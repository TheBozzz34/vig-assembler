const std = @import("std");

const Operand = enum { none, i32_value, u32_address, target };

const Instruction = struct {
    opcode: u8,
    operand: Operand,

    fn size(self: Instruction) usize {
        return switch (self.operand) {
            .none => 1,
            .i32_value, .u32_address, .target => 5,
        };
    }
};

pub fn assemble(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var labels = std.StringHashMap(usize).init(allocator);
    defer labels.deinit();

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

        const instruction = try parseInstruction(line);
        offset += instruction.size();
    }

    var output = try std.ArrayList(u8).initCapacity(allocator, offset);
    errdefer output.deinit(allocator);

    lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = meaningfulLine(raw_line);
        if (line.len == 0 or labelName(line) != null) continue;

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
        }
    }

    return output.toOwnedSlice(allocator);
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
        .{ "halt", 0, .none }, .{ "push", 1, .i32_value },
        .{ "add", 2, .none }, .{ "sub", 3, .none }, .{ "print", 4, .none },
        .{ "dup", 5, .none }, .{ "pop", 6, .none }, .{ "swap", 7, .none },
        .{ "mul", 8, .none }, .{ "div", 9, .none }, .{ "mod", 10, .none },
        .{ "eq", 11, .none }, .{ "ne", 12, .none }, .{ "lt", 13, .none },
        .{ "lte", 14, .none }, .{ "gt", 15, .none }, .{ "gte", 16, .none },
        .{ "jmp", 17, .target }, .{ "jmp_zero", 18, .target },
        .{ "jmp_not_zero", 19, .target }, .{ "load", 20, .u32_address },
        .{ "store", 21, .u32_address }, .{ "call", 22, .target }, .{ "ret", 23, .none },
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

test "rejects an unresolved control-flow label" {
    try std.testing.expectError(error.InvalidCharacter, assemble(std.testing.allocator, "call missing\nhalt"));
}
