const std = @import("std");
const assembler = @import("assembler.zig");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.toSlice(init.arena.allocator());

    // `--check-stack` asks for the operand-stack check as well. It is a separate
    // flag because a correct hand-written program can fail it. See `Options`.
    var options: assembler.Options = .{};
    if (args.len > 1 and std.mem.eql(u8, args[args.len - 1], "--check-stack")) {
        options.check_stack = true;
        args = args[0 .. args.len - 1];
    }

    if (args.len != 4 or !std.mem.eql(u8, args[2], "-o")) {
        std.debug.print("Usage: vigasm <source.vigas> -o <output.vig> [--check-stack]\n", .{});
        return error.InvalidArguments;
    }

    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, .limited(1024 * 1024));
    defer init.gpa.free(source);

    var diagnostics: assembler.Diagnostics = .{};
    const program = assembler.assembleWithOptions(init.gpa, source, options, &diagnostics) catch |err| {
        if (diagnostics.verification) |failure| {
            std.debug.print(
                "Verification failed at code offset {d}: {s}\n",
                .{ failure.offset, @errorName(failure.reason) },
            );
        } else {
            std.debug.print("Assembly failed: {s}\n", .{@errorName(err)});
        }
        return err;
    };
    defer init.gpa.free(program);

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = args[3],
        .data = program,
    });
    std.debug.print("Assembled {d} bytes to {s}\n", .{ program.len, args[3] });
}
