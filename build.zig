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
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // The map viewer's geometry core (src/geom): unit tests natively, and the WebAssembly build that
    // the daemon embeds as src/map.wasm. The built file is committed so the daemon build needs no extra
    // step; `scripts/build-wasm.sh` rebuilds it and `tools/test_wasm.js` fails if it is stale.
    const geom_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/geom/wasm.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(geom_tests).step);

    const wasm_opt = b.option(std.builtin.OptimizeMode, "wasm-optimize", "Optimize mode of the wasm build (default ReleaseSmall)") orelse .ReleaseSmall;
    const wasm = b.addExecutable(.{ .name = "map", .root_module = b.createModule(.{
        .root_source_file = b.path("src/geom/wasm.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = wasm_opt,
        .strip = true,
        .single_threaded = true,
    }) });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.stack_size = 64 * 1024;
    const wasm_out = b.option([]const u8, "wasm-out", "Copy the built wasm to this path under the source tree (default src/map.wasm)") orelse "src/map.wasm";
    const update = b.addUpdateSourceFiles();
    update.addCopyFileToSource(wasm.getEmittedBin(), wasm_out);
    b.step("wasm", "Build the viewer's WebAssembly core into src/map.wasm").dependOn(&update.step);
}
