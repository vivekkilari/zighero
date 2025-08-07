const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Define platform dependant executable
    var handmade_platform = b.addExecutable(.{
        .name = "handmade_win32",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/handmade_win32.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .win32_manifest = .{.cwd_relative = "dist/windows/handmade.manifest"},
    });

    // Defined game code as shared library
    const handmade_game = b.addSharedLibrary(.{
        .name = "handmade_game",
        .root_source_file = b.path("src/handmade.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add win32 API zig bindings
    const zigwin32 = b.dependency("zigwin32", .{});
    handmade_platform.root_module.addImport("win32", zigwin32.module("win32"));

    // Install artifact
    // Needed to use zig build run on 
    // zig-out instead of .zig-cache
    const install_handmade_platform = b.addInstallArtifact(handmade_platform, .{});
    b.getInstallStep().dependOn(&install_handmade_platform.step);

    const install_handmade_game = b.addInstallArtifact(handmade_game, .{});

    // Game code dll
    b.installArtifact(handmade_game);

    // Run artifact
    const run_exe = b.addRunArtifact(handmade_platform);
    run_exe.step.dependOn(&install_handmade_platform.step);
    run_exe.step.dependOn(&install_handmade_game.step);

    // Run step
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_exe.step);
}
