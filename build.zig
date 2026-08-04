const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The assembler shares the opcodes, the container format and the verifier
    // with the VM. This build does not make them again.
    const bytecode = b.dependency("vig_bytecode", .{
        .target = target,
        .optimize = optimize,
    }).module("vig_bytecode");

    // This module is available to each dependent package, in the same way as
    // `vig_bytecode`. The assembler is a library first and the `vigasm`
    // executable second. Therefore the VM can assemble a program in a test and
    // then run it, and no test has to encode instruction bytes by hand.
    _ = b.addModule("vig_assembler", .{
        .root_source_file = b.path("src/assembler.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vig_bytecode", .module = bytecode }},
    });

    const exe = b.addExecutable(.{
        .name = "vigasm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vig_bytecode", .module = bytecode }},
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the assembler");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    // A test executable collects the `test` blocks from its own root file only.
    // Therefore each source file that has tests needs an entry here. With
    // `main.zig` as the only root, the build ran no test and gave no message.
    const test_roots = [_][]const u8{
        "src/main.zig",
        "src/assembler.zig",
        // This root embeds OPCODES.md and checks it against the shared instruction
        // table. `@embedFile` makes the file an input of the build, so the check
        // runs again when the documentation changes.
        "src/opcodes_doc_tests.zig",
    };

    const test_step = b.step("test", "Run unit tests");
    for (test_roots) |root| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "vig_bytecode", .module = bytecode }},
            }),
        });

        // `@embedFile` reads a path inside the directory of the root module, and
        // OPCODES.md is above `src`. An anonymous import gives the file a name
        // that the test can embed, and makes it an input of the build.
        if (std.mem.eql(u8, root, "src/opcodes_doc_tests.zig")) {
            tests.root_module.addAnonymousImport("opcodes_md", .{
                .root_source_file = b.path("OPCODES.md"),
            });
        }

        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
