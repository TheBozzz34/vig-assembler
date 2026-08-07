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
    // `--vig64` selects the version-2 wide object format. It is deliberately
    // explicit while the VIG32 command-line form remains available.
    var relocatable = false;
    var vig64 = false;
    var first: usize = 1;
    while (first < args.len) {
        if (std.mem.eql(u8, args[first], "-c")) {
            relocatable = true;
            first += 1;
        } else if (std.mem.eql(u8, args[first], "--vig64")) {
            vig64 = true;
            first += 1;
        } else break;
    }

    if (args.len != first + 3 or !std.mem.eql(u8, args[first + 1], "-o")) {
        usage();
        return error.InvalidArguments;
    }
    // Nothing in an object is verified, so there is no stack to check yet. The
    // linker runs both checks on the program it produces.
    if ((relocatable and options.check_stack) or (vig64 and !relocatable)) {
        usage();
        return error.InvalidArguments;
    }
    const output_path = args[first + 2];

    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, args[first], init.gpa, .limited(1024 * 1024));
    defer init.gpa.free(source);

    var diagnostics: assembler.Diagnostics = .{};
    const program = (if (relocatable)
        if (vig64) assembler.assembleVig64Object(init.gpa, source) else assembler.assembleObject(init.gpa, source)
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
        \\       vigasm -c [--vig64] <source.vigas> -o <output.vigo>
        \\
    , .{});
}
