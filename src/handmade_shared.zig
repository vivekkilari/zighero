///! Shared code, not reliant on dynamic linking
const std = @import("std");

// Data Types --------------------------------------------------------------------------------------
pub const GameState = struct {
    tone_hz: i32,
    green_offset:  i32,
    blue_offset: i32,

    t_sine: f32,

    player_x: i32,
    player_y: i32,
    t_jump: f32,
};

pub const DebugFileResult = extern struct {
    contents_size: u32 = 0, 
    contents: *anyopaque = undefined,
};

pub const GameMemory = struct {
    is_initialized: bool = false,

    permanent_storage_size: u64 = 0,
    permanent_storage: *anyopaque = undefined, // NOTE: REQUIRED to be cleared to zero at startup

    transient_storage_size: u64 = 0,
    transient_storage: *anyopaque = undefined, // NOTE: REQUIRED to be cleared to zero at startup

    DEBUGPlatformReadEntireFile: *const fn (file_name: [*:0]const u8) callconv(.C) DebugFileResult = undefined,
    DEBUGPlatformFreeFileMemory: *const fn (memory: *anyopaque) callconv(.C) void = undefined,
    DEBUGPlatformWriteEntireFile: *const fn (file_name: [*:0]const u8, memory_size: u32, memory: *anyopaque) callconv(.C) bool = undefined,
};

// TODO: In the future, rendering _specifically_ will become a three-tiered abstraction!!!
pub const GameOffscreenBuffer = struct {
    memory: ?*anyopaque,
    width: i32,
    height: i32,
    pitch: i32,
    bytes_per_pixel: i32,
};

pub const GameSoundOutputBuffer = struct {
    samples_per_second: u32,
    sample_count: u32,
    samples: [*]i16,
};

pub const GameButtonState = struct {
    half_transition_count: u32 = 0,
    ended_down: bool = false,
};

pub const GameControllerInput = struct {
    is_connected: bool = false,
    is_analog: bool = false,
    stick_average_x: f32 = 0,
    stick_average_y: f32 = 0,

    move_up: GameButtonState = .{},
    move_down: GameButtonState = .{},
    move_left: GameButtonState = .{},
    move_right: GameButtonState = .{},

    action_up: GameButtonState = .{},
    action_down: GameButtonState = .{},
    action_left: GameButtonState = .{},
    action_right: GameButtonState = .{},

    left_shoulder: GameButtonState = .{},
    right_shoulder: GameButtonState = .{},

    start: GameButtonState = .{},
    back: GameButtonState = .{},

    pub const button_count: u8 =  blk: {
        var count = 0;
        for (@typeInfo(GameControllerInput).@"struct".fields) |field| {
            if (field.type == GameButtonState) count += 1;
        }
        break :blk count;
    };

    pub fn button(self: *GameControllerInput, idx: usize) *GameButtonState {
        return switch (idx) {
            0 => &self.move_up,
            1 => &self.move_down,
            2 => &self.move_left,
            3 => &self.move_right,
            4 => &self.action_up,
            5 => &self.action_down,
            6 => &self.action_left,
            7 => &self.action_right,
            8 => &self.left_shoulder,
            9 => &self.right_shoulder,
            10 => &self.start,
            11 => &self.back,
            else => unreachable,
        };
    }
};

pub const GameInput = struct {
    // TODO: Insert clock values here
    controllers: [5]GameControllerInput = undefined,
};

// Public Functions -------------------------------------------------------------------------------

pub fn kilobytes(comptime count: comptime_int) comptime_int {
    return count * 1024;
}

pub fn megabytes(comptime count: comptime_int) comptime_int {
    return kilobytes(count) * 1024;
}

pub fn gigabytes(comptime count: comptime_int) comptime_int {
    return megabytes(count) * 1024;
}

pub fn terabytes(comptime count: comptime_int) comptime_int {
    return gigabytes(count) * 1024;
}

pub inline fn getController(input: *GameInput, controller_idx: usize) *GameControllerInput {
    std.debug.assert(controller_idx < input.controllers.len);
    return &input.controllers[controller_idx];
}

// Stubs

pub fn gameUpdateAndRenderStub(
    _: *GameMemory,
    _: *GameInput,
    _: *GameOffscreenBuffer, 
) callconv(.C) void {
    return;
}

pub fn gameGetSoundSamplesStub(
    _: *GameMemory,
    _: *GameSoundOutputBuffer, 
) callconv(.C) void {
    return;
}

