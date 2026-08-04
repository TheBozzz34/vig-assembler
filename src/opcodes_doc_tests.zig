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

// OPCODES.md is above `src`, which `@embedFile` cannot reach by a relative path.
// `build.zig` gives the file this name with `addAnonymousImport`.
const opcodes_md = @embedFile("opcodes_md");

/// The name that the documentation gives to the operand of an instruction, as it
/// appears after the mnemonic in the Assembly column.
fn operandPlaceholder(kind: OperandKind) []const u8 {
    return switch (kind) {
        .none => "",
        .signed => "value",
        .data_address => "address",
        .code_target => "target",
        .import_index => "name",
        .local_index => "index",
        // `enter` is the one instruction with two operands.
        .frame_shape => "arguments locals",
    };
}

/// The text of the Operand column.
fn operandDescription(kind: OperandKind) []const u8 {
    return switch (kind) {
        .none => "—",
        .signed => "signed `i32`",
        .data_address, .code_target => "unsigned `u32`",
        .import_index => "unsigned `u8` import index",
        .local_index => "unsigned `u16` frame slot",
        .frame_shape => "two unsigned `u16`",
    };
}

/// A bar inside a table cell is written `\|`, because an unescaped one would end
/// the cell. The stack effect of `or` is `a b → a | b`, so it needs this.
fn escapeBars(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const size = std.mem.replacementSize(u8, text, "|", "\\|");
    const result = try allocator.alloc(u8, size);
    _ = std.mem.replace(u8, text, "|", "\\|", result);
    return result;
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
    else effect: {
        const escaped = try escapeBars(allocator, info.stack_effect);
        defer allocator.free(escaped);
        break :effect try std.fmt.allocPrint(allocator, "`{s}`", .{escaped});
    };
    defer allocator.free(effect);

    return std.fmt.allocPrint(allocator, "| {d} | {s} | {s} | {s} | {s} |", .{
        byte,
        assembly,
        operandDescription(kind),
        effect,
        description,
    });
}

/// The five cells of a table row.
///
/// A split on every bar is wrong, because a cell can hold `\|`. This walks the row
/// and steps over an escaped character rather than treating it as a separator.
fn rowCells(row: []const u8, cells: *[5][]const u8) !void {
    if (!std.mem.startsWith(u8, row, "|")) return error.MalformedRow;

    var found: usize = 0;
    var start: usize = 1;
    var position: usize = 1;
    while (position < row.len) {
        switch (row[position]) {
            '\\' => position += 2,
            '|' => {
                if (found == cells.len) return error.MalformedRow;
                cells[found] = std.mem.trim(u8, row[start..position], " ");
                found += 1;
                position += 1;
                start = position;
            },
            else => position += 1,
        }
    }
    if (found != cells.len) return error.MalformedRow;
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
/// file already has. A row is
/// `| byte | assembly | operand | effect | description |`.
fn descriptionOf(row: []const u8) ?[]const u8 {
    var cells: [5][]const u8 = undefined;
    rowCells(row, &cells) catch return null;
    return cells[4];
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
            var cells: [5][]const u8 = undefined;
            rowCells(row, &cells) catch continue;
            const assembly = std.mem.trim(u8, cells[1], "`");
            var words = std.mem.splitScalar(u8, assembly, ' ');
            if (std.mem.eql(u8, words.next() orelse continue, info.mnemonic)) found += 1;
        }
        if (found != 1) {
            std.debug.print("{s} appears in {d} rows of OPCODES.md\n", .{ info.mnemonic, found });
        }
        try std.testing.expectEqual(@as(usize, 1), found);
    }
}
