const std = @import("std");

const max_foreign_args = 4;

const Operand = enum { none, i32_value, value_or_target, u32_address, target, foreign_import };

const Instruction = struct {
    opcode: u8,
    operand: Operand,

    fn size(self: Instruction) usize {
        return switch (self.operand) {
            .none => 1,
            .foreign_import => 2,
            .i32_value, .value_or_target, .u32_address, .target => 5,
        };
    }
};

const ForeignArgType = enum(u8) {
    i32 = 0,
    u32 = 1,
    ptr = 2,
    cstr = 3,
};

const ForeignImport = struct {
    library: []const u8,
    symbol: []const u8,
    arg_types: [max_foreign_args]ForeignArgType = @splat(.u32),
    arg_count: u8 = 0,
};

pub fn assemble(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var labels = std.StringHashMap(usize).init(allocator);
    defer labels.deinit();
    var imports_by_name = std.StringHashMap(u8).init(allocator);
    defer imports_by_name.deinit();
    var imports = std.ArrayList(ForeignImport).empty;
    defer imports.deinit(allocator);

    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = meaningfulLine(raw_line);
        if (line.len == 0) continue;

        if (labelName(line)) |name| {
            if (labels.contains(name)) return error.DuplicateLabel;
            try labels.put(name, offset);
            continue;
        }

        if (isDirective(line, "extern")) {
            const foreign_import = try parseExtern(line);
            if (imports_by_name.contains(foreign_import.name)) return error.DuplicateForeignImport;
            if (imports.items.len >= 256) return error.TooManyForeignImports;
            try imports_by_name.put(foreign_import.name, @intCast(imports.items.len));
            try imports.append(allocator, foreign_import.value);
            continue;
        }

        if (isDirective(line, "asciiz")) {
            offset += (try parseAsciiz(line)).len + 1;
            continue;
        }

        const instruction = try parseInstruction(line);
        offset += instruction.size();
    }

    var header_len: usize = 6;
    for (imports.items) |foreign_import| {
        if (foreign_import.library.len > 255 or foreign_import.symbol.len > 255) return error.ForeignNameTooLong;
        header_len += 3 + foreign_import.arg_count + foreign_import.library.len + foreign_import.symbol.len;
    }

    var output = try std.ArrayList(u8).initCapacity(allocator, header_len + offset);
    errdefer output.deinit(allocator);
    if (imports.items.len > 0) try appendForeignHeader(&output, allocator, imports.items);

    lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = meaningfulLine(raw_line);
        if (line.len == 0 or labelName(line) != null or isDirective(line, "extern")) continue;

        if (isDirective(line, "asciiz")) {
            const contents = try parseAsciiz(line);
            try output.appendSlice(allocator, contents);
            try output.append(allocator, 0);
            continue;
        }

        var tokens = std.mem.tokenizeAny(u8, line, " \t,");
        const operation = tokens.next() orelse unreachable;
        const instruction = try instructionFor(operation);
        try output.append(allocator, instruction.opcode);

        switch (instruction.operand) {
            .none => if (tokens.next() != null) return error.UnexpectedOperand,
            .i32_value => {
                const operand = tokens.next() orelse return error.MissingOperand;
                if (tokens.next() != null) return error.UnexpectedOperand;
                const value = try std.fmt.parseInt(i32, operand, 0);
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(i32, &bytes, value, .little);
                try output.appendSlice(allocator, &bytes);
            },
            .value_or_target => {
                const operand = tokens.next() orelse return error.MissingOperand;
                if (tokens.next() != null) return error.UnexpectedOperand;
                const address = labels.get(operand) orelse try std.fmt.parseInt(usize, operand, 0);
                if (address > std.math.maxInt(i32)) return error.AddressOutOfRange;
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(i32, &bytes, @intCast(address), .little);
                try output.appendSlice(allocator, &bytes);
            },
            .u32_address => {
                const operand = tokens.next() orelse return error.MissingOperand;
                if (tokens.next() != null) return error.UnexpectedOperand;
                const value = try std.fmt.parseInt(u32, operand, 0);
                try appendU32(&output, allocator, value);
            },
            .target => {
                const operand = tokens.next() orelse return error.MissingOperand;
                if (tokens.next() != null) return error.UnexpectedOperand;
                const value = labels.get(operand) orelse try std.fmt.parseInt(usize, operand, 0);
                if (value > std.math.maxInt(u32)) return error.AddressOutOfRange;
                try appendU32(&output, allocator, @intCast(value));
            },
            .foreign_import => {
                const operand = tokens.next() orelse return error.MissingOperand;
                if (tokens.next() != null) return error.UnexpectedOperand;
                const index = imports_by_name.get(operand) orelse return error.UnknownForeignImport;
                try output.append(allocator, index);
            },
        }
    }

    return output.toOwnedSlice(allocator);
}

