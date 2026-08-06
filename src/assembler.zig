const std = @import("std");
const bytecode = @import("vig_bytecode");

const container = bytecode.container;
const encode = bytecode.encode;
const foreign = bytecode.foreign;
const verify = bytecode.verify;
const OpCode = bytecode.OpCode;

/// The region of the program that a label points into.
///
/// The three regions sit in memory in this order: the code, then the static data
/// from the file, then the zero-filled bytes that `reserve` asks for. Therefore the
/// assembler knows the final address of a label in a later region only after it
/// knows the length of each earlier one.
///
/// A label in `bss` needs both earlier lengths, and the file holds no byte for it.
/// That is the point of the region: a program declares a large array and the file
/// stays small.
const Region = enum { code, data, bss };

const Label = struct {
    region: Region,
    offset: usize,
};

/// The output of the assembler that is not a program. At this time it holds the
/// location of a failure in the verifier. The caller can show this location with
/// the error.
pub const Diagnostics = struct {
    verification: ?verify.Failure = null,
};

/// What the caller asks the assembler to do beyond assembling.
pub const Options = struct {
    /// Also check that the operand stack has one height at every instruction.
    ///
    /// This is off by default, and it is not about whether a program is safe to run:
    /// the VM refuses an unsafe program either way. It is a check for a program that
    /// a compiler wrote, where an unbalanced stack is a fault in the compiler and
    /// shows up far from the instruction that caused it. Hand-written VIG that keeps
    /// its own stack in a way the check cannot follow is still a correct program, so
    /// the check is something a caller asks for.
    check_stack: bool = false,
};

/// Assemble `source` into a VIG container. The verifier then makes sure that:
///
/// - each instruction that the program can reach decodes;
/// - each branch goes to the first byte of an instruction;
/// - control does not continue past the end of the code.
pub fn assemble(allocator: std.mem.Allocator, source: []const u8, diagnostics: ?*Diagnostics) ![]u8 {
    return assembleWithOptions(allocator, source, .{}, diagnostics);
}

/// The same, with the checks that a caller asks for beyond the ones every program
/// gets. See `Options`.
pub fn assembleWithOptions(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: Options,
    diagnostics: ?*Diagnostics,
) ![]u8 {
    var labels = std.StringHashMap(Label).init(allocator);
    defer labels.deinit();
    var imports_by_name = std.StringHashMap(u8).init(allocator);
    defer imports_by_name.deinit();
    var imports = std.ArrayList(foreign.Import).empty;
    defer imports.deinit(allocator);

    // A label takes the address of the next item that the assembler writes. That
    // item can be an instruction or a string. Therefore the assembler holds each
    // label until it knows the address.
    var pending_labels = std.ArrayList([]const u8).empty;
    defer pending_labels.deinit(allocator);

    var code_len: usize = 0;
    var data_len: usize = 0;
    var bss_len: usize = 0;
    var entry_label: ?[]const u8 = null;

    // Pass one: measure the two regions and put each label at its address.
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = meaningfulLine(raw_line);
        if (line.len == 0) continue;

        if (labelName(line)) |name| {
            if (labels.contains(name) or containsPending(pending_labels.items, name)) {
                return error.DuplicateLabel;
            }
            try pending_labels.append(allocator, name);
            continue;
        }

        if (isDirective(line, "extern")) {
            const declaration = try parseExtern(line);
            if (imports_by_name.contains(declaration.name)) return error.DuplicateForeignImport;
            if (imports.items.len >= foreign.max_imports) return error.TooManyForeignImports;
            try imports_by_name.put(declaration.name, @intCast(imports.items.len));
            try imports.append(allocator, declaration.import);
            continue;
        }

        if (isDirective(line, "entry")) {
            if (entry_label != null) return error.DuplicateEntryPoint;
            entry_label = try parseEntry(line);
            continue;
        }

        if (isDirective(line, "asciiz")) {
            try place(&labels, &pending_labels, .data, data_len);
            data_len += (try parseAsciiz(line)).len + 1;
            continue;
        }

        // A value directive needs no label address to measure itself: the width is
        // the directive and the count is the number of values. Therefore pass one
        // knows the size of the region even though a value can name a label that
        // only pass two can resolve.
        if (dataWidth(line)) |width| {
            try place(&labels, &pending_labels, .data, data_len);
            data_len += width * try countValues(line);
            continue;
        }

        if (isDirective(line, "reserve")) {
            try place(&labels, &pending_labels, .bss, bss_len);
            bss_len += try parseReserve(line);
            continue;
        }

        try place(&labels, &pending_labels, .code, code_len);
        code_len += (try parseInstruction(line)).size();
    }
    // A label after the last instruction has the address of the end of the code.
    try place(&labels, &pending_labels, .code, code_len);

    // Pass two: write the output. Each region has exactly the size from pass one.
    var code = try std.ArrayList(u8).initCapacity(allocator, code_len);
    defer code.deinit(allocator);
    var data = try std.ArrayList(u8).initCapacity(allocator, data_len);
    defer data.deinit(allocator);

    // Every label has an address now, and each region has its final length.
    // Therefore one scope answers for the whole pass, and an instruction operand and
    // a data value resolve a name in exactly the same way.
    const scope: Scope = .{
        .labels = &labels,
        .imports_by_name = &imports_by_name,
        .code_len = code_len,
        .data_len = data_len,
    };

    lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = meaningfulLine(raw_line);
        if (line.len == 0 or labelName(line) != null) continue;
        if (isDirective(line, "extern") or isDirective(line, "entry")) continue;

        if (isDirective(line, "asciiz")) {
            try data.appendSlice(allocator, try parseAsciiz(line));
            try data.append(allocator, 0);
            continue;
        }

        if (dataWidth(line)) |width| {
            try appendValues(allocator, &data, line, width, scope);
            continue;
        }

        // `reserve` writes no byte. Its length is in the header, and the VM clears
        // memory before it loads a program.
        if (isDirective(line, "reserve")) continue;

        var tokens = std.mem.tokenizeAny(u8, line, " \t,");
        const instruction = try opCodeFor(tokens.next() orelse unreachable);
        const operand = try parseOperand(instruction, &tokens, scope);

        var buffer: [8]u8 = undefined;
        const size = try encode.encode(&buffer, instruction, operand);
        try code.appendSlice(allocator, buffer[0..size]);
    }

    const entry_point = try resolveEntryPoint(entry_label, &labels);
    try verifyProgram(allocator, code.items, entry_point, imports.items, options, diagnostics);

    const layout: container.Layout = .{
        .imports = imports.items,
        .code = code.items,
        .data = data.items,
        .bss_len = std.math.cast(u32, bss_len) orelse return error.AddressOutOfRange,
        .entry_point = entry_point,
    };
    const output = try allocator.alloc(u8, try container.encodedSize(layout));
    errdefer allocator.free(output);
    std.debug.assert(try container.write(layout, output) == output.len);
    return output;
}

