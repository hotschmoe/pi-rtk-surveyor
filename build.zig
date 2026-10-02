const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{ .name = "rtkd", .root_module = root });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run rtkd on this machine").dependOn(&run.step);

    // Unit tests run natively on the dev box (also aarch64). Fixtures under
    // tests/fixtures are real receiver captures, read relative to the repo root.
    const tests = b.addTest(.{ .root_module = root });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
