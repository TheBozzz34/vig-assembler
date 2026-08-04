const std = @import("std");
const assembler = @import("assembler.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4 or !std.mem.eql(u8, args[2], "-o")) {
        std.debug.print("Usage: vigasm <source.vigas> -o <output.vig>\n", .{});
        return error.InvalidArguments;
    }

    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, .limited(1024 * 1024));
    defer init.gpa.free(source);

    var diagnostics: assembler.Diagnostics = .{};
    const program = assembler.assemble(init.gpa, source, &diagnostics) catch |err| {
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
