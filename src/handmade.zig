// TODO: Services that the platform layer provides to the game
//
// TODO: Services that the game provides to the platform layer.
// (this may expand in the future - sound on separate thread, etc.)

const std = @import("std");

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
    buffer: *GameOffscreenBuffer, 
    blue_offset: i32, 
    green_offset: i32,
    sound_buffer: *GameSoundOutputBuffer,
    tone_hz: i32,
) void {
    // TODO: Allow sample offsets here for more robust platform options
    gameOutputSound(sound_buffer, tone_hz);
    renderWeirdGradient(buffer, blue_offset, green_offset);
}
