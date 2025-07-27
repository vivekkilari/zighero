const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Define executable
    const exe = b.addExecutable(.{
        .name = "zighero",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/win32_handmade.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.linkSystemLibrary("User32");
    exe.linkSystemLibrary("Gdi32");
    exe.linkSystemLibrary("winmm");


    // win32 API Zig bindings
    const zwin32 = b.dependency("zigwin32", .{});
    exe.root_module.addImport("win32", zwin32.module("win32"));

    b.installArtifact(exe);

    // Run step
    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_exe.step);
}