/// Give the address to each label that waits for the next item in the output.
fn place(
    labels: *std.StringHashMap(Label),
    pending: *std.ArrayList([]const u8),
    region: Region,
    offset: usize,
) !void {
    for (pending.items) |name| try labels.put(name, .{ .region = region, .offset = offset });
    pending.clearRetainingCapacity();
}

fn containsPending(pending: []const []const u8, name: []const u8) bool {
    for (pending) |other| {
        if (std.mem.eql(u8, other, name)) return true;
    }
    return false;
}

const Scope = struct {
    labels: *const std.StringHashMap(Label),
    imports_by_name: *const std.StringHashMap(u8),
    code_len: usize,
    data_len: usize,

    /// The absolute address of a label in the program image. That image is the code
    /// region, then the static-data region, then the zero-filled region.
    fn address(self: Scope, name: []const u8) ?usize {
        const label = self.labels.get(name) orelse return null;
        return switch (label.region) {
            .code => label.offset,
            .data => self.code_len + label.offset,
            .bss => self.code_len + self.data_len + label.offset,
        };
    }
};

fn parseOperand(
    instruction: OpCode,
    tokens: *std.mem.TokenIterator(u8, .any),
    scope: Scope,
) !encode.Operand {
    const kind = instruction.operandKind();
    if (kind == .none) {
        if (tokens.next() != null) return error.UnexpectedOperand;
        return .none;
    }

    const text = tokens.next() orelse return error.MissingOperand;

    // `enter` is the one instruction with two operands: the arguments of the function
    // and then its locals.
    if (kind == .frame_shape) {
        const locals_text = tokens.next() orelse return error.MissingOperand;
        if (tokens.next() != null) return error.UnexpectedOperand;
        return .{ .frame_shape = .{
            .arguments = try std.fmt.parseInt(u16, text, 0),
            .locals = try std.fmt.parseInt(u16, locals_text, 0),
        } };
    }

    if (tokens.next() != null) return error.UnexpectedOperand;

    // An import is named and never calculated, so it does not go through the
    // expression parser.
    if (kind == .import_index) {
        return .{ .import_index = scope.imports_by_name.get(text) orelse return error.UnknownForeignImport };
    }
    // A frame slot is an index and never an address, so no label can name one.
    if (kind == .local_index) {
        return .{ .local_index = try std.fmt.parseInt(u16, text, 0) };
    }

    const value = try resolveAddress(text, scope, kind.acceptsLabel());
    return switch (kind) {
        .none, .import_index, .local_index, .frame_shape => unreachable,
        .signed => .{ .signed = std.math.cast(i32, value) orelse return error.AddressOutOfRange },
        .code_target => .{ .code_target = std.math.cast(u32, value) orelse return error.AddressOutOfRange },
        .data_address => .{ .data_address = std.math.cast(u32, value) orelse return error.AddressOutOfRange },
    };
}

/// Read an operand that names an address, and give its value.
///
/// The operand is a number, a label, or a label and a constant joined by `+` or `-`.
/// The last form is what an array and a structure need: `numbers+8` is the third
/// `i32` of `numbers`, and `point+4` is the second field of `point`. Without it a
/// program must know the address of a label to reach anything but its first byte,
/// and the source cannot know that address.
///
/// The expression carries no space, so `numbers+8` is one operand and `numbers + 8`
/// is three. A join of the tokens would make `push 1 2` mean `push 12`, and that
/// line is a mistake that the assembler must report.
fn resolveAddress(text: []const u8, scope: Scope, accepts_label: bool) !i64 {
    // The whole text is tried as a label first. Therefore a label whose name holds a
    // `-` still resolves, and only a name that no label has becomes an expression.
    if (accepts_label) {
        if (scope.address(text)) |address| return @intCast(address);
    }

    const split = std.mem.indexOfAny(u8, text, "+-");
    // A sign at the start belongs to the number and does not make an expression.
    if (split == null or split.? == 0) return std.fmt.parseInt(i64, text, 0);
    if (!accepts_label) return error.InvalidCharacter;

    const name = text[0..split.?];
    const offset_text = text[split.? + 1 ..];
    if (offset_text.len == 0) return error.MissingOperand;

    const base = scope.address(name) orelse return error.UnknownLabel;
    const offset = try std.fmt.parseInt(i64, offset_text, 0);
    const total = if (text[split.?] == '+')
        @as(i64, @intCast(base)) + offset
    else
        @as(i64, @intCast(base)) - offset;

    if (total < 0) return error.AddressOutOfRange;
    return total;
}

