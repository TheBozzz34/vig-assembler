//! A check that OPCODES.md still describes the instruction set.
//!
//! The reference table in OPCODES.md repeats what `vig_bytecode.opcode.table`
//! already holds: the byte, the mnemonic, the operand kind and the stack effect of
//! every instruction. Nothing connected the two, so an instruction could join the
//! set and the documented table would stay as it was, with no message.
//!
//! The four mechanical columns are checked here against the shared table. The
//! Description column is not: those sentences are written for a reader, and
//! several of them say more than the one-line `summary` of an instruction does.
//! An author is free to improve them.
//!
//! When this test fails it prints the row that the table asks for, so the fix is
//! to paste that row into OPCODES.md.

const std = @import("std");
const bytecode = @import("vig_bytecode");

const OpCode = bytecode.OpCode;
const OperandKind = bytecode.OperandKind;

const opcodes_md = @embedFile("../OPCODES.md");

/// The name that the documentation gives to the operand of an instruction, as it
/// appears after the mnemonic in the Assembly column.
fn operandPlaceholder(kind: OperandKind) []const u8 {
    return switch (kind) {
        .none => "",
        .signed => "value",
        .data_address => "address",
        .code_target => "target",
        .import_index => "name",
    };
}

/// The text of the Operand column.
fn operandDescription(kind: OperandKind) []const u8 {
    return switch (kind) {
        .none => "—",
        .signed => "signed `i32`",
        .data_address, .code_target => "unsigned `u32`",
        .import_index => "unsigned `u8` import index",
    };
}

/// The row that OPCODES.md must hold for one instruction. The Description column
/// is the text that the file already has, because this check does not own it.
fn expectedRow(
    allocator: std.mem.Allocator,
    byte: u8,
    info: bytecode.Info,
    description: []const u8,
) ![]u8 {
    const kind = info.operand;
    const placeholder = operandPlaceholder(kind);

    const assembly = if (placeholder.len == 0)
        try std.fmt.allocPrint(allocator, "`{s}`", .{info.mnemonic})
    else
        try std.fmt.allocPrint(allocator, "`{s} {s}`", .{ info.mnemonic, placeholder });
    defer allocator.free(assembly);

    const effect = if (info.stack_effect.len == 0)
        try allocator.dupe(u8, "—")
    else
        try std.fmt.allocPrint(allocator, "`{s}`", .{info.stack_effect});
    defer allocator.free(effect);

    return std.fmt.allocPrint(allocator, "| {d} | {s} | {s} | {s} | {s} |", .{
        byte,
        assembly,
        operandDescription(kind),
        effect,
        description,
    });
}

/// The rows of the instruction table in OPCODES.md, in the order that the file has
/// them.
fn documentedRows(allocator: std.mem.Allocator) ![][]const u8 {
    var rows: std.ArrayList([]const u8) = .empty;
    errdefer rows.deinit(allocator);

    var lines = std.mem.splitScalar(u8, opcodes_md, '\n');
    // Find the header of the table, then step over the alignment row that comes
    // after it.
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "| Byte |")) break;
    } else return error.NoInstructionTable;
    _ = lines.next() orelse return error.NoInstructionTable;

    // The table ends at the first line that is not a row.
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (!std.mem.startsWith(u8, line, "|")) break;
        try rows.append(allocator, line);
    }
    return rows.toOwnedSlice(allocator);
}

/// The Description column of a row, so a comparison can keep the text that the
/// file already has.
fn descriptionOf(row: []const u8) ?[]const u8 {
    // A row is `| byte | assembly | operand | effect | description |`. The
    // description is the fifth of the five cells.
    var cells = std.mem.splitScalar(u8, row, '|');
    _ = cells.next(); // the empty text before the first bar
    for (0..3) |_| _ = cells.next() orelse return null;
    const description = cells.next() orelse return null;
    return std.mem.trim(u8, description, " ");
}

test "OPCODES.md documents every instruction, in order, with its operand and effect" {
    const allocator = std.testing.allocator;

    const rows = try documentedRows(allocator);
    defer allocator.free(rows);

    // A missing row and an extra row are both failures. Without this check an
    // instruction added to the end of the set would be documented by nothing.
    if (rows.len != bytecode.opcode.table.len) {
        std.debug.print(
            "OPCODES.md has {d} instruction rows and the instruction set has {d}.\n",
            .{ rows.len, bytecode.opcode.table.len },
        );
    }
    try std.testing.expectEqual(bytecode.opcode.table.len, rows.len);

    for (bytecode.opcode.table, rows, 0..) |info, row, index| {
        const byte: u8 = @intCast(index);
        const description = descriptionOf(row) orelse {
            std.debug.print("row {d} of OPCODES.md has too few columns: {s}\n", .{ index, row });
            return error.MalformedRow;
        };

        const expected = try expectedRow(allocator, byte, info, description);
        defer allocator.free(expected);

        std.testing.expectEqualStrings(expected, row) catch |err| {
            std.debug.print(
                "OPCODES.md does not match the instruction table at byte {d} ({s}).\n" ++
                    "The row that the table asks for is:\n{s}\n",
                .{ byte, info.mnemonic, expected },
            );
            return err;
        };
    }
}

test "the documented table covers each mnemonic exactly one time" {
    const allocator = std.testing.allocator;

    const rows = try documentedRows(allocator);
    defer allocator.free(rows);

    for (bytecode.opcode.table) |info| {
        var found: usize = 0;
        for (rows) |row| {
            // The mnemonic is inside backticks in the Assembly column, and it is
            // either the whole cell or the part before the operand name.
            var cells = std.mem.splitScalar(u8, row, '|');
            _ = cells.next();
            _ = cells.next() orelse continue;
            const assembly = std.mem.trim(u8, cells.next() orelse continue, " `");
            var words = std.mem.splitScalar(u8, assembly, ' ');
            if (std.mem.eql(u8, words.next() orelse continue, info.mnemonic)) found += 1;
        }
        if (found != 1) {
            std.debug.print("{s} appears in {d} rows of OPCODES.md\n", .{ info.mnemonic, found });
        }
        try std.testing.expectEqual(@as(usize, 1), found);
    }
}
