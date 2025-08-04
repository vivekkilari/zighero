// TODO: THIS IS NOT A FINAL PLATFORM LAYER!!!
// - Saved game locations
// - Getting a handle to our own executable file
// - Asset loading path
// - Threading (launch a thread)
// - Raw Input (support for multiple keyboards)
// - Sleep/timeBeginPeriod
// - ClipCursor() (for multimontior support)
// - Fullscreen support
// - WM_SETCURSOR (control cursor visibility)
// - QueryCancelAutoplay
// - WM_ACTIVATEAPP (for when we are not the active application)
// - Blit speed improvements (BitBlt)
// - Hardward acceleration (OpenGL or Direct3D or BOTH??)
// - GetKeyboardLayout (for Fr*nch keyboards, international WASD support)
//
// Just a partial list of stuf!!

const std = @import("std");
const builtin = @import("builtin");
const shared = @import("handmade_shared.zig");

const winapi = std.os.windows.WINAPI;
const win32 = struct {
    const root = @import("win32");
    const zig = root.zig;

    const fnd = root.foundation;
    const wm = root.ui.windows_and_messaging;
    const dbg = root.system.diagnostics.debug;
    const gdi = root.graphics.gdi;
    const mem = root.system.memory;
    const file = root.storage.file_system;
    const xin = root.ui.input.xbox_controller;
    const km = root.ui.input.keyboard_and_mouse;
    const lib = root.system.library_loader;
    const audio = root.media.audio;
    const dsound = audio.direct_sound;
    const com = root.system.com;
    const perf = root.system.performance;
};

// NOTE: Required for win32 API to convert automatically choose ? ANSI : WIDE
pub const UNICODE = false;
const DEBUG = builtin.mode == .Debug;

// TODO: Global for now
var global_running = false;
var global_pause = false;
var global_perf_count_frequency: i64 = 0;
var global_back_buffer = Win32OffscreenBuffer{
    .info = undefined,
    .memory = null,
    .width = 0,
    .height = 0,
    .pitch = 0,
    .bytes_per_pixel = 0,
};

var global_secondary_buffer: ?*win32.dsound.IDirectSoundBuffer = null;

var xInputGetState: *const fn (u32, ?*win32.xin.XINPUT_STATE) callconv(winapi) isize 
    = &xInputGetStateStub;
var xInputSetState: *const fn (u32, ?*win32.xin.XINPUT_VIBRATION) callconv(winapi) isize 
    = &xInputSetStateStub;

var win32DirectSoundCreate: *const fn (
    pcGuidDevice: ?*const win32.zig.Guid, 
    ppDS: ?*?*win32.dsound.IDirectSound,
    pUnkOuter: ?*win32.com.IUnknown,
) callconv(winapi) win32.fnd.HRESULT = undefined;

const Win32GameCode = struct {
    game_code_dll: win32.fnd.HINSTANCE = undefined,
    updateAndRender: *const @TypeOf(shared.gameUpdateAndRenderStub) = &shared.gameUpdateAndRenderStub,
    getSoundSamples: *const @TypeOf(shared.gameGetSoundSamplesStub) = &shared.gameGetSoundSamplesStub,

    is_valid: bool = false,
};

const Win32SoundOutput = struct {
    samples_per_second: u32,
    bytes_per_sample: u32,
    secondary_buffer_size: u32,
    safety_bytes: u32,
    running_sample_index: u32,
    latency_sample_count: u32,
    t_sine: f32,
};

const Win32DebugTimeOutput = struct {
    output_play_cursor: u32 = 0,
    output_write_cursor: u32 = 0,
    output_location: u32  = 0,
    output_byte_count: u32 = 0,
    expected_flip_play_cursor: u32 = 0,

    flip_play_cursor: u32 = 0,
    flip_write_cursor: u32 = 0,
};

const Win32OffscreenBuffer = struct {
    info: win32.gdi.BITMAPINFO,
    memory: ?*anyopaque,
    width: i32,
    height: i32,
    pitch: i32,
    bytes_per_pixel: u4,
};