fn resolveEntryPoint(entry_label: ?[]const u8, labels: *const std.StringHashMap(Label)) !u32 {
    const name = entry_label orelse return 0;
    const label = labels.get(name) orelse return error.UnknownEntryPointLabel;
    // Execution starts at an instruction. Therefore the entry point cannot
    // name a string in the static-data region.
    if (label.region != .code) return error.InvalidEntryPoint;
    return std.math.cast(u32, label.offset) orelse error.AddressOutOfRange;
}

fn verifyProgram(
    allocator: std.mem.Allocator,
    code: []const u8,
    entry_point: u32,
    imports: []const foreign.Import,
    options: Options,
    diagnostics: ?*Diagnostics,
) !void {
    const scratch = try allocator.alloc(verify.Mark, verify.scratchSize(code.len));
    defer allocator.free(scratch);

    // The number of arguments of each import, which is what the stack check needs to
    // know how many values a `foreign_call` takes.
    const import_args = try allocator.alloc(u8, imports.len);
    defer allocator.free(import_args);
    for (imports, import_args) |import, *count| count.* = import.arg_count;

    const verify_options: verify.Options = .{
        .code = code,
        .entry_point = entry_point,
        .import_count = @intCast(imports.len),
        // The assembler knows the length of the code, so it can refuse a `store`
        // that would write an instruction. It does not know the size of the memory
        // of the VM that will run the program, so it leaves that bound to the VM.
        .code_len = @intCast(code.len),
        .import_args = import_args,
    };

    var failure: verify.Failure = undefined;
    verify.verify(verify_options, scratch, &failure) catch |err| {
        if (diagnostics) |slot| slot.verification = failure;
        return err;
    };

    if (!options.check_stack) return;

    // The stack check needs its own working space, and it is not part of what makes
    // a program safe to run. Therefore nothing is allocated for it unless the caller
    // asked for the check.
    const depths = try allocator.alloc(verify.Depth, code.len);
    defer allocator.free(depths);
    const walked = try allocator.alloc(verify.Mark, code.len);
    defer allocator.free(walked);
    const signature = try allocator.alloc(verify.Mark, code.len);
    defer allocator.free(signature);

    verify.checkStack(verify_options, .{
        .depths = depths,
        .walk = walked,
        .signature = signature,
    }, &failure) catch |err| {
        if (diagnostics) |slot| slot.verification = failure;
        return err;
    };
}

fn meaningfulLine(raw_line: []const u8) []const u8 {
    // Semicolons and hashes introduce comments, except inside an `asciiz`
    // literal where they are ordinary string bytes.
    var in_string = false;
    var comment_start = raw_line.len;
    for (raw_line, 0..) |byte, index| {
        if (byte == '"') {
            in_string = !in_string;
        } else if (!in_string and (byte == ';' or byte == '#')) {
            comment_start = index;
            break;
        }
    }
    const uncommented = raw_line[0..comment_start];
    return std.mem.trim(u8, uncommented, " \t\r");
}

fn labelName(line: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, line, ":")) return null;
    const name = std.mem.trim(u8, line[0 .. line.len - 1], " \t");
    return if (name.len == 0 or std.mem.indexOfAny(u8, name, " \t,") != null) null else name;
}

fn isDirective(line: []const u8, directive: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, line, " \t,");
    return std.mem.eql(u8, tokens.next() orelse return false, directive);
}

fn parseExtern(line: []const u8) !struct { name: []const u8, import: foreign.Import } {
    var tokens = std.mem.tokenizeAny(u8, line, " \t,");
    _ = tokens.next(); // extern
    const name = tokens.next() orelse return error.MissingOperand;
    const library = tokens.next() orelse return error.MissingOperand;
    const symbol = tokens.next() orelse return error.MissingOperand;

    var import: foreign.Import = .{ .library = library, .symbol = symbol };
    while (tokens.next()) |type_name| {
        try import.addArg(foreign.ArgType.fromName(type_name) orelse return error.UnknownForeignType);
    }
    return .{ .name = name, .import = import };
}

fn parseEntry(line: []const u8) ![]const u8 {
    var tokens = std.mem.tokenizeAny(u8, line, " \t,");
    _ = tokens.next(); // entry
    const name = tokens.next() orelse return error.MissingOperand;
    if (tokens.next() != null) return error.UnexpectedOperand;
    return name;
}

fn parseAsciiz(line: []const u8) ![]const u8 {
    const rest = std.mem.trim(u8, line["asciiz".len..], " \t");
    if (rest.len < 2 or rest[0] != '"' or rest[rest.len - 1] != '"') return error.InvalidStringLiteral;
    const contents = rest[1 .. rest.len - 1];
    if (std.mem.indexOfScalar(u8, contents, 0) != null or std.mem.indexOfScalar(u8, contents, '"') != null) {
        return error.InvalidStringLiteral;
    }
    return contents;
}

/// The directives that put an initialized value in the static-data region, with the
/// width of one value in bytes.
///
/// The names say how many bits a value has, which is how the load and the store
/// mnemonics name a width and how an `extern` declaration names an argument type.
/// A program therefore reads what it wrote with the instruction of the same number:
/// `i16` and `load16_s`.
const data_widths = [_]struct { directive: []const u8, width: usize }{
    .{ .directive = "i8", .width = 1 },
    .{ .directive = "i16", .width = 2 },
    .{ .directive = "i32", .width = 4 },
};

