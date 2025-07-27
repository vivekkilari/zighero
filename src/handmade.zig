// TODO: Services that the platform layer provides to the game
//
// TODO: Services that the game provides to the platform layer.
// (this may expand in the future - sound on separate thread, etc.)

const std = @import("std");
const win_h = @import("win32_handmade.zig");

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

pub const Platform = struct {
    DEBUGPlatformFreeFileMemory: fn (*anyopaque) void = undefined,
    DEBUGPlatformReadEntireFile: fn ([*:0]const u8) struct { u32, ?*anyopaque } = undefined,
    DEBUGPlatformWriteEntireFile: fn ([*:0]const u8, u32, *anyopaque) bool = undefined,
};

pub const GameMemory = struct {
    is_initialized: bool,

    permanent_storage_size: u64,
    permanent_storage: *anyopaque, // NOTE: REQUIRED to be cleared to zero at startup

    transient_storage_size: u64,
    transient_storage: *anyopaque, // NOTE: REQUIRED to be cleared to zero at startup
};

// TODO: In the future, rendering _specifically_ will become a three-tiered abstraction!!!
pub const GameOffscreenBuffer = struct {
    memory: ?*anyopaque,
    width: i32,
    height: i32,
    pitch: i32,
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

pub inline fn getController(input: *GameInput, controller_idx: usize) *GameControllerInput {
    std.debug.assert(controller_idx < input.controllers.len);
    return &input.controllers[controller_idx];
}

pub fn gameOutputSound(sound_buffer: *GameSoundOutputBuffer, tone_hz: i32) void {
    const sound_output = struct {
        var t_sine: f32 = undefined;
    };
    const tone_volume = 3000;

    const wave_period = sound_buffer.samples_per_second / @as(u32, @intCast(tone_hz));

    var sample_out: [*]i16 = sound_buffer.samples;
    for (0..sound_buffer.sample_count) |_| {
        const sine_value: f32 = @sin(sound_output.t_sine);
        const sample_value: i16 = @intFromFloat(
            sine_value * @as(f32, @floatFromInt(tone_volume)));

        sample_out[0] = sample_value;
        sample_out += 1;
        sample_out[0] = sample_value;
        sample_out += 1;

        sound_output.t_sine += std.math.tau /
            @as(f32, @floatFromInt(wave_period));
    }
}

fn renderWeirdGradient(
    buffer: *GameOffscreenBuffer, 
    blue_offset: i32,
    green_offset: i32,
) void {
    var row: [*]u8 = @as(?[*]u8, @ptrCast(buffer.memory)) orelse return;

    // NOTE: Written as bgrx due to endianness flipping
    const rgb = packed struct(u32) {
        b: u8 = 0,
        g: u8 = 0,
        r: u8 = 0,
        _: u8 = 0,
    };

    const b_height: usize = @intCast(buffer.height);
    const b_width: usize = @intCast(buffer.width);

    for (0..b_height) |y| {
        var pixel: [*]rgb = @ptrCast(@alignCast(row));
        for (1..b_width) |x| {
            const blue: u32 = @bitCast(@as(i32, @intCast(x)) + blue_offset);
            const green: u32 = @bitCast(@as(i32, @intCast(y)) + green_offset);

            pixel[x] = .{
                .b = @truncate(blue),
                .g = @truncate(green),
                .r = 0,
            };
        }

        row += @intCast(buffer.pitch);
    }
}

pub fn gameUpdateAndRender(
    platform: *const Platform,
    memory: *GameMemory,
    input: *GameInput,
    buffer: *GameOffscreenBuffer, 
    sound_buffer: *GameSoundOutputBuffer,
) void {
    const GameState = struct {
        tone_hz: i32,
        green_offset:  i32,
        blue_offset: i32,
    };

    std.debug.assert(@sizeOf(GameState) <= memory.permanent_storage_size);
    
    var game_state: *GameState = @alignCast(@ptrCast(memory.permanent_storage));
    if (!memory.is_initialized) {
        const filename = "./handmade.zig";

        const contents_size, const contents_result = platform.DEBUGPlatformReadEntireFile(filename);
        if (contents_result) |contents| {
            _ = platform.DEBUGPlatformWriteEntireFile(
                "../zig-out/data/test.out", 
                contents_size, 
                contents
            );
            platform.DEBUGPlatformFreeFileMemory(contents);
        }

        game_state.tone_hz = 256;

        memory.is_initialized = true;
    }

    for (input.controllers) |controller| {
        if (controller.is_analog) {
            game_state.blue_offset += @intFromFloat(4.0 * controller.stick_average_x);
            game_state.tone_hz = 256 + @as(i32, @intFromFloat(128.0 * controller.stick_average_y));
        } else {
            if (controller.move_left.ended_down) game_state.blue_offset -= 1;
            if (controller.move_right.ended_down) game_state.blue_offset += 1;
        }

        if (controller.action_down.ended_down) {
            game_state.green_offset += 1;
        }
    }

    // TODO: Allow sample offsets here for more robust platform options
    gameOutputSound(sound_buffer, game_state.tone_hz);
    renderWeirdGradient(buffer, game_state.blue_offset, game_state.green_offset);
}
