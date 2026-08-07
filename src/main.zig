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

    // `-c` makes a relocatable object for the linker instead of a program.
    var relocatable = false;
    var first: usize = 1;
    if (args.len > 1 and std.mem.eql(u8, args[1], "-c")) {
        relocatable = true;
        first = 2;
    }

    if (args.len != first + 3 or !std.mem.eql(u8, args[first + 1], "-o")) {
        usage();
        return error.InvalidArguments;
    }
    // Nothing in an object is verified, so there is no stack to check yet. The
    // linker runs both checks on the program it produces.
    if (relocatable and options.check_stack) {
        usage();
        return error.InvalidArguments;
    }
    const output_path = args[first + 2];

    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, args[first], init.gpa, .limited(1024 * 1024));
    defer init.gpa.free(source);

    var diagnostics: assembler.Diagnostics = .{};
    const program = (if (relocatable)
        assembler.assembleObject(init.gpa, source)
    else
        assembler.assembleWithOptions(init.gpa, source, options, &diagnostics)) catch |err| {
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
        .sub_path = output_path,
        .data = program,
    });
    std.debug.print("Assembled {d} bytes to {s}\n", .{ program.len, output_path });
}

fn usage() void {
    std.debug.print(
        \\Usage: vigasm <source.vigas> -o <output.vig> [--check-stack]
        \\       vigasm -c <source.vigas> -o <output.vigo>
        \\
    , .{});
}