/// The width of one value for the data directive on this line, or null if the line
/// is not one of them.
fn dataWidth(line: []const u8) ?usize {
    for (data_widths) |entry| {
        if (isDirective(line, entry.directive)) return entry.width;
    }
    return null;
}

/// How many values a data directive lists.
///
/// A directive with no value is a mistake rather than an empty declaration: it
/// writes nothing, so the label before it takes the address of whatever comes next,
/// which is the same fault that `reserve 0` has.
fn countValues(line: []const u8) !usize {
    var tokens = std.mem.tokenizeAny(u8, line, " \t,");
    _ = tokens.next(); // the directive

    var count: usize = 0;
    while (tokens.next()) |_| count += 1;
    if (count == 0) return error.MissingOperand;
    return count;
}

/// Write each value that a data directive lists, in the order that the source wrote
/// them.
///
/// A value is a number or a label expression, exactly as an instruction operand is.
/// Therefore `i32 greeting` puts the address of a string in the data region, and a C
/// initializer that holds a pointer or a function address needs nothing more. The
/// values are separated by a space or a comma, so an array is one line:
/// `i32 1, 2, 3`.
fn appendValues(
    allocator: std.mem.Allocator,
    data: *std.ArrayList(u8),
    line: []const u8,
    width: usize,
    scope: Scope,
) !void {
    var tokens = std.mem.tokenizeAny(u8, line, " \t,");
    _ = tokens.next(); // the directive

    while (tokens.next()) |text| {
        var buffer: [4]u8 = undefined;
        try writeValue(&buffer, try resolveAddress(text, scope, true), width);
        try data.appendSlice(allocator, buffer[0..width]);
    }
}

/// Put `value` in the first `width` bytes of `buffer`, in the order that memory
/// holds them.
///
/// The permitted range covers the signed form and the unsigned form of the width, so
/// `i8 -1` and `i8 255` both give the byte `0xff`. The two spellings mean the same
/// byte, and which one appears is a matter of what the source said. A value outside
/// both is a mistake and not something to truncate without a word.
fn writeValue(buffer: *[4]u8, value: i64, width: usize) !void {
    const bits: u6 = @intCast(width * 8);
    const lowest = -(@as(i64, 1) << (bits - 1));
    const highest = (@as(i64, 1) << bits) - 1;
    if (value < lowest or value > highest) return error.ValueOutOfRange;

    std.mem.writeInt(u32, buffer, @truncate(@as(u64, @bitCast(value))), .little);
}

/// `reserve N` gives the label before it `N` zero bytes in the static-data region.
/// A program then has a name for storage that it can write, because the code region
/// is read-only and an `asciiz` string is a fixed value.
///
/// The bytes are in the container, so they are bytes of the file. A later stage
/// records a zero-filled length in the header instead, and then a large array costs
/// nothing in the file.
fn parseReserve(line: []const u8) !usize {
    var tokens = std.mem.tokenizeAny(u8, line, " \t,");
    _ = tokens.next(); // reserve
    const text = tokens.next() orelse return error.MissingOperand;
    if (tokens.next() != null) return error.UnexpectedOperand;

    const size = try std.fmt.parseInt(usize, text, 0);
    // A zero size gives the label the address of whatever comes after it, which is
    // never what the author meant.
    if (size == 0) return error.InvalidReserveSize;
    return size;
}

/// Check the form of an instruction line in pass one, before the labels have
/// addresses.
fn parseInstruction(line: []const u8) !OpCode {
    var tokens = std.mem.tokenizeAny(u8, line, " \t,");
    const instruction = try opCodeFor(tokens.next() orelse return error.InvalidSyntax);

    // `enter` takes two operands. Every other instruction takes one or none.
    const operands: usize = switch (instruction.operandKind()) {
        .none => 0,
        .frame_shape => 2,
        else => 1,
    };
    for (0..operands) |_| _ = tokens.next() orelse return error.MissingOperand;
    if (tokens.next() != null) return error.UnexpectedOperand;

    return instruction;
}

fn opCodeFor(mnemonic: []const u8) !OpCode {
    return OpCode.fromMnemonic(mnemonic) orelse error.UnknownOpcode;
}

// Tests ----------------------------------------------------------------------

const testing = std.testing;

/// Assemble `source` and check the two regions of the container. These checks
/// are easier to read than a check on the bytes of the complete file. The
/// vig-bytecode tests check the layout of the header.
fn expectRegions(source: []const u8, expected_code: []const u8, expected_data: []const u8) !void {
    const output = try assemble(testing.allocator, source, null);
    defer testing.allocator.free(output);

    const image = try container.parse(output);
    try testing.expectEqual(container.Kind.current, image.kind);
    try testing.expectEqualSlices(u8, expected_code, image.code);
    try testing.expectEqualSlices(u8, expected_data, image.data);
}

test "assembles labels and the newest VIG opcodes" {
    // A global is a label now, and not a slot index. The code is 29 bytes and the
    // program holds no static data, so `counter` is at address 29.
    const source =
        \\start:
        \\  push 40
        \\  store counter
        \\  call increment
        \\  print
        \\  halt
        \\increment:
        \\  load counter
        \\  push 2
        \\  add
        \\  ret
        \\counter:
        \\  reserve 4
    ;
    const expected = [_]u8{
        1,  40, 0,  0, 0,
        21, 29, 0,  0, 0,
        22, 17, 0,  0, 0,
        4,  0,
        20, 29, 0,  0, 0,
        1,  2,  0,  0, 0,
        2,  23,
    };

    try expectRegions(source, &expected, "");
}

