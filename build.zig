const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Define executable
    const exe = b.addExecutable(.{
        .name = "handmade_win32",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/handmade_win32.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Separate platform and game layers
    const handmade_game = b.addSharedLibrary(.{
        .name = "handmade_game",
        .root_source_file = b.path("src/handmade.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(handmade_game);

    // win32 API Zig bindings
    const zwin32 = b.dependency("zigwin32", .{});
    exe.root_module.addImport("win32", zwin32.module("win32"));

    b.installArtifact(exe);

    // Run step
    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_exe.step);
}