fn appendForeignHeader(output: *std.ArrayList(u8), allocator: std.mem.Allocator, imports: []const ForeignImport) !void {
    try output.appendSlice(allocator, "VIGF");
    try output.append(allocator, 1); // container version
    try output.append(allocator, @intCast(imports.len));
    for (imports) |foreign_import| {
        try output.append(allocator, @intCast(foreign_import.library.len));
        try output.append(allocator, @intCast(foreign_import.symbol.len));
        try output.append(allocator, foreign_import.arg_count);
        for (foreign_import.arg_types[0..foreign_import.arg_count]) |arg_type| {
            try output.append(allocator, @intFromEnum(arg_type));
        }
        try output.appendSlice(allocator, foreign_import.library);
        try output.appendSlice(allocator, foreign_import.symbol);
    }
}

fn appendU32(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try output.appendSlice(allocator, &bytes);
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

fn parseExtern(line: []const u8) !struct { name: []const u8, value: ForeignImport } {
    var tokens = std.mem.tokenizeAny(u8, line, " \t,");
    _ = tokens.next(); // extern
    const name = tokens.next() orelse return error.MissingOperand;
    const library = tokens.next() orelse return error.MissingOperand;
    const symbol = tokens.next() orelse return error.MissingOperand;

    var foreign_import = ForeignImport{ .library = library, .symbol = symbol };
    while (tokens.next()) |type_name| {
        if (foreign_import.arg_count >= max_foreign_args) return error.TooManyForeignArguments;
        foreign_import.arg_types[foreign_import.arg_count] = try foreignArgTypeFor(type_name);
        foreign_import.arg_count += 1;
    }
    return .{ .name = name, .value = foreign_import };
}

fn foreignArgTypeFor(name: []const u8) !ForeignArgType {
    const definitions = .{
        .{ "i32", .i32 }, .{ "u32", .u32 }, .{ "ptr", .ptr }, .{ "cstr", .cstr },
    };
    inline for (definitions) |definition| {
        if (std.mem.eql(u8, name, definition[0])) return definition[1];
    }
    return error.UnknownForeignType;
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

fn parseInstruction(line: []const u8) !Instruction {
    var tokens = std.mem.tokenizeAny(u8, line, " \t,");
    const operation = tokens.next() orelse return error.InvalidSyntax;
    const instruction = try instructionFor(operation);

    if (instruction.operand == .none) {
        if (tokens.next() != null) return error.UnexpectedOperand;
    } else {
        _ = tokens.next() orelse return error.MissingOperand;
        if (tokens.next() != null) return error.UnexpectedOperand;
    }
    return instruction;
}

fn instructionFor(operation: []const u8) !Instruction {
    const definitions = .{
        .{ "halt", 0, .none }, .{ "push", 1, .value_or_target },
        .{ "add", 2, .none }, .{ "sub", 3, .none }, .{ "print", 4, .none },
        .{ "dup", 5, .none }, .{ "pop", 6, .none }, .{ "swap", 7, .none },
        .{ "mul", 8, .none }, .{ "div", 9, .none }, .{ "mod", 10, .none },
        .{ "eq", 11, .none }, .{ "ne", 12, .none }, .{ "lt", 13, .none },
        .{ "lte", 14, .none }, .{ "gt", 15, .none }, .{ "gte", 16, .none },
        .{ "jmp", 17, .target }, .{ "jmp_zero", 18, .target },
        .{ "jmp_not_zero", 19, .target }, .{ "load", 20, .u32_address },
        .{ "store", 21, .u32_address }, .{ "call", 22, .target }, .{ "ret", 23, .none },
        .{ "foreign_call", 24, .foreign_import },
    };

    inline for (definitions) |definition| {
        if (std.mem.eql(u8, operation, definition[0])) {
            return .{ .opcode = definition[1], .operand = definition[2] };
        }
    }
    return error.UnknownOpcode;
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
        1, 40, 0, 0, 0,
        21, 0, 0, 0, 0,
        22, 17, 0, 0, 0,
        4, 0,
        20, 0, 0, 0, 0,
        1, 2, 0, 0, 0,
        2, 23,
    };

    const output = try assemble(std.testing.allocator, source);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualSlices(u8, &expected, output);
}

test "assembles a foreign-import container and call" {
    const source =
        \\extern GetCurrentProcessId kernel32.dll GetCurrentProcessId
        \\foreign_call GetCurrentProcessId
        \\halt
    ;
    const expected = "VIGF" ++ [_]u8{ 1, 1, 12, 19, 0 } ++
        "kernel32.dllGetCurrentProcessId" ++ [_]u8{ 24, 0, 0 };
    const output = try assemble(std.testing.allocator, source);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualSlices(u8, &expected, output);
}

test "rejects an unresolved control-flow label" {
    try std.testing.expectError(error.InvalidCharacter, assemble(std.testing.allocator, "call missing\nhalt"));
}