test "assembles the newest operand-free opcodes" {
    const source =
        \\and
        \\or
        \\xor
        \\not
        \\shl
        \\shr_u
        \\rotl
        \\add_wrap
        \\read_i32
        \\read_byte
        \\print_hex
        \\halt
    ;

    try expectRegions(source, &[_]u8{ 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 0 }, "");
}

test "static data is assembled after the code, not inside it" {
    // The source declares `greeting` before `halt`, but the assembler puts it in
    // the data region. Therefore its address is past the end of the code, and the
    // VM can never execute it.
    const source =
        \\  push greeting
        \\  print_string
        \\  halt
        \\greeting:
        \\  asciiz "hi"
    ;
    const code_len = 5 + 1 + 1;
    const expected_code = [_]u8{
        1,  code_len, 0, 0, 0,
        25, 0,
    };

    try expectRegions(source, &expected_code, "hi\x00");

    const output = try assemble(testing.allocator, source, null);
    defer testing.allocator.free(output);
    const image = try container.parse(output);
    try testing.expectEqual(@as(u32, code_len), image.header.code_len);
    try testing.expectEqual(@as(u32, 3), image.header.data_len);
}

test "several strings keep their declaration order in the data region" {
    const source =
        \\  push second
        \\  print_string
        \\  halt
        \\first:
        \\  asciiz "a"
        \\second:
        \\  asciiz "bc"
    ;
    // "a\0" uses data offsets 0 and 1. Therefore `second` is at `code_len` + 2.
    try expectRegions(source, &[_]u8{ 1, 9, 0, 0, 0, 25, 0 }, "a\x00bc\x00");
}

test "asciiz strings may contain comment markers" {
    const source =
        \\  push message
        \\  print_string
        \\  halt
        \\message:
        \\  asciiz "use # and ; literally" # trailing comment
    ;

    try expectRegions(source, &[_]u8{ 1, 7, 0, 0, 0, 25, 0 }, "use # and ; literally\x00");
}

test "assembles a foreign-import container and call" {
    const source =
        \\extern GetCurrentProcessId kernel32.dll GetCurrentProcessId
        \\foreign_call GetCurrentProcessId
        \\halt
    ;
    const output = try assemble(testing.allocator, source, null);
    defer testing.allocator.free(output);

    const image = try container.parse(output);
    try testing.expectEqual(@as(u8, 1), image.header.import_count);
    try testing.expectEqualSlices(u8, &[_]u8{ 24, 0, 0 }, image.code);

    var iterator = image.importIterator();
    const import = (try iterator.next()).?;
    try testing.expectEqualStrings("kernel32.dll", import.library);
    try testing.expectEqualStrings("GetCurrentProcessId", import.symbol);
    try testing.expectEqual(@as(usize, 0), import.argTypes().len);
    // The declared length of the table must be equal to the length that the
    // imports use.
    try testing.expectEqual(iterator.offset, image.header.import_table_len);
}

test "extern argument types are taken from the shared foreign ABI" {
    const source =
        \\extern MessageBoxA user32.dll MessageBoxA ptr cstr cstr u32
        \\halt
    ;
    const output = try assemble(testing.allocator, source, null);
    defer testing.allocator.free(output);

    var iterator = (try container.parse(output)).importIterator();
    const import = (try iterator.next()).?;
    try testing.expectEqualSlices(
        foreign.ArgType,
        &.{ .ptr, .cstr, .cstr, .u32 },
        import.argTypes(),
    );
}

test "rejects more foreign imports, arguments or unknown types than the ABI allows" {
    const too_many =
        \\extern f0 k.dll s
        \\extern f1 k.dll s
        \\extern f2 k.dll s
        \\extern f3 k.dll s
        \\extern f4 k.dll s
        \\extern f5 k.dll s
        \\extern f6 k.dll s
        \\extern f7 k.dll s
        \\extern f8 k.dll s
        \\extern f9 k.dll s
        \\extern f10 k.dll s
        \\extern f11 k.dll s
        \\extern f12 k.dll s
        \\extern f13 k.dll s
        \\extern f14 k.dll s
        \\extern f15 k.dll s
        \\extern f16 k.dll s
        \\halt
    ;
    try testing.expectError(error.TooManyForeignImports, assemble(testing.allocator, too_many, null));
    try testing.expectError(
        error.TooManyForeignArguments,
        assemble(testing.allocator, "extern f k.dll s u32 u32 u32 u32 u32\nhalt", null),
    );
    try testing.expectError(
        error.UnknownForeignType,
        assemble(testing.allocator, "extern f k.dll s f32\nhalt", null),
    );
    try testing.expectError(
        error.UnknownForeignImport,
        assemble(testing.allocator, "foreign_call missing\nhalt", null),
    );
}

test "push accepts signed literals and label addresses" {
    const source =
        \\  push -42
        \\  push data
        \\  halt
        \\data:
        \\  asciiz "x"
    ;
    const expected_code = [_]u8{
        1, 0xd6, 0xff, 0xff, 0xff,
        1, 11,   0,    0,    0,
        0,
    };
    try expectRegions(source, &expected_code, "x\x00");
}

