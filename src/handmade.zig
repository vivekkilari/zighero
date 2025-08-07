// TODO: Services that the platform layer provides to the game
//
// TODO: Services that the game provides to the platform layer.
// (this may expand in the future - sound on separate thread, etc.)

const std = @import("std");
const shared = @import("handmade_shared.zig");

fn gameOutputSound(
    game_state: *shared.GameState,
    sound_buffer: *shared.GameSoundOutputBuffer,
    tone_hz: i32,
) void {
    const tone_volume = 3000;

    const wave_period = sound_buffer.samples_per_second / @as(u32, @intCast(tone_hz));

    var sample_out: [*]i16 = sound_buffer.samples;
    for (0..sound_buffer.sample_count) |idx| {
        const sine_value: f32 = 
            if (false) @sin(game_state.t_sine) else 0;
        const sample_value: i16 = @intFromFloat(
            sine_value * @as(f32, @floatFromInt(tone_volume)));

        sample_out[idx * 2] = sample_value;
        sample_out[idx * 2 + 1] = sample_value;

        game_state.t_sine += std.math.tau /
            @as(f32, @floatFromInt(wave_period));
        if (game_state.t_sine > std.math.tau) 
            game_state.t_sine -= std.math.tau;
    }
}

fn renderWeirdGradient(
    buffer: *shared.GameOffscreenBuffer, 
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

fn renderPlayer(buffer: *shared.GameOffscreenBuffer, player_x: i32, player_y: i32) void {
    const mem_ptr = @as([*]u8, @ptrCast(buffer.memory.?));
    const buf_end = mem_ptr + 
        @as(u32, @intCast(buffer.pitch * buffer.height));


    const color = 0xFFFFFFFF;
    const top = player_y;
    const bottom = player_y +% 10;

    var x = player_x;
    while (x < player_x +% 10) : (x += 1) {
        var pixel_adr: [*]u8 = mem_ptr + 
            (@as(u32, @bitCast(x)) *| @as(u32, @intCast(buffer.bytes_per_pixel))) + 
            (@as(u32, @bitCast(top *| buffer.pitch)));
        var y = top;
        while (y < bottom) : (y += 1) {
            if (@intFromPtr(pixel_adr) >= @intFromPtr(mem_ptr) and
                @intFromPtr(pixel_adr + 4) <= @intFromPtr(buf_end)) {
                const pixel: [*]u32 = @alignCast(@ptrCast(pixel_adr));
                pixel[0] = color;
            }
            pixel_adr += @intCast(buffer.pitch);
        }
    }
}

pub export fn gameUpdateAndRender(
    memory: *shared.GameMemory,
    input: *shared.GameInput,
    buffer: *shared.GameOffscreenBuffer, 
) callconv(.C) void {
    std.debug.assert(@sizeOf(shared.GameState) <= memory.permanent_storage_size);

    var game_state: *shared.GameState = @alignCast(@ptrCast(memory.permanent_storage));
    if (!memory.is_initialized) {
        const filename = "./handmade.zig";

        const dbg_result = memory.DEBUGPlatformReadEntireFile(filename);

        _ = memory.DEBUGPlatformWriteEntireFile(
            "../zig-out/data/test.out", 
            dbg_result.contents_size, 
            dbg_result.contents
        );
        memory.DEBUGPlatformFreeFileMemory(dbg_result.contents);

        game_state.tone_hz = 512;
        game_state.t_sine = 0;

        game_state.player_x = 100;
        game_state.player_y = 100;

        memory.is_initialized = true;
    }

    for (input.controllers) |controller| {
        if (controller.is_analog) {
            game_state.blue_offset +%= @intFromFloat(4.0 * controller.stick_average_x);
            game_state.tone_hz = 512 + @as(i32, @intFromFloat(128.0 * controller.stick_average_y));
        } else {
            if (controller.move_left.ended_down) game_state.blue_offset -%= 1;
            if (controller.move_right.ended_down) game_state.blue_offset +%= 1;
        }

        if (controller.action_down.ended_down) {
            game_state.green_offset +%= 1;
        }


        game_state.player_x +%= @intFromFloat(7.0 * controller.stick_average_x);
        game_state.player_y -%= @as(i32, @intFromFloat((7.0 * controller.stick_average_y)));
        if (game_state.t_jump > 0) {
            game_state.player_y +%= @intFromFloat(
                10 * std.math.sin(0.5 * std.math.pi * game_state.t_jump));
        }

        if (controller.action_down.ended_down) {
            game_state.t_jump = 5;
        }
        game_state.t_jump -= 0.033;
    }

    renderWeirdGradient(buffer, game_state.blue_offset, game_state.green_offset);
    renderPlayer(buffer, game_state.player_x, game_state.player_y);
}

pub export fn gameGetSoundSamples(
    memory: *shared.GameMemory, 
    sound_buffer: *shared.GameSoundOutputBuffer,
) callconv(.C) void {
    const game_state: *shared.GameState = @alignCast(@ptrCast(memory.permanent_storage));
    gameOutputSound(game_state, sound_buffer, game_state.tone_hz);
}



