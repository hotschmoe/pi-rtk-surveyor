const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Release builds drop debug info; `-Dstrip=false` keeps it for gdb/addr2line.
    const strip = b.option(bool, "strip", "Strip debug info (default: on for release modes)") orelse (optimize != .Debug);

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        // rtkd is one thread and one epoll loop by design; this removes the atomics/TLS machinery.
        .single_threaded = true,
        // Tracing and unwind tables only serve stack traces, which a stripped field binary cannot print.
        .error_tracing = false,
        .unwind_tables = if (strip) .none else null,
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