test "assembles indirect data access" {
    const source =
        \\  push 7
        \\  push 2
        \\  store_at
        \\  push 2
        \\  load_at
        \\  halt
    ;
    const expected = [_]u8{
        1,  7, 0, 0, 0,
        1,  2, 0, 0, 0,
        27,
        1,  2, 0, 0, 0,
        26,
        0,
    };
    try expectRegions(source, &expected, "");
}

test "the entry point defaults to the first instruction" {
    const output = try assemble(testing.allocator, "halt", null);
    defer testing.allocator.free(output);
    try testing.expectEqual(@as(u32, 0), (try container.parse(output)).header.entry_point);
}

test "an entry directive records where execution starts" {
    const source =
        \\entry main
        \\helper:
        \\  push 1
        \\  ret
        \\main:
        \\  call helper
        \\  print
        \\  halt
    ;
    const output = try assemble(testing.allocator, source, null);
    defer testing.allocator.free(output);
    try testing.expectEqual(@as(u32, 6), (try container.parse(output)).header.entry_point);
}

test "rejects an entry point that is missing, repeated, or not code" {
    try testing.expectError(
        error.UnknownEntryPointLabel,
        assemble(testing.allocator, "entry nowhere\nhalt", null),
    );
    try testing.expectError(
        error.DuplicateEntryPoint,
        assemble(testing.allocator, "entry a\nentry a\na:\nhalt", null),
    );
    try testing.expectError(
        error.InvalidEntryPoint,
        assemble(testing.allocator, "entry text\nhalt\ntext:\n  asciiz \"x\"", null),
    );
}

test "labels are unique and resolve in either direction" {
    try testing.expectError(
        error.DuplicateLabel,
        assemble(testing.allocator, "a:\n  halt\na:\n  halt", null),
    );
    // Two labels on two lines that come one after the other have the same
    // address.
    try testing.expectError(
        error.DuplicateLabel,
        assemble(testing.allocator, "a:\na:\n  halt", null),
    );
}

test "rejects an unresolved control-flow label" {
    try testing.expectError(
        error.InvalidCharacter,
        assemble(testing.allocator, "call missing\nhalt", null),
    );
}

test "rejects malformed operands and string literals" {
    try testing.expectError(error.UnknownOpcode, assemble(testing.allocator, "nope", null));
    try testing.expectError(error.MissingOperand, assemble(testing.allocator, "push", null));
    try testing.expectError(error.UnexpectedOperand, assemble(testing.allocator, "halt 1", null));
    try testing.expectError(error.UnexpectedOperand, assemble(testing.allocator, "push 1 2", null));
    try testing.expectError(error.InvalidStringLiteral, assemble(testing.allocator, "asciiz nope", null));
    // A data address is a label now. But this label names an instruction, so the
    // store would write the code and the verifier refuses it.
    try testing.expectError(
        error.StoreIntoCodeRegion,
        assemble(testing.allocator, "store here\nhere:\nhalt", null),
    );
    // A name that no label has, and that is not a number, is still a failure.
    try testing.expectError(
        error.InvalidCharacter,
        assemble(testing.allocator, "store nowhere\nhalt", null),
    );
}

test "verification rejects a program whose control flow leaves the code" {
    // The assembler finds this error: control continues past the end of the code
    // region. The VM does not have to find it.
    var diagnostics: Diagnostics = .{};
    try testing.expectError(
        error.ExecutionRunsOffEnd,
        assemble(testing.allocator, "push 1", &diagnostics),
    );
    try testing.expectEqual(@as(usize, 0), diagnostics.verification.?.offset);

    // A label cannot make a jump into the middle of an instruction. Therefore
    // this test uses an absolute address.
    try testing.expectError(
        error.MisalignedTarget,
        assemble(testing.allocator, "push 1\njmp 1", null),
    );
    // A jump into the static-data region goes fully outside the code.
    try testing.expectError(
        error.TargetOutOfRange,
        assemble(testing.allocator, "jmp text\nhalt\ntext:\n  asciiz \"x\"", null),
    );
}

test "reserve declares zero-filled bytes that the file does not hold" {
    // `slot` is at the start of the zero-filled region and `flag` is four bytes
    // after it. The code is 11 bytes and there is no static data, so the two
    // addresses are 11 and 15.
    const source =
        \\  push slot
        \\  push flag
        \\  halt
        \\slot:
        \\  reserve 4
        \\flag:
        \\  reserve 1
    ;
    const expected_code = [_]u8{
        1, 11, 0, 0, 0,
        1, 15, 0, 0, 0,
        0,
    };
    // The data region is empty. The five bytes are a length in the header.
    try expectRegions(source, &expected_code, "");

    const output = try assemble(testing.allocator, source, null);
    defer testing.allocator.free(output);
    const image = try container.parse(output);
    try testing.expectEqual(@as(u32, 5), image.header.bss_len);
    try testing.expectEqual(@as(usize, 11), image.fileImageLen());
    try testing.expectEqual(@as(usize, 16), image.imageLen());
}

test "the zero-filled region comes after the static data" {
    const source =
        \\  push text
        \\  push buffer
        \\  halt
        \\text:
        \\  asciiz "ab"
        \\buffer:
        \\  reserve 2
    ;
    // "ab\0" uses data offsets 0 to 2, so `buffer` is at code_len + 3 = 14.
    const expected_code = [_]u8{
        1, 11, 0, 0, 0,
        1, 14, 0, 0, 0,
        0,
    };
    try expectRegions(source, &expected_code, "ab\x00");

    const output = try assemble(testing.allocator, source, null);
    defer testing.allocator.free(output);
    try testing.expectEqual(@as(u32, 2), (try container.parse(output)).header.bss_len);
}

