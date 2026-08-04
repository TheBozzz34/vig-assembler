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
    const test_roots = [_][]const u8{ "src/main.zig", "src/assembler.zig" };

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
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
