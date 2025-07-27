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
const handmade = @import("handmade.zig");

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

// TODO: Global for now
var global_running: bool = undefined;
var global_perf_count_frequency: i64 = undefined;
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

const win32Platform = handmade.Platform {
    .DEBUGPlatformFreeFileMemory = DEBUGWin32FreeFileMemory,
    .DEBUGPlatformReadEntireFile = DEBUGWin32ReadEntireFile,
    .DEBUGPlatformWriteEntireFile = DEBUGWin32WriteEntireFile,
};

const Win32SoundOutput = struct {
    samples_per_second: u32,
    bytes_per_sample: u32,
    secondary_buffer_size: u32,
    running_sample_index: u32,
    latency_sample_count: u32,
    t_sine: f32,
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

pub fn DEBUGWin32ReadEntireFile(filename: [*:0]const u8) struct {u32, *anyopaque} {
    if (builtin.mode != .Debug) return .{.contents_size = 0, .contents = undefined};

    var result: struct { u32, *anyopaque } = .{ 0, undefined };

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
    result[1] = win32.mem.VirtualAlloc(
            null, file_size_32, .{ .RESERVE = 1, .COMMIT = 1}, .{ .PAGE_READWRITE = 1}
    ) orelse {
        return result;
    };

    var bytes_read: u32 = 0;
    if (win32.file.ReadFile(file_handle, result[1], file_size_32, &bytes_read, null) 
        != 0 and file_size_32 == bytes_read){
        // NOTE: File read successfully
        result[0] = bytes_read;
    } else {
        DEBUGWin32FreeFileMemory(result[1]);
        result[1] = undefined;
    }

    return result;
} 

pub fn DEBUGWin32FreeFileMemory(memory: *anyopaque) void { 
    if (builtin.mode != .Debug) return;

    _ = win32.mem.VirtualFree(memory, 0, .RELEASE);
}

pub fn DEBUGWin32WriteEntireFile(
    filename: [*:0]const u8,
    memory_size: u32,
    memory: *anyopaque
) bool {
    if (builtin.mode != .Debug) return false;

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

fn xInputGetStateStub(_: u32, _: ?*win32.xin.XINPUT_STATE) 
    callconv(winapi) isize {
    return @intFromEnum(win32.fnd.ERROR_DEVICE_NOT_CONNECTED);
}

fn xInputSetStateStub(_: u32, _: ?*win32.xin.XINPUT_VIBRATION) 
    callconv(winapi) isize {
    return @intFromEnum(win32.fnd.ERROR_DEVICE_NOT_CONNECTED);
}

fn win32LoadXInput() void {
    const library = win32.lib.LoadLibrary("xinput1_4.dll") orelse l: {
        break :l win32.lib.LoadLibrary("xinput9_1_0.dll");
    } orelse l: {
        // TODO: Diagnostic
        break :l win32.lib.LoadLibrary("xinput1_3.dll");
    } orelse {
        // TODO: Diagnostic
        return;
    };

    if (win32.lib.GetProcAddress(library, "XInputGetState")) |procedure| {
        xInputGetState = @as(@TypeOf(xInputGetState), @ptrCast(procedure));
    }

    if (win32.lib.GetProcAddress(library, "XInputGetState")) |procedure| {
        xInputSetState = @as(@TypeOf(xInputSetState), @ptrCast(procedure));
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
        .nBlockAlign = undefined,
        .nAvgBytesPerSec = undefined,
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
    var result: win32.fnd.LRESULT = undefined;

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
    var region_1_size: u32 = undefined;
    var region_2: ?*anyopaque = null;
    var region_2_size: u32 = undefined;

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
    source_buffer: *handmade.GameSoundOutputBuffer,
) void {
    var region_1: ?*anyopaque = null;
    var region_1_size: u32 = undefined;
    var region_2: ?*anyopaque = null;
    var region_2_size: u32 = undefined;

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
    new_state: *handmade.GameButtonState,
    is_down: bool,
) void {
    std.debug.assert(new_state.ended_down != is_down);
    new_state.ended_down = is_down;
    new_state.half_transition_count += 1;
}

fn win32ProcessXInputDigitalButton(
    x_input_button_state: u16,
    old_state: *handmade.GameButtonState, 
    button_bit: u32,
    new_state: *handmade.GameButtonState,
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

fn win32ProcessPendingMessages(keyboard_controller: *handmade.GameControllerInput) void {
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

    const window_class = win32.wm.WNDCLASS{
        .style = .{},
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

    const monitor_refresh_hz: i32 = 60;
    const game_update_hz: i32 = monitor_refresh_hz / 2;
    const target_seconds_per_frame: f32 = 1 / @as(f32, @floatFromInt(game_update_hz));

    win32LoadXInput();
    win32ResizeDIBSection(&global_back_buffer, 1280, 720);

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
    sound_output.latency_sample_count = sound_output.samples_per_second / 15;
    sound_output.running_sample_index = 0;
    sound_output.t_sine = 0;

    win32InitDSound(window, sound_output.samples_per_second, sound_output.secondary_buffer_size);
    win32ClearSoundBuffer(&sound_output);
    _ = global_secondary_buffer.?.Play(0, 0, win32.dsound.DSBPLAY_LOOPING);

    const samples: [*]i16 = @alignCast(@ptrCast(win32.mem.VirtualAlloc(
        null, sound_output.secondary_buffer_size,
        .{ .COMMIT = 1, .RESERVE = 1 }, win32.mem.PAGE_READWRITE) orelse {
        // TODO: Diagnostic
        return 0;
    }));

    const base_address: *allowzero anyopaque = if(builtin.mode == .Debug)
        @ptrFromInt(handmade.terabytes(2)) else @ptrFromInt(0);
    
    var game_memory: handmade.GameMemory = undefined;
    game_memory.permanent_storage_size = handmade.megabytes(64);
    game_memory.transient_storage_size = handmade.gigabytes(4);

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

    var input: [2]handmade.GameInput = .{ .{}, .{} };
    var new_input = &input[0];
    var old_input = &input[1];

    var last_counter = win32GetWallClock();
    var last_cycle_count = rdtsc();

    global_running = true;
    while (global_running) {
        const old_keyboard_controller = handmade.getController(old_input, 0);
        const new_keyboard_controller = handmade.getController(new_input, 0);
        new_keyboard_controller.* = .{
            .is_connected = true,
        };

        for (0..handmade.GameControllerInput.button_count) |idx| {
            new_keyboard_controller.button(idx).ended_down = 
                old_keyboard_controller.button(idx).ended_down; 
        }

        win32ProcessPendingMessages(new_keyboard_controller);

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

        var byte_to_lock: u32 = undefined;
        var target_cursor: u32 = undefined;
        var bytes_to_write: u32 = undefined;
        var play_cursor: u32 = undefined;
        var write_cursor: u32 = undefined;
        var sound_is_valid = false;
        // TODO: Tighten up sound logic so that we know where we should be 
        // writing to and can anticipate the time spent in the game update
        if (win32.zig.SUCCEEDED(
                global_secondary_buffer.?.GetCurrentPosition(&play_cursor, &write_cursor))) {
            sound_is_valid = true;

            byte_to_lock = (sound_output.running_sample_index * sound_output.bytes_per_sample) % 
                sound_output.secondary_buffer_size;

            target_cursor = (play_cursor + 
                (sound_output.latency_sample_count * sound_output.bytes_per_sample)) % 
                sound_output.secondary_buffer_size;

            if (byte_to_lock > target_cursor) {
                bytes_to_write = sound_output.secondary_buffer_size - byte_to_lock;
                bytes_to_write += target_cursor;
            } else {
                bytes_to_write = target_cursor - byte_to_lock;
            }
        }

        // TODO: Sound is wrong now, because we haven't updated 
        // it to go with the new frame loop.
        var sound_buffer = handmade.GameSoundOutputBuffer {
            .samples_per_second = sound_output.samples_per_second,
            .sample_count = bytes_to_write / sound_output.bytes_per_sample,
            .samples = samples,
        };

        var buffer = handmade.GameOffscreenBuffer{
            .memory = global_back_buffer.memory,
            .width = global_back_buffer.width,
            .height  = global_back_buffer.height,
            .pitch = global_back_buffer.pitch,
        };

        handmade.gameUpdateAndRender(&win32Platform, &game_memory, new_input, &buffer, &sound_buffer);

        if (sound_is_valid) {
            win32FillSoundBuffer(&sound_output, byte_to_lock, bytes_to_write, &sound_buffer);
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

            // const test_seconds_elapsed_for_frame = win32GetSecondsElapsed(last_counter, 
            //     win32GetWallClock());
            // std.debug.assert(test_seconds_elapsed_for_frame < target_seconds_per_frame);

            while (seconds_elapsed_per_frame < target_seconds_per_frame) {
                seconds_elapsed_per_frame = win32GetSecondsElapsed(last_counter, win32GetWallClock());
            }
        } else {
            // TODO: MISSED FRAME RATE!
            // TODO: Logging
        }

        const dimensions = win32GetWindowDimension(window);
        win32DrawBufferToWindow(&global_back_buffer, device_ctx, dimensions.width, dimensions.height);

        const temp = new_input;
        new_input = old_input;
        old_input = temp;

        const end_counter = win32GetWallClock();
        const ms_per_frame: f32 = 1000.0 * win32GetSecondsElapsed(last_counter, end_counter);
        last_counter = end_counter;

        const end_cycle_count = rdtsc();
        const cycles_elapsed = end_cycle_count - last_cycle_count;
        last_cycle_count = end_cycle_count;

        const fps: f64 = 0;
        const mc_per_frame: f64 = @as(f64, @floatFromInt(cycles_elapsed)) / (1000.0 * 1000.0);

        _ = ms_per_frame;
        _ = fps;
        _ = mc_per_frame;
        // std.debug.print(
        //     "{d: >10}ms/f, {d: >10}f/s, {d: >10}mc/f\n", 
        //     .{ms_per_frame, fps, mc_per_frame}
        // );
    }

    return 0;
}