test "a label and a constant address a member of an array" {
    // `numbers+8` is the third i32 of `numbers`. Without this form a program cannot
    // name anything but the first byte of a label.
    const source =
        \\  push 1
        \\  store numbers
        \\  push 2
        \\  store numbers+4
        \\  push 3
        \\  store numbers+8
        \\  load numbers+8
        \\  halt
        \\numbers:
        \\  reserve 12
    ;
    // Six five-byte instructions, a five-byte load, then `halt`: 36 bytes.
    const expected_code = [_]u8{
        1,  1,  0,  0, 0,
        21, 36, 0,  0, 0,
        1,  2,  0,  0, 0,
        21, 40, 0,  0, 0,
        1,  3,  0,  0, 0,
        21, 44, 0,  0, 0,
        20, 44, 0,  0, 0,
        0,
    };
    try expectRegions(source, &expected_code, "");
}

test "a constant can also be subtracted from a label" {
    const source =
        \\  load tail-4
        \\  halt
        \\head:
        \\  reserve 8
        \\tail:
        \\  reserve 4
    ;
    // The code is six bytes, so `head` is at 6 and `tail` is at 14. `tail-4` is 10.
    try expectRegions(source, &[_]u8{ 20, 10, 0, 0, 0, 0 }, "");
}

test "rejects an address expression whose label does not exist" {
    try testing.expectError(
        error.UnknownLabel,
        assemble(testing.allocator, "load missing+4\nhalt", null),
    );
    // An expression needs a number after the sign.
    try testing.expectError(
        error.MissingOperand,
        assemble(testing.allocator, "load here+\nhalt\nhere:\n  reserve 4", null),
    );
    // A space makes the line three tokens, and three tokens is a mistake. A join
    // would make `push 1 2` mean `push 12`.
    try testing.expectError(
        error.UnexpectedOperand,
        assemble(testing.allocator, "load here + 4\nhalt\nhere:\n  reserve 4", null),
    );
}

test "rejects a reserve with no size, a zero size, or extra tokens" {
    try testing.expectError(
        error.MissingOperand,
        assemble(testing.allocator, "halt\nx:\n  reserve", null),
    );
    try testing.expectError(
        error.InvalidReserveSize,
        assemble(testing.allocator, "halt\nx:\n  reserve 0", null),
    );
    try testing.expectError(
        error.UnexpectedOperand,
        assemble(testing.allocator, "halt\nx:\n  reserve 4 8", null),
    );
    try testing.expectError(
        error.InvalidCharacter,
        assemble(testing.allocator, "halt\nx:\n  reserve four", null),
    );
}

test "a data directive writes initialized values in the static-data region" {
    // The three widths, each with the value 1, so the bytes show the width and the
    // order and nothing else. `i32` is four bytes little-endian, as every value in
    // memory is.
    const source =
        \\  halt
        \\one_byte:
        \\  i8 1
        \\two_bytes:
        \\  i16 1
        \\four_bytes:
        \\  i32 1
    ;
    try expectRegions(source, &[_]u8{0}, "\x01\x01\x00\x01\x00\x00\x00");
}

test "one data directive lists several values" {
    // A comma and a space separate values the same way, because the tokenizer takes
    // both. An array initializer is therefore one line.
    const source =
        \\  halt
        \\numbers:
        \\  i32 1, 2, 3
        \\bytes:
        \\  i8 4 5 6
    ;
    try expectRegions(
        source,
        &[_]u8{0},
        "\x01\x00\x00\x00\x02\x00\x00\x00\x03\x00\x00\x00\x04\x05\x06",
    );
}

test "a data value can be a label or a label expression" {
    // This is what a C initializer that holds a pointer needs: `char *p = message;`
    // and `int *tail = &numbers[2];`. The code is one byte, so `message` is at 1 and
    // the pointer that follows the string is at 4.
    const source =
        \\  halt
        \\message:
        \\  asciiz "hi"
        \\pointer:
        \\  i32 message
        \\interior:
        \\  i32 message+1
    ;
    try expectRegions(source, &[_]u8{0}, "hi\x00" ++ "\x01\x00\x00\x00" ++ "\x02\x00\x00\x00");
}

test "the signed form and the unsigned form of a value give the same bytes" {
    // `i8 -1` and `i8 255` are one byte and it holds the same bits. Which spelling
    // appears is a matter of what the source said, so both are accepted.
    try expectRegions("halt\nx:\n  i8 -1, 255", &[_]u8{0}, "\xff\xff");
    try expectRegions("halt\nx:\n  i16 -1, 65535", &[_]u8{0}, "\xff\xff\xff\xff");
    try expectRegions("halt\nx:\n  i32 -1", &[_]u8{0}, "\xff\xff\xff\xff");
    // A base prefix works here as it does in an instruction operand.
    try expectRegions("halt\nx:\n  i32 0x0a", &[_]u8{0}, "\x0a\x00\x00\x00");
}

test "a value that does not fit its width is refused" {
    // Truncating without a word would put a number in the program that the source
    // did not ask for.
    try testing.expectError(
        error.ValueOutOfRange,
        assemble(testing.allocator, "halt\nx:\n  i8 256", null),
    );
    try testing.expectError(
        error.ValueOutOfRange,
        assemble(testing.allocator, "halt\nx:\n  i8 -129", null),
    );
    try testing.expectError(
        error.ValueOutOfRange,
        assemble(testing.allocator, "halt\nx:\n  i16 65536", null),
    );
    try testing.expectError(
        error.ValueOutOfRange,
        assemble(testing.allocator, "halt\nx:\n  i32 4294967296", null),
    );
    // A label whose address is past the width is the same mistake. `far` sits after
    // 300 reserved bytes, so its address needs more than one byte to hold.
    try testing.expectError(
        error.ValueOutOfRange,
        assemble(testing.allocator, "halt\nx:\n  i8 far\npad:\n  reserve 300\nfar:\n  reserve 1", null),
    );
}