inline fn rdtsc() u64 {
    var hi: u32 = 0;
    var low: u32 = 0;
    asm (
        \\rdtsc
        : [low] "={eax}" (low),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | @as(u64, low);
}

fn DEBUGWin32ReadEntireFile(filename: [*:0]const u8) callconv(.C) shared.DebugFileResult {
    if (!DEBUG) return .{.contents_size = 0, .contents = undefined};

    var result: shared.DebugFileResult = .{};

    const file_handle = win32.file.CreateFile(
        filename,
        win32.file.FILE_GENERIC_READ,
        win32.file.FILE_SHARE_READ,
        null,
        win32.file.OPEN_EXISTING,
        .{},
        null,
    ); 
    if (file_handle == win32.fnd.INVALID_HANDLE_VALUE) {
        return result;
    }

    defer _ = win32.fnd.CloseHandle(file_handle);

    var file_size = win32.fnd.LARGE_INTEGER { .QuadPart = 0 };
    if (win32.file.GetFileSizeEx(file_handle, &file_size) == 0) {
        return result;
    }

    const file_size_32: u32 = @intCast(file_size.QuadPart);
    result.contents = win32.mem.VirtualAlloc(
            null, file_size_32, .{ .RESERVE = 1, .COMMIT = 1}, .{ .PAGE_READWRITE = 1}
    ) orelse {
        return result;
    };

    var bytes_read: u32 = 0;
    if (win32.file.ReadFile(file_handle, result.contents, file_size_32, &bytes_read, null) 
        != 0 and file_size_32 == bytes_read){
        // NOTE: File read successfully
        result.contents_size = bytes_read;
    } else {
        DEBUGWin32FreeFileMemory(result.contents);
        result.contents = undefined;
    }

    return result;
} 

fn DEBUGWin32FreeFileMemory(memory: *anyopaque) callconv(.C) void { 
    if (!DEBUG) return;

    _ = win32.mem.VirtualFree(memory, 0, .RELEASE);
}

fn DEBUGWin32WriteEntireFile(
    filename: [*:0]const u8,
    memory_size: u32,
    memory: *anyopaque
) callconv(.C) bool {
    if (!DEBUG) return false;

    var result = false;

    const file_handle = win32.file.CreateFile(
        filename,
        win32.file.FILE_GENERIC_WRITE,
        win32.file.FILE_SHARE_NONE,
        null,
        win32.file.CREATE_ALWAYS,
        .{},
        null,
    ); 

    if (file_handle == win32.fnd.INVALID_HANDLE_VALUE) {
        return false;
    }
    defer _ = win32.fnd.CloseHandle(file_handle);

    var bytes_written: u32 = 0;
    if (win32.file.WriteFile(file_handle, memory, memory_size, &bytes_written, null)
        != 0) {
        // NOTE: File written successfully
        result = bytes_written == memory_size;
    } else {
        // TODO: Logging
    }

    return result;
}

fn xInputGetStateStub(_: u32, _: ?*win32.xin.XINPUT_STATE) callconv(winapi) isize {
    return @intFromEnum(win32.fnd.ERROR_DEVICE_NOT_CONNECTED);
}

fn xInputSetStateStub(_: u32, _: ?*win32.xin.XINPUT_VIBRATION) callconv(winapi) isize {
    return @intFromEnum(win32.fnd.ERROR_DEVICE_NOT_CONNECTED);
}

fn win32LoadGameCode() Win32GameCode {
    var result = Win32GameCode{};

    _ = win32.file.CopyFile(
        "C:/personal/dev/gen/zighero/zig-out/bin/handmade_game.dll", 
        "C:/personal/dev/gen/zighero/zig-out/bin/handmade_game_temp.dll",
        0,
    );
    result.game_code_dll = win32.lib.LoadLibrary(
        "C:/personal/dev/gen/zighero/zig-out/bin/handmade_game_temp.dll") orelse {
        // TODO: Diagnostic
        std.debug.panic("Could not find shared.dll!", .{});
        unreachable;
    };

    var procs_found: u32 = 0;
    if (win32.lib.GetProcAddress(result.game_code_dll, "gameUpdateAndRender")) |proc| {
        result.updateAndRender = @as(@TypeOf(result.updateAndRender), @ptrCast(proc));
        procs_found += 1;
    }

    if (win32.lib.GetProcAddress(result.game_code_dll, "gameGetSoundSamples")) |proc| {
        result.getSoundSamples = @as(@TypeOf(result.getSoundSamples), @ptrCast(proc));
        procs_found += 1;
    }

    result.is_valid = (procs_found == 2);
    if (!result.is_valid) {
        result.updateAndRender = &shared.gameUpdateAndRenderStub;
        result.getSoundSamples = &shared.gameGetSoundSamplesStub;
    }
    return result;
}

fn win32UnloadGameCode(game_code: *Win32GameCode) void {
    _ = win32.lib.FreeLibrary(game_code.game_code_dll);
    game_code.game_code_dll = undefined;
    game_code.is_valid = false;
    game_code.updateAndRender = shared.gameUpdateAndRenderStub;
    game_code.getSoundSamples = shared.gameGetSoundSamplesStub;
}

fn win32LoadXInput() void {
    const lib_xinput = win32.lib.LoadLibrary("xinput1_4.dll") orelse l: {
        break :l win32.lib.LoadLibrary("xinput9_1_0.dll");
    } orelse l: {
        // TODO: Diagnostic
        break :l win32.lib.LoadLibrary("xinput1_3.dll");
    } orelse {
        // TODO: Diagnostic
        return;
    };

    if (win32.lib.GetProcAddress(lib_xinput, "XInputGetState")) |proc| {
        xInputGetState = @as(@TypeOf(xInputGetState), @ptrCast(proc));
    }

    if (win32.lib.GetProcAddress(lib_xinput, "XInputGetState")) |proc| {
        xInputSetState = @as(@TypeOf(xInputSetState), @ptrCast(proc));
    }
}

fn win32InitDSound(window: win32.fnd.HWND, samples_per_second: u32, buffer_size: u32) void {
    // NOTE: Load the library
    const lib = win32.lib.LoadLibrary("dsound.dll") orelse {
        // TODO: Diagnostic
        std.debug.print("Failed to load dsound.dll!", .{});
        return;
    };

    const procedure = win32.lib.GetProcAddress(lib, "DirectSoundCreate") 
        orelse {
        // TODO: Diagnostic
        std.debug.print("Failed to get DirectSoundCreate procedure!", .{});
        return;
    };
    win32DirectSoundCreate = 
        @as(@TypeOf(win32DirectSoundCreate), @ptrCast(procedure));

    // NOTE: Get a DirectSound object
    var direct_sound_opt: ?*win32.dsound.IDirectSound = null;
    if (!win32.zig.SUCCEEDED( win32DirectSoundCreate(null, &direct_sound_opt, null)) or 
            direct_sound_opt == null) {
        // TODO: Diagnostic
        std.debug.print("Failed to create direct sound object!", .{});
        return;
    }

    var wave_format = win32.audio.WAVEFORMATEX {
        .wFormatTag = win32.audio.WAVE_FORMAT_PCM,
        .nChannels = 2,
        .nSamplesPerSec = samples_per_second,
        .wBitsPerSample = 16,
        .nBlockAlign = 0,
        .nAvgBytesPerSec = 0,
        .cbSize = 0,
    };
    wave_format.nBlockAlign = (wave_format.nChannels * wave_format.wBitsPerSample) / 8;
    wave_format.nAvgBytesPerSec = wave_format.nSamplesPerSec * wave_format.nBlockAlign;

    var direct_sound: *win32.dsound.IDirectSound = direct_sound_opt.?;
    if (win32.zig.SUCCEEDED(direct_sound.SetCooperativeLevel(
                window, win32.dsound.DSSCL_PRIORITY))) pb: {

        var buffer_desc = win32.dsound.DSBUFFERDESC{
            .dwSize = @sizeOf(win32.dsound.DSBUFFERDESC),
            .dwFlags = win32.dsound.DSBCAPS_PRIMARYBUFFER,
            .dwBufferBytes = 0,
            .dwReserved = 0,
            .guid3DAlgorithm = win32.zig.Guid.initString("00000000-0000-0000-0000-000000000000"),
            .lpwfxFormat = null,
        };

        // NOTE: "Create" a primary buffer
        var primary_buffer: ?*win32.dsound.IDirectSoundBuffer = null;
        if (!win32.zig.SUCCEEDED(direct_sound.CreateSoundBuffer(
                    &buffer_desc, &primary_buffer, null))) {
            // TODO: Diagnostic
            std.debug.print("Failed to create primary sound buffer!", .{});
            break :pb;
        }

        if (!win32.zig.SUCCEEDED(primary_buffer.?.SetFormat(&wave_format))) {
            // TODO: Diagnostic
            std.debug.print("Failed to set primary sound buffer format!", .{}); 
            break :pb;
        }
        // NOTE: The format has finally been set!
    } else {
        // TODO: Diagnostic
        std.debug.print(
            "Failed to set direct sound object cooperation level!", .{}); 
    }

    // NOTE: "Create" a secondary buffer
    var buffer_desc = win32.dsound.DSBUFFERDESC{
        .dwSize = @sizeOf(win32.dsound.DSBUFFERDESC),
        .dwFlags = 0,
        .dwBufferBytes = buffer_size,
        .dwReserved = 0,
        .guid3DAlgorithm = win32.zig.Guid.initString("00000000-0000-0000-0000-000000000000"),
        .lpwfxFormat = &wave_format,
    };

    global_secondary_buffer = null;
    if (!win32.zig.SUCCEEDED(direct_sound.CreateSoundBuffer(
                &buffer_desc, &global_secondary_buffer, null))) {
        // TODO: Diagnostic
        std.debug.print("Failed to create secondary sound buffer!", .{}); 
        return;
    }
}

fn win32GetWindowDimension(window: win32.fnd.HWND) struct { width: i32, height: i32 } {
    var rect: win32.fnd.RECT = undefined;
    _ = win32.wm.GetClientRect(window, &rect);

    return .{
        .width = rect.right - rect.left,
        .height = rect.bottom - rect.top,
    };
}

fn win32ResizeDIBSection(buffer: *Win32OffscreenBuffer, width: i32, height: i32) void {
    if (buffer.memory != null) {
        _ = win32.mem.VirtualFree(buffer.memory, 0, win32.mem.MEM_RELEASE);
    }

    buffer.width = width;
    buffer.height = height;
    buffer.bytes_per_pixel = 4;

    // NOTE: When the biHeight field is negative, Windows treats the bitmap as 
    // topdown, not bottom up, meaning that the first three bytes correspond 
    // to the top-left pixel of the window
    buffer.info.bmiHeader.biSize = @sizeOf(win32.gdi.BITMAPINFOHEADER);
    buffer.info.bmiHeader.biWidth = buffer.width;
    buffer.info.bmiHeader.biHeight = -buffer.height;
    buffer.info.bmiHeader.biPlanes = 1;
    buffer.info.bmiHeader.biBitCount = 32;
    buffer.info.bmiHeader.biCompression = win32.gdi.BI_RGB;

    const memory_size: usize = 
        @intCast(buffer.bytes_per_pixel * buffer.width * buffer.height);
    buffer.memory = win32.mem.VirtualAlloc(
        buffer.memory,
        memory_size,
        win32.mem.MEM_COMMIT,
        win32.mem.PAGE_READWRITE,
    );

    buffer.pitch = width * buffer.bytes_per_pixel;
}

fn win32DrawBufferToWindow(
    buffer: *Win32OffscreenBuffer,
    device_context: win32.gdi.HDC,
    window_width: i32,
    window_height: i32,
) void {
    // TODO: Aspect ratio correction
    _ = win32.gdi.StretchDIBits(
        device_context,
        0, 0, window_width, window_height,
        0, 0, buffer.width, buffer.height,
        buffer.memory,
        &buffer.info,
        win32.gdi.DIB_USAGE.RGB_COLORS,
        win32.gdi.SRCCOPY,
    );
}

fn win32WindowCallback(
    window: win32.fnd.HWND,
    message: u32,
    w_param: win32.fnd.WPARAM,
    l_param: win32.fnd.LPARAM,
) callconv(winapi) win32.fnd.LRESULT {
    var result: win32.fnd.LRESULT = 0;

    const wm = win32.wm;

    switch (message) {
        wm.WM_CLOSE, wm.WM_DESTROY => global_running = false,
        wm.WM_ACTIVATEAPP => win32.dbg.OutputDebugString("WM_ACTIVATEAPP\n"),
        wm.WM_SYSKEYDOWN, wm.WM_SYSKEYUP, wm.WM_KEYDOWN, wm.WM_KEYUP => {
            std.debug.print("Keyboard input came in through a non-dispatch  message!", .{});
            unreachable;
        },
        wm.WM_PAINT => {
            var paint: win32.gdi.PAINTSTRUCT = undefined;
            if (win32.gdi.BeginPaint(window, &paint)) |deviceContext| {
                const dimensions = win32GetWindowDimension(window);
                win32DrawBufferToWindow(
                    &global_back_buffer,
                    deviceContext,
                    dimensions.width,
                    dimensions.height,
                );
            }

            _ = win32.gdi.EndPaint(window, &paint);
        },
        else => result = wm.DefWindowProc(window, message, w_param, l_param),
    }

    return result;
}

fn win32ClearSoundBuffer(sound_output: *Win32SoundOutput) void {
    var region_1: ?*anyopaque = null;
    var region_1_size: u32 = 0;
    var region_2: ?*anyopaque = null;
    var region_2_size: u32 = 0;

    if (!win32.zig.SUCCEEDED(global_secondary_buffer.?.Lock(
                0, sound_output.secondary_buffer_size,
                &region_1, &region_1_size, 
                &region_2, &region_2_size,
                0,
    ))) return;

    var dest_sample: [*] i8 = undefined;
    if (region_1) |region| {
        dest_sample = @alignCast(@ptrCast(region));
        for (0..region_1_size) |_| {
            dest_sample[0] = 0;
            dest_sample += 1;
        }
    }

    if (region_2) |region| {
        dest_sample = @alignCast(@ptrCast(region));
        for (0..region_2_size) |_| {
            dest_sample[0] = 0;
            dest_sample += 1;
        }
    }

    _ = global_secondary_buffer.?.Unlock(
        region_1, region_1_size, 
        region_2, region_2_size,
    );
}
fn win32FillSoundBuffer(
    sound_output: *Win32SoundOutput,
    byte_to_lock: u32,
    bytes_to_write: u32,
    source_buffer: *shared.GameSoundOutputBuffer,
) void {
    var region_1: ?*anyopaque = null;
    var region_1_size: u32 = 0;
    var region_2: ?*anyopaque = null;
    var region_2_size: u32 = 0;

    if (!win32.zig.SUCCEEDED(global_secondary_buffer.?.Lock(
                byte_to_lock, bytes_to_write,
                &region_1, &region_1_size, 
                &region_2, &region_2_size,
                0,
    ))) return;

    var source_sample = source_buffer.samples;
    var dest_sample: [*] align(1) i16 = undefined;
    if (region_1) |region| {
        dest_sample = @alignCast(@ptrCast(region));
        const region_size: usize = region_1_size / sound_output.bytes_per_sample;
        for (0..region_size) |_| {
            dest_sample[0] = source_sample[0];
            dest_sample += 1;
            source_sample += 1;
            dest_sample[0] = source_sample[0];
            dest_sample += 1;
            source_sample += 1;

            sound_output.running_sample_index += 1;
        }
    }


    if (region_2) |region| {
        dest_sample = @alignCast(@ptrCast(region));
        const region_size: usize = region_2_size / sound_output.bytes_per_sample;
        for (0..region_size) |_| {
            dest_sample[0] = source_sample[0];
            dest_sample += 1;
            source_sample += 1;
            dest_sample[0] = source_sample[0];
            dest_sample += 1;
            source_sample += 1;

            sound_output.running_sample_index += 1;
        }
    }

    _ = global_secondary_buffer.?.Unlock(
        region_1, region_1_size, 
        region_2, region_2_size,
    );
}

fn win32ProcessKeyboardMessage(
    new_state: *shared.GameButtonState,
    is_down: bool,
) void {
    // NOTE: WILL NOT WORK IF STATE CHANGES OUTSIDE OF WINDOW
    // std.debug.assert(new_state.ended_down != is_down);
    new_state.ended_down = is_down;
    new_state.half_transition_count += 1;
}

fn win32ProcessXInputDigitalButton(
    x_input_button_state: u16,
    old_state: *shared.GameButtonState, 
    button_bit: u32,
    new_state: *shared.GameButtonState,
) void {
    new_state.ended_down = ((x_input_button_state & button_bit) == button_bit);
    new_state.half_transition_count = if (old_state.ended_down != new_state.ended_down) 1 else 0;
}

fn win32ProcessXInputStickValue(
    value: i16,
    deadzone_threshold: i16,
) f32 {
    // NOTE: Handles deadzone and normalizes input to be between deadzone and max values
    return if (value < -deadzone_threshold) 
        @as(f32, @floatFromInt(value + deadzone_threshold)) / (32768.0 - @as(f32, @floatFromInt(deadzone_threshold)))
    else if (value > deadzone_threshold)
        @as(f32, @floatFromInt(value - deadzone_threshold)) / (32767.0 - @as(f32, @floatFromInt(deadzone_threshold)))
    else 0;
}

fn win32ProcessPendingMessages(keyboard_controller: *shared.GameControllerInput) void {
    var message: win32.wm.MSG = undefined;

    while (win32.wm.PeekMessage(&message, null, 0, 0, win32.wm.PM_REMOVE) > 0) {
        switch (message.message) {
            win32.wm.WM_QUIT => global_running = false,
            win32.wm.WM_SYSKEYUP, win32.wm.WM_SYSKEYDOWN, win32.wm.WM_KEYUP, win32.wm.WM_KEYDOWN => {
                const vk_code: win32.km.VIRTUAL_KEY = 
                    @enumFromInt(win32.zig.loword(message.wParam));

                const key_flags = win32.zig.hiword(message.lParam);
                const was_down = (key_flags & win32.wm.KF_REPEAT) == win32.wm.KF_REPEAT;
                const is_down = (key_flags & win32.wm.KF_UP) != win32.wm.KF_UP;

                const km = win32.km;
                if (was_down != is_down) {
                    switch (vk_code) {
                        km.VK_W => win32ProcessKeyboardMessage(&keyboard_controller.move_up, is_down),
                        km.VK_A => win32ProcessKeyboardMessage(&keyboard_controller.move_left, is_down),
                        km.VK_S => win32ProcessKeyboardMessage(&keyboard_controller.move_down, is_down),
                        km.VK_D => win32ProcessKeyboardMessage(&keyboard_controller.move_right, is_down),
                        km.VK_Q => win32ProcessKeyboardMessage(&keyboard_controller.left_shoulder, is_down),
                        km.VK_E => win32ProcessKeyboardMessage(&keyboard_controller.right_shoulder, is_down),
                        km.VK_UP => win32ProcessKeyboardMessage(&keyboard_controller.action_up, is_down),
                        km.VK_LEFT => win32ProcessKeyboardMessage(&keyboard_controller.action_left, is_down),
                        km.VK_DOWN => win32ProcessKeyboardMessage(&keyboard_controller.action_down, is_down),
                        km.VK_RIGHT => win32ProcessKeyboardMessage(&keyboard_controller.action_right, is_down),
                        km.VK_ESCAPE => win32ProcessKeyboardMessage(&keyboard_controller.back, is_down),
                        km.VK_SPACE => win32ProcessKeyboardMessage(&keyboard_controller.start, is_down),
                        km.VK_P => {
                            if (is_down) global_pause = !global_pause;
                        },
                        else => {},
                    }
                }

                const alt_key_was_down = (message.lParam & (1 << 29)) != 0;
                if ((vk_code == win32.km.VK_F4) and alt_key_was_down) {
                    global_running = false;
                }
            },
            else => {
                _ = win32.wm.TranslateMessage(&message);
                _ = win32.wm.DispatchMessageA(&message);
            },
        }
    }
}

pub inline fn win32GetWallClock() win32.fnd.LARGE_INTEGER {
    var result: win32.fnd.LARGE_INTEGER = undefined;
    _ = win32.perf.QueryPerformanceCounter(&result);
    return result;
}

pub inline fn win32GetSecondsElapsed(start: win32.fnd.LARGE_INTEGER, end: win32.fnd.LARGE_INTEGER) f32 {
    const result = @as(f32, @floatFromInt(end.QuadPart - start.QuadPart)) / 
        @as(f32, @floatFromInt(global_perf_count_frequency));
    return result;
}

fn win32DebugDrawVerticalLine(
    back_buffer: *Win32OffscreenBuffer, 
    x: u32, top: u32, bottom: u32, color: u32,
) void {
    if (!(x >= 0 and x < back_buffer.width)) return;

    const top_clamped: u32 = if (top <= 0) 0 else top;
    const bot_clamped: u32 = if (bottom > back_buffer.height) 
        @intCast(back_buffer.height) else bottom;

    var pixel_adr: [*]u8 = @as([*]u8, @ptrCast(back_buffer.memory.?)) + 
                        (x * back_buffer.bytes_per_pixel) +
                        (top_clamped * @as(u32, @intCast(back_buffer.pitch)));

    for (top_clamped..bot_clamped) |_| {
        const pixel: [*]u32 = @alignCast(@ptrCast(pixel_adr));
        pixel[0] = color;
        pixel_adr += @intCast(back_buffer.pitch);
    }
}

fn win32DrawSoundBufferMarker(
    back_buffer: *Win32OffscreenBuffer,
    _: *Win32SoundOutput,
    c: f32, pad_x: u32, 
    top: u32, bottom: u32,
    value: u32, color: u32,
) void {
    const value_f: f32 = @floatFromInt(value);
    const offset: u32 = @intFromFloat(c * value_f);
    const x: u32 = pad_x + offset;
    win32DebugDrawVerticalLine(back_buffer, x, top, bottom, color);
}

fn win32DebugSyncDisplay(
    back_buffer: *Win32OffscreenBuffer,
    markers: []Win32DebugTimeOutput,
    current_marker_idx: u32,
    sound_ouput: *Win32SoundOutput,
    _: f32,
) void {
    const pad_x : u32 = 16;
    const pad_y : u32 = 16;

    const line_height = 64;

    const padless_width: f32 = @floatFromInt(global_back_buffer.width - (2 * pad_x)); 
    const buf_size: f32 = @floatFromInt(sound_ouput.secondary_buffer_size);
    const c: f32 = padless_width / buf_size;

    const play_color = 0xFFFFFFFF;
    const write_color = 0xFFFF0000;
    const expected_flip_color = 0xFFFFFF00;
    const play_window_color = 0xFFFF00FF;

    for (0..markers.len) |marker_idx| {
        const this_marker = &markers[marker_idx];
        std.debug.assert(this_marker.output_play_cursor < sound_ouput.secondary_buffer_size);
        std.debug.assert(this_marker.output_write_cursor < sound_ouput.secondary_buffer_size);
        std.debug.assert(this_marker.output_location < sound_ouput.secondary_buffer_size);
        std.debug.assert(this_marker.output_byte_count < sound_ouput.secondary_buffer_size);
        std.debug.assert(this_marker.flip_play_cursor < sound_ouput.secondary_buffer_size);
        std.debug.assert(this_marker.flip_write_cursor < sound_ouput.secondary_buffer_size);

        var top = pad_y;
        var bottom = pad_y + line_height;
        if (marker_idx == current_marker_idx) {
            top += line_height + pad_y;
            bottom += line_height + pad_y;

            const first_top = top;

            win32DrawSoundBufferMarker(back_buffer, sound_ouput, c, pad_x, top, bottom, 
                this_marker.output_play_cursor, play_color);
            win32DrawSoundBufferMarker(back_buffer, sound_ouput, c, pad_x, top, bottom, 
                this_marker.output_write_cursor, write_color);

            top += line_height + pad_y;
            bottom += line_height + pad_y;

            win32DrawSoundBufferMarker(back_buffer, sound_ouput, c, pad_x, top, bottom, 
                this_marker.output_location, play_color);
            win32DrawSoundBufferMarker(back_buffer, sound_ouput, c, pad_x, top, bottom, 
                this_marker.output_location + this_marker.output_byte_count, write_color);

            top += line_height + pad_y;
            bottom += line_height + pad_y;

            win32DrawSoundBufferMarker(back_buffer, sound_ouput, c, pad_x, first_top, bottom, 
                this_marker.expected_flip_play_cursor, expected_flip_color);
        }

        win32DrawSoundBufferMarker(back_buffer, sound_ouput, c, pad_x, top, bottom, 
            this_marker.flip_play_cursor, play_color);
        win32DrawSoundBufferMarker(back_buffer, sound_ouput, c, pad_x, top, bottom, 
            this_marker.flip_play_cursor + (480 * sound_ouput.bytes_per_sample), play_window_color);
        win32DrawSoundBufferMarker(back_buffer, sound_ouput, c, pad_x, top, bottom, 
            this_marker.flip_write_cursor, write_color);
    }
}

pub fn wWinMain(
    instance: ?win32.fnd.HINSTANCE,
    _: ?win32.fnd.HINSTANCE,
    _: [*:0]u16,
    _: u32,
) callconv(winapi) c_int {
    var perf_count_frequency_result: win32.fnd.LARGE_INTEGER = undefined;
    _ = win32.perf.QueryPerformanceFrequency(&perf_count_frequency_result);
    global_perf_count_frequency = perf_count_frequency_result.QuadPart;

    // NOTE: Set the Windows scheduler granularity to 1ms
    // so that our Sleep() can be more granular
    const desired_scheduler_ms = 1;
    const sleep_is_granular = 
        win32.root.media.timeBeginPeriod(desired_scheduler_ms) 
        == win32.root.media.TIMERR_NOERROR;

    win32LoadXInput();
    win32ResizeDIBSection(&global_back_buffer, 1280, 720);

    const window_class = win32.wm.WNDCLASS{
        .style = .{.HREDRAW = 1, .VREDRAW = 1},
        .lpfnWndProc = win32WindowCallback,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = "ZigHeroWindowClass",
    };

    const monitor_refresh_hz: u32 = 60;
    const game_update_hz: u32 = monitor_refresh_hz / 2;
    const target_seconds_per_frame: f32 = 1.0 / @as(f32, @floatFromInt(game_update_hz));

    if (win32.wm.RegisterClass(&window_class) < 1) return 0;
    const window = win32.wm.CreateWindowEx(
        .{},
        window_class.lpszClassName,
        "ZigHero",
        .{
            // OVERLAPPEDWINDOW
            .TABSTOP = 1,
            .GROUP = 1,
            .THICKFRAME = 1,
            .SYSMENU = 1,
            .DLGFRAME = 1,
            .BORDER = 1,
            // VISIBLE
            .VISIBLE = 1,
        },
        win32.wm.CW_USEDEFAULT,
        win32.wm.CW_USEDEFAULT,
        win32.wm.CW_USEDEFAULT,
        win32.wm.CW_USEDEFAULT,
        null,
        null,
        instance,
        null,
        ) orelse return 0;

    const device_ctx = win32.gdi.GetDC(window) orelse return 0;
    defer _ = win32.gdi.ReleaseDC(window, device_ctx);

    var sound_output: Win32SoundOutput = undefined;
    sound_output.samples_per_second = 48000;
    sound_output.bytes_per_sample = @sizeOf(i16) * 2;
    sound_output.secondary_buffer_size = 
        sound_output.samples_per_second * sound_output.bytes_per_sample;
    // TODO: Get rid of latency_sample_count
    sound_output.latency_sample_count = 3 * 
        @divFloor(sound_output.samples_per_second, game_update_hz);
    sound_output.safety_bytes = (
        (sound_output.samples_per_second * sound_output.bytes_per_sample) / 
        game_update_hz) / 3;
    sound_output.running_sample_index = 0;
    sound_output.t_sine = 0;

    win32InitDSound(window, sound_output.samples_per_second, sound_output.secondary_buffer_size);
    win32ClearSoundBuffer(&sound_output);
    _ = global_secondary_buffer.?.Play(0, 0, win32.dsound.DSBPLAY_LOOPING);

    if (false) {
        // NOTE: This stest the play_cursor/write_cursor update frequency
        // on this machine. It was 480 samples
        while (true) {
            var play_cursor: u32 = 0;
            var write_cursor: u32 = 0;
            _ = global_secondary_buffer.?.GetCurrentPosition(&play_cursor, &write_cursor);
            std.debug.print("PC:{d} WC:{d}\n", .{play_cursor, write_cursor});
        }
    }

    global_running = true;

    const samples: [*]i16 = @alignCast(@ptrCast(win32.mem.VirtualAlloc(
        null, sound_output.secondary_buffer_size,
        .{ .COMMIT = 1, .RESERVE = 1 }, win32.mem.PAGE_READWRITE) orelse {
        // TODO: Diagnostic
        return 0;
    }));

    const base_address: *allowzero anyopaque = if(DEBUG)
        @ptrFromInt(shared.terabytes(2)) else @ptrFromInt(0);
    
    var game_memory = shared.GameMemory {
        .permanent_storage_size = shared.megabytes(64),
        .transient_storage_size = shared.gigabytes(4),
        .DEBUGPlatformReadEntireFile = DEBUGWin32ReadEntireFile,
        .DEBUGPlatformFreeFileMemory = DEBUGWin32FreeFileMemory,
        .DEBUGPlatformWriteEntireFile = DEBUGWin32WriteEntireFile,
    };

    const total_size = game_memory.permanent_storage_size + 
        game_memory.transient_storage_size;
    game_memory.permanent_storage = win32.mem.VirtualAlloc(
            base_address, total_size, 
            .{ .RESERVE = 1, .COMMIT = 1 }, 
            .{ .PAGE_READWRITE = 1},
    ) orelse {
        // TODO: Diagnostic
        std.debug.print("Memory allocation failure!", .{});
        return 0;
    };

    game_memory.transient_storage = @as([*]u8, @alignCast(@ptrCast(
                game_memory.permanent_storage))) + game_memory.permanent_storage_size;

    var input: [2]shared.GameInput = .{ .{}, .{} };
    var new_input = &input[0];
    var old_input = &input[1];

    var last_counter = win32GetWallClock();
    var flip_wall_clock: win32.fnd.LARGE_INTEGER = win32GetWallClock();

    var debug_time_marker_idx: u32 = 0;
    var debug_time_markers: [game_update_hz / 2]Win32DebugTimeOutput = @splat(.{});

    var audio_latency_bytes: u32 = 0;
    var audio_latency_seconds: f32 = 0;
    var sound_is_valid = false;

    var game_code = win32LoadGameCode();
    var load_counter: u32 = 120;

    var last_cycle_count = rdtsc();
    while (global_running) {
        if (load_counter > 120) {
            win32UnloadGameCode(&game_code);
            game_code = win32LoadGameCode();
            load_counter = 0;
        }
        load_counter += 1;

        const old_keyboard_controller = shared.getController(old_input, 0);
        const new_keyboard_controller = shared.getController(new_input, 0);
        new_keyboard_controller.* = .{
            .is_connected = true,
        };

        for (0..shared.GameControllerInput.button_count) |idx| {
            new_keyboard_controller.button(idx).ended_down = 
                old_keyboard_controller.button(idx).ended_down; 
        }

        win32ProcessPendingMessages(new_keyboard_controller);

        if (global_pause) continue;
        var max_controller_count = win32.xin.XUSER_MAX_COUNT;
        if (max_controller_count > new_input.controllers.len - 1) {
            max_controller_count = new_input.controllers.len - 1; 
        }

        var controller_idx: u32 = 0;
        while(controller_idx < max_controller_count) : 
            (controller_idx += 1) {
            // NOTE: Ignores first "controller" which is keyboard
            const our_controller_idx = controller_idx + 1;
            const old_controller = &old_input.controllers[our_controller_idx];
            const new_controller = &new_input.controllers[our_controller_idx];

            var controller_state: win32.xin.XINPUT_STATE = undefined;
            if (xInputGetState(controller_idx, &controller_state) == 
                    @intFromEnum(win32.fnd.ERROR_SUCCESS)) {
                // NOTE: The controller is plugged in
                // TODO: See if controller_state.dwPacketNumber increments too rapidly
                new_controller.is_connected = true;

                const pad = &controller_state.Gamepad;

                // TODO: This is a square deadzone, check XInput to verify that
                // the deadzone is "round"
                new_controller.stick_average_x = win32ProcessXInputStickValue(
                        pad.sThumbLX, win32.xin.XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE,
                );
                new_controller.stick_average_y = win32ProcessXInputStickValue(
                    pad.sThumbLY, win32.xin.XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE,
                );

                if ((new_controller.stick_average_x != 0) and
                    (new_controller.stick_average_y != 0)) {
                    new_controller.is_analog = true;
                }

                const xin = win32.xin;

                if ((pad.wButtons & xin.XINPUT_GAMEPAD_DPAD_UP) != 0) {
                    new_controller.stick_average_y = 1;
                    new_controller.is_analog = false;
                }

                if ((pad.wButtons & xin.XINPUT_GAMEPAD_DPAD_DOWN) != 0) {
                    new_controller.stick_average_y = -1;
                    new_controller.is_analog = false;
                }

                if ((pad.wButtons & xin.XINPUT_GAMEPAD_DPAD_RIGHT) != 0) {
                    new_controller.stick_average_x = 1;
                    new_controller.is_analog = false;
                }

                if ((pad.wButtons & xin.XINPUT_GAMEPAD_DPAD_LEFT) != 0) {
                    new_controller.stick_average_x = -1;
                    new_controller.is_analog = false;
                }

                const threshold = 0.5;
                win32ProcessXInputDigitalButton(
                    if (new_controller.stick_average_x < -threshold) 1 else 0, 
                    &old_controller.move_left, 1, 
                    &new_controller.move_left,
                );

                win32ProcessXInputDigitalButton(
                    if (new_controller.stick_average_x > threshold) 1 else 0, 
                    &old_controller.move_right, 1, 
                    &new_controller.move_right,
                );

                win32ProcessXInputDigitalButton(
                    if (new_controller.stick_average_y < -threshold) 1 else 0, 
                    &old_controller.move_down, 1, 
                    &new_controller.move_down,
                );

                win32ProcessXInputDigitalButton(
                    if (new_controller.stick_average_y > threshold) 1 else 0, 
                    &old_controller.move_up, 1, 
                    &new_controller.move_up,
                );

                win32ProcessXInputDigitalButton(pad.wButtons, &old_controller.action_down,
                    xin.XINPUT_GAMEPAD_A, &new_controller.action_down,
                );

                win32ProcessXInputDigitalButton(pad.wButtons, &old_controller.action_right,
                    xin.XINPUT_GAMEPAD_B, &new_controller.action_right,
                );

                win32ProcessXInputDigitalButton(pad.wButtons, &old_controller.action_left,
                    xin.XINPUT_GAMEPAD_X, &new_controller.action_left,
                );

                win32ProcessXInputDigitalButton(pad.wButtons, &old_controller.action_up,
                    xin.XINPUT_GAMEPAD_Y, &new_controller.action_up,
                );

                win32ProcessXInputDigitalButton(pad.wButtons, &old_controller.left_shoulder,
                    xin.XINPUT_GAMEPAD_LEFT_SHOULDER, &new_controller.left_shoulder,
                );

                win32ProcessXInputDigitalButton(pad.wButtons, &old_controller.right_shoulder,
                    xin.XINPUT_GAMEPAD_RIGHT_SHOULDER, &new_controller.right_shoulder,
                );

                win32ProcessXInputDigitalButton(pad.wButtons, &old_controller.start,
                    xin.XINPUT_GAMEPAD_START, &new_controller.start,
                );

                win32ProcessXInputDigitalButton(pad.wButtons, &old_controller.back,
                    xin.XINPUT_GAMEPAD_BACK, &new_controller.back,
                );

                // TODO: Will do deadzone handling later
                // XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE
                // XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE
            } else {
                // NOTE:The controller is not available
                new_controller.is_connected = false;
            }
            }

        var buffer = shared.GameOffscreenBuffer{
            .memory = global_back_buffer.memory,
            .width = global_back_buffer.width,
            .height  = global_back_buffer.height,
            .pitch = global_back_buffer.pitch,
        };

        game_code.updateAndRender(&game_memory, new_input, &buffer);

        const audio_wall_clock = win32GetWallClock();
        const from_begin_to_audio_seconds = win32GetSecondsElapsed(flip_wall_clock, audio_wall_clock);

        var play_cursor: u32 = 0;
        var write_cursor: u32 = 0;
        if (win32.zig.SUCCEEDED(global_secondary_buffer.?
                .GetCurrentPosition(&play_cursor, &write_cursor))) {
            // NOTE:
            //
            // Here is how sound output computation works.
            //
            // We define a safety value that is the number
            // of samples we think our game update loop
            // may vary by (let's say up to 2ms)
            //
            // When we wake up to write audio, we will look
            // and see what the play cursor position is and we
            // will forecast ahead where we think the play
            // cursor will be on the next frame boundary.
            //
            // We will then look to see if the write cursor is
            // before that by at least our safety value. If 
            // it is, the target fill position is that frame 
            // boundary plus one frame. This gives us perfect 
            // audio sync in the case of a card that has low 
            // enough latency.
            //
            // If the write cursor is _after_ that safety
            // margin, then we assume we can never sync the
            // audio perfectly, so we will write one frame's
            // worth of audio plus the safety margin's worth
            // of guard samples.

            if (!sound_is_valid) {
                sound_output.running_sample_index = write_cursor / sound_output.bytes_per_sample;
                sound_is_valid = true;
            }

            const byte_to_lock: u32 = 
                (sound_output.running_sample_index * sound_output.bytes_per_sample) % 
                sound_output.secondary_buffer_size;

            const expected_sound_bytes_per_frame: u32 = 
                (sound_output.samples_per_second * sound_output.bytes_per_sample) / game_update_hz;
            const seconds_left_until_flip: f32 = target_seconds_per_frame - from_begin_to_audio_seconds;
            const expected_bytes_until_flip_signed: i32 = @intFromFloat(
                (seconds_left_until_flip / target_seconds_per_frame) *
                @as(f32, @floatFromInt(expected_sound_bytes_per_frame))
            );
            // NOTE: Casey forgets to ouse this value even though that's obviously a bug
            const expected_bytes_until_flip: u32 = if (expected_bytes_until_flip_signed < 0) 0 
                else @intCast(expected_bytes_until_flip_signed);

            const expected_frame_boundary_byte = play_cursor + expected_bytes_until_flip;

            var safe_write_cursor = write_cursor;
            if (safe_write_cursor < play_cursor) {
                safe_write_cursor += sound_output.secondary_buffer_size;
            }
            std.debug.assert(safe_write_cursor >= play_cursor);
            safe_write_cursor += sound_output.safety_bytes;

            const audio_card_is_low_latency = safe_write_cursor < expected_frame_boundary_byte;

            var target_cursor: u32 = 0;
            if (audio_card_is_low_latency) {
                target_cursor = expected_frame_boundary_byte + expected_sound_bytes_per_frame; 
            } else {
                target_cursor = write_cursor + expected_sound_bytes_per_frame + sound_output.safety_bytes;
            }
            target_cursor %= sound_output.secondary_buffer_size;

            var bytes_to_write: u32 = 0;
            if (byte_to_lock > target_cursor) {
                bytes_to_write = sound_output.secondary_buffer_size - byte_to_lock;
                bytes_to_write += target_cursor;
            } else {
                bytes_to_write = target_cursor - byte_to_lock;
            }

            var sound_buffer = shared.GameSoundOutputBuffer {
                .samples_per_second = sound_output.samples_per_second,
                .sample_count = bytes_to_write / sound_output.bytes_per_sample,
                .samples = samples,
            };
            game_code.getSoundSamples(&game_memory, &sound_buffer);

            if (DEBUG) {
                var marker = &debug_time_markers[debug_time_marker_idx];
                marker.output_play_cursor = play_cursor;
                marker.output_write_cursor = write_cursor;
                marker.output_location = byte_to_lock;
                marker.output_byte_count = bytes_to_write;
                marker.expected_flip_play_cursor = expected_frame_boundary_byte;

                var unwrapped_write_cursor = write_cursor;
                if (unwrapped_write_cursor < play_cursor)
                    unwrapped_write_cursor += sound_output.secondary_buffer_size;
                audio_latency_bytes = unwrapped_write_cursor - play_cursor;
                audio_latency_seconds = 
                    (@as(f32, @floatFromInt(audio_latency_bytes)) / 
                     @as(f32, @floatFromInt(sound_output.bytes_per_sample))) /
                    @as(f32, @floatFromInt(sound_output.samples_per_second));

                std.debug.print("BTL:{d} TC:{d} BTW:{d} - PC:{d} WC:{d} DELTA:{d} {d}\n",
                    .{byte_to_lock, target_cursor, bytes_to_write,
                        play_cursor, write_cursor, audio_latency_bytes, audio_latency_seconds});
            }
            win32FillSoundBuffer(&sound_output, byte_to_lock, bytes_to_write, &sound_buffer);
        } else {
            sound_is_valid = false;
        }

        const work_counter = win32GetWallClock();
        const work_seconds_elapsed = win32GetSecondsElapsed(last_counter, work_counter);

        var seconds_elapsed_per_frame = work_seconds_elapsed;
        if (seconds_elapsed_per_frame < target_seconds_per_frame) {
            if (sleep_is_granular) {
                const sleep_ms: u32 = @intFromFloat(1000.0 * 
                    (target_seconds_per_frame - seconds_elapsed_per_frame)); 
                if (sleep_ms > 0) {
                    win32.root.system.threading.Sleep(sleep_ms);
                }
            }

            const test_seconds_elapsed_for_frame = win32GetSecondsElapsed(last_counter, 
                win32GetWallClock());
            if (test_seconds_elapsed_for_frame < target_seconds_per_frame) {
                // TODO: LOG MISSED SLEEP HERE
            }

            while (seconds_elapsed_per_frame < target_seconds_per_frame) {
                seconds_elapsed_per_frame = win32GetSecondsElapsed(last_counter, win32GetWallClock());
            }
        } else {
            // TODO: MISSED FRAME RATE!
            // TODO: Logging
        }

        const end_counter = win32GetWallClock();
        const ms_per_frame: f32 = 1000.0 * win32GetSecondsElapsed(last_counter, end_counter);
        last_counter = end_counter;

        const dimensions = win32GetWindowDimension(window);
        if (DEBUG) {
            // TODO: This is wrong on the zero'th index
            win32DebugSyncDisplay(
                &global_back_buffer, &debug_time_markers,
                debug_time_marker_idx -% 1, &sound_output, target_seconds_per_frame,
            );
        }

        win32DrawBufferToWindow(&global_back_buffer, device_ctx, dimensions.width, dimensions.height);

        flip_wall_clock = win32GetWallClock();

        if (DEBUG) {
            var play_curs: u32 = 0;
            var write_curs: u32 = 0;
            if (win32.zig.SUCCEEDED(global_secondary_buffer.?
                    .GetCurrentPosition(&play_curs, &write_curs))) {
                std.debug.assert(debug_time_marker_idx < debug_time_markers.len);
                const marker = &debug_time_markers[debug_time_marker_idx];

                if (debug_time_marker_idx == debug_time_markers.len) 
                    debug_time_marker_idx = 0;

                marker.flip_play_cursor = play_curs;
                marker.flip_write_cursor = write_curs;
            }
        }

        const temp = new_input;
        new_input = old_input;
        old_input = temp;

        const end_cycle_count = rdtsc();
        const cycles_elapsed = end_cycle_count - last_cycle_count;
        last_cycle_count = end_cycle_count;

        const fps: f64 = 0;
        const mc_per_frame: f64 = @as(f64, @floatFromInt(cycles_elapsed)) / (1000.0 * 1000.0);

        // _ = ms_per_frame;
        // _ = fps;
        // _ = mc_per_frame;
        std.debug.print(
            "{d:.2}ms/f, {d:.2}f/s, {d:.2}mc/f\n", 
            .{ms_per_frame, fps, mc_per_frame}
        );

        if (DEBUG) {
            debug_time_marker_idx += 1;
            if (debug_time_marker_idx == debug_time_markers.len) debug_time_marker_idx = 0;
        }
    }

    return 0;
}
