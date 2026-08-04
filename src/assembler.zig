const std = @import("std");
const bytecode = @import("vig_bytecode");

const container = bytecode.container;
const encode = bytecode.encode;
const foreign = bytecode.foreign;
const verify = bytecode.verify;
const OpCode = bytecode.OpCode;

/// The region of the program that a label points into. The assembler makes the
/// static data apart from the code. Therefore it knows the final address of a
/// data label only after it knows the length of the code. That address is
/// `code_len + offset`.
const Region = enum { code, data };

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

/// Assemble `source` into a VIG container. The verifier then makes sure that:
///
/// - each instruction that the program can reach decodes;
/// - each branch goes to the first byte of an instruction;
/// - control does not continue past the end of the code.
pub fn assemble(allocator: std.mem.Allocator, source: []const u8, diagnostics: ?*Diagnostics) ![]u8 {
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

        var tokens = std.mem.tokenizeAny(u8, line, " \t,");
        const instruction = try opCodeFor(tokens.next() orelse unreachable);
        const operand = try parseOperand(
            instruction,
            &tokens,
            .{ .labels = &labels, .imports_by_name = &imports_by_name, .code_len = code_len },
        );

        var buffer: [8]u8 = undefined;
        const size = try encode.encode(&buffer, instruction, operand);
        try code.appendSlice(allocator, buffer[0..size]);
    }

    const entry_point = try resolveEntryPoint(entry_label, &labels);
    try verifyProgram(allocator, code.items, entry_point, imports.items.len, diagnostics);

    const layout: container.Layout = .{
        .imports = imports.items,
        .code = code.items,
        .data = data.items,
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

    /// The absolute address of a label in the program image. That image is the
    /// code region, then the static-data region.
    fn address(self: Scope, name: []const u8) ?usize {
        const label = self.labels.get(name) orelse return null;
        return switch (label.region) {
            .code => label.offset,
            .data => self.code_len + label.offset,
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
    if (tokens.next() != null) return error.UnexpectedOperand;

    const label = if (kind.acceptsLabel()) scope.address(text) else null;
    return switch (kind) {
        .none => unreachable,
        .signed => .{ .signed = if (label) |value|
            std.math.cast(i32, value) orelse return error.AddressOutOfRange
        else
            try std.fmt.parseInt(i32, text, 0) },
        .code_target => .{ .code_target = try codeTarget(label, text) },
        .data_address => .{ .data_address = try std.fmt.parseInt(u32, text, 0) },
        .import_index => .{
            .import_index = scope.imports_by_name.get(text) orelse return error.UnknownForeignImport,
        },
    };
}

fn codeTarget(label: ?usize, text: []const u8) !u32 {
    const value = label orelse try std.fmt.parseInt(usize, text, 0);
    return std.math.cast(u32, value) orelse error.AddressOutOfRange;
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
    import_count: usize,
    diagnostics: ?*Diagnostics,
) !void {
    const scratch = try allocator.alloc(verify.Mark, verify.scratchSize(code.len));
    defer allocator.free(scratch);

    var failure: verify.Failure = undefined;
    verify.verify(.{
        .code = code,
        .entry_point = entry_point,
        .import_count = @intCast(import_count),
    }, scratch, &failure) catch |err| {
        if (diagnostics) |slot| slot.verification = failure;
        return err;
    };
}

fn meaningfulLine(raw_line: []const u8) []const u8 {
    const uncommented = if (std.mem.indexOfAny(u8, raw_line, ";#")) |comment_start|
        raw_line[0..comment_start]
    else
        raw_line;
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

/// Check the form of an instruction line in pass one, before the labels have
/// addresses.
fn parseInstruction(line: []const u8) !OpCode {
    var tokens = std.mem.tokenizeAny(u8, line, " \t,");
    const instruction = try opCodeFor(tokens.next() orelse return error.InvalidSyntax);

    if (instruction.operandKind() == .none) {
        if (tokens.next() != null) return error.UnexpectedOperand;
    } else {
        _ = tokens.next() orelse return error.MissingOperand;
        if (tokens.next() != null) return error.UnexpectedOperand;
    }
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
    const source =
        \\start:
        \\  push 40
        \\  store 0
        \\  call increment
        \\  print
        \\  halt
        \\increment:
        \\  load 0
        \\  push 2
        \\  add
        \\  ret
    ;
    const expected = [_]u8{
        1,  40, 0,  0, 0,
        21, 0,  0,  0, 0,
        22, 17, 0,  0, 0,
        4,  0,
        20, 0,  0,  0, 0,
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
        \\halt
    ;

    try expectRegions(source, &[_]u8{ 28, 29, 30, 31, 32, 33, 34, 35, 36, 0 }, "");
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
    // A data address is never a label. Therefore a label in that position is a
    // failure in the parse.
    try testing.expectError(
        error.InvalidCharacter,
        assemble(testing.allocator, "store here\nhere:\nhalt", null),
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

test "an empty source assembles to an empty program" {
    const output = try assemble(testing.allocator, "# nothing but a comment\n", null);
    defer testing.allocator.free(output);

    const image = try container.parse(output);
    try testing.expectEqual(@as(usize, 0), image.imageLen());
    try testing.expectEqual(@as(u32, 0), image.header.entry_point);
}