test "a data directive with no value is refused" {
    // The label before it would take the address of the next item, which is never
    // what the author meant.
    try testing.expectError(
        error.MissingOperand,
        assemble(testing.allocator, "halt\nx:\n  i32", null),
    );
    // A name that no label has is not a number either. This is the error that an
    // instruction operand gives for the same name, and a value is read the same way.
    try testing.expectError(
        error.InvalidCharacter,
        assemble(testing.allocator, "halt\nx:\n  i32 missing", null),
    );
}

test "initialized data and reserved bytes keep their order in one program" {
    // The regions are the code, then the static data that the file holds, then the
    // zero-filled bytes. A directive of each kind therefore lands where its region
    // is, whatever order the source wrote them in.
    const source =
        \\  push counter
        \\  push limit
        \\  halt
        \\counter:
        \\  reserve 4
        \\limit:
        \\  i32 100
    ;
    // The code is 11 bytes and the data region holds the four bytes of `limit`.
    // Therefore `limit` is at 11 and `counter`, which is in the region after it, is
    // at 15.
    const expected_code = [_]u8{
        1, 15, 0, 0, 0,
        1, 11, 0, 0, 0,
        0,
    };
    try expectRegions(source, &expected_code, "\x64\x00\x00\x00");

    const output = try assemble(testing.allocator, source, null);
    defer testing.allocator.free(output);
    const image = try container.parse(output);
    try testing.expectEqual(@as(u32, 4), image.header.data_len);
    try testing.expectEqual(@as(u32, 4), image.header.bss_len);
}

test "an empty source assembles to an empty program" {
    const output = try assemble(testing.allocator, "# nothing but a comment\n", null);
    defer testing.allocator.free(output);

    const image = try container.parse(output);
    try testing.expectEqual(@as(usize, 0), image.imageLen());
    try testing.expectEqual(@as(u32, 0), image.header.entry_point);
}

test "the stack check is something the caller asks for" {
    // A program that leaves a value on the stack at `halt` is a correct program: the
    // VM stops and the value goes nowhere. The check is about a program that a
    // compiler wrote, so it is off unless the caller asks.
    const source = "push 1\nhalt";

    const plain = try assemble(testing.allocator, source, null);
    testing.allocator.free(plain);

    const checked = try assembleWithOptions(testing.allocator, source, .{ .check_stack = true }, null);
    testing.allocator.free(checked);
}

test "the stack check finds an instruction with nothing to take" {
    // `add` needs two values and the program gave it one. Without the check this
    // assembles, and the VM traps at run time with no source to point at.
    const source =
        \\  push 1
        \\  add
        \\  halt
    ;

    const unchecked = try assemble(testing.allocator, source, null);
    testing.allocator.free(unchecked);

    var diagnostics: Diagnostics = .{};
    try testing.expectError(
        error.StackUnderflowAt,
        assembleWithOptions(testing.allocator, source, .{ .check_stack = true }, &diagnostics),
    );
    // The failure names the `add`, which is the five bytes of the `push` in.
    try testing.expectEqual(@as(usize, 5), diagnostics.verification.?.offset);
}

test "the stack check follows a call through the frame a function declares" {
    // The function takes one argument and returns one value, so the caller is
    // balanced. This is what a compiler emits, and it is the shape the check follows.
    const source =
        \\entry main
        \\main:
        \\  push 6
        \\  call square
        \\  print
        \\  pop
        \\  halt
        \\square:
        \\  enter 1 0
        \\  load_local 0
        \\  load_local 0
        \\  mul
        \\  ret_val
    ;

    const program = try assembleWithOptions(testing.allocator, source, .{ .check_stack = true }, null);
    testing.allocator.free(program);
}

test "the stack check refuses a function that returns the wrong number of values" {
    const source =
        \\entry main
        \\main:
        \\  call broken
        \\  pop
        \\  halt
        \\broken:
        \\  enter 0 0
        \\  push 1
        \\  push 2
        \\  ret_val
    ;

    try testing.expectError(
        error.UnbalancedReturn,
        assembleWithOptions(testing.allocator, source, .{ .check_stack = true }, null),
    );
}

test "the stack check refuses arms of a branch that leave different heights" {
    const source =
        \\entry main
        \\main:
        \\  push 1
        \\  jmp_zero done
        \\  push 7
        \\done:
        \\  halt
    ;

    try testing.expectError(
        error.InconsistentStackDepth,
        assembleWithOptions(testing.allocator, source, .{ .check_stack = true }, null),
    );
}

test "the stack check cannot follow a call to a function with no frame" {
    // The older calling convention keeps its own stack and declares no arguments, so
    // the height after the call is not something the check can work out. Such a
    // program is still correct and still assembles without the check.
    const source =
        \\entry main
        \\main:
        \\  push 21
        \\  call double
        \\  print
        \\  pop
        \\  halt
        \\double:
        \\  push 2
        \\  mul
        \\  ret
    ;

    const program = try assemble(testing.allocator, source, null);
    testing.allocator.free(program);

    try testing.expectError(
        error.UndeclaredCallTarget,
        assembleWithOptions(testing.allocator, source, .{ .check_stack = true }, null),
    );
}
