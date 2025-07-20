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
    const xin = root.ui.input.xbox_controller;
    const km = root.ui.input.keyboard_and_mouse;
    const lib = root.system.library_loader;
    const audio = root.media.audio;
    const dsound = audio.direct_sound;
    const com = root.system.com;
    const perf = root.system.performance;
};

const Win32OffscreenBuffer = struct {
    info: win32.gdi.BITMAPINFO,
    memory: ?*anyopaque,
    width: i32,
    height: i32,
    pitch: i32,
    bytes_per_pixel: u4,
};

// NOTE: Required for win32 API to convert automatically choose ? ANSI : WIDE
pub const UNICODE = false;

// TODO: Global for now
var global_running: bool = true;
var global_back_buffer = Win32OffscreenBuffer{
    .info = undefined,
    .memory = null,
    .width = 0,
    .height = 0,
    .pitch = 0,
    .bytes_per_pixel = 0,
};
var global_secondary_buffer: ?*win32.dsound.IDirectSoundBuffer = null;

fn xInputGetStateStub(
    _: u32, 
    _: ?*win32.xin.XINPUT_STATE,
) callconv(winapi) isize {
    return @intFromEnum(win32.fnd.ERROR_DEVICE_NOT_CONNECTED);
}

fn xInputSetStateStub(
    _: u32, 
    _: ?*win32.xin.XINPUT_VIBRATION,
) callconv(winapi) isize {
    return @intFromEnum(win32.fnd.ERROR_DEVICE_NOT_CONNECTED);
}

var xInputGetState: *const fn (u32, ?*win32.xin.XINPUT_STATE) 
    callconv(winapi) isize = &xInputGetStateStub;
var xInputSetState: *const fn (u32, ?*win32.xin.XINPUT_VIBRATION) 
    callconv(winapi) isize = &xInputSetStateStub;

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

var win32DirectSoundCreate: *const fn (
    pcGuidDevice: ?*const win32.zig.Guid, 
    ppDS: ?*?*win32.dsound.IDirectSound,
    pUnkOuter: ?*win32.com.IUnknown,
) callconv(winapi) win32.fnd.HRESULT = undefined;

fn win32InitDSound(
    window: win32.fnd.HWND, 
    samples_per_second: u32,
    buffer_size: u32,
) void {
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
    if (!win32.zig.SUCCEEDED(win32DirectSoundCreate(
                null, &direct_sound_opt, null)) or direct_sound_opt == null) {
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
    wave_format.nBlockAlign = 
        (wave_format.nChannels * wave_format.wBitsPerSample) / 8;
    wave_format.nAvgBytesPerSec = 
        wave_format.nSamplesPerSec * wave_format.nBlockAlign;


    var direct_sound: *win32.dsound.IDirectSound = direct_sound_opt.?;
    if (win32.zig.SUCCEEDED(direct_sound.SetCooperativeLevel(
                window, win32.dsound.DSSCL_PRIORITY))) pb: {

        var buffer_desc = win32.dsound.DSBUFFERDESC{
            .dwSize = @sizeOf(win32.dsound.DSBUFFERDESC),
            .dwFlags = win32.dsound.DSBCAPS_PRIMARYBUFFER,
            .dwBufferBytes = 0,
            .dwReserved = 0,
            .guid3DAlgorithm = win32.zig.Guid
                .initString("00000000-0000-0000-0000-000000000000"),
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
        // ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
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
        .guid3DAlgorithm = win32.zig.Guid
            .initString("00000000-0000-0000-0000-000000000000"),
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

fn win32GetWindowDimension(window: win32.fnd.HWND) struct {
    width: i32, 
    height: i32 
} {
    var rect: win32.fnd.RECT = undefined;
    _ = win32.wm.GetClientRect(window, &rect);

    return .{
        .width = rect.right - rect.left,
        .height = rect.bottom - rect.top,
    };
}

fn win32ResizeDIBSection(
    buffer: *Win32OffscreenBuffer,
    width: i32,
    height: i32,
) void {
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

    msg: switch (message) {
        win32.wm.WM_CLOSE, win32.wm.WM_DESTROY => {
            global_running = false;
        },
        win32.wm.WM_ACTIVATEAPP => 
            win32.dbg.OutputDebugString("WM_ACTIVATEAPP\n"),
        win32.wm.WM_SYSKEYDOWN, 
        win32.wm.WM_SYSKEYUP,
        win32.wm.WM_KEYDOWN,
        win32.wm.WM_KEYUP => {
            const vk_code: u8 = @intCast(w_param);
            const was_down = (l_param & (1 << 30)) != 0;
            const is_down = (l_param & (1 << 31)) == 0;

            if (was_down == is_down) break :msg;

            switch (vk_code) {
                'W' => {},
                'A' => {},
                'S' => {},
                'D' => {},
                'Q' => {},
                'E' => {},
                @intFromEnum(win32.km.VK_UP) => {},
                @intFromEnum(win32.km.VK_LEFT) => {},
                @intFromEnum(win32.km.VK_DOWN) => {},
                @intFromEnum(win32.km.VK_RIGHT) => {},
                @intFromEnum(win32.km.VK_ESCAPE) => {
                    std.debug.print("ESCAPE: ", .{});
                    if (is_down) std.debug.print("IsDown ", .{});
                    if (was_down) std.debug.print("WASDOWN", .{});
                    std.debug.print("\n", .{});
                },
                @intFromEnum(win32.km.VK_SPACE) => {},
                @intFromEnum(win32.km.VK_F4) => {
                    const alt_key_was_down = (l_param & (1 << 29)) != 0;
                    if (!alt_key_was_down) return 0;

                    global_running = false;
                },
                else => {}
            }

        },
        win32.wm.WM_PAINT => {
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
        else => 
            result = win32.wm.DefWindowProc(window, message, w_param, l_param),
    }

         return result;
}

const Win32SoundOutput = struct {
    samples_per_second: u32,
    wave_period: u32,
    bytes_per_sample: u32,
    secondary_buffer_size: u32,
    running_sample_index: u32,
    latency_sample_count: u32,
    t_sine: f32,
    tone_hz: i32,
    tone_volume: i16,
};

fn win32FillSoundBuffer(
    sound_output: *Win32SoundOutput,
    byte_to_lock: u32,
    bytes_to_write: u32,
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

    if (region_1) |region| {
        var sample_out: [*] align(1) i16 = @alignCast(@ptrCast(region));
        const region_1_sample_count: usize = region_1_size / sound_output.bytes_per_sample;
        for (0..region_1_sample_count) |_| {
            const sine_value: f32 = @sin(sound_output.t_sine);
            const sample_value: i16 = @intFromFloat(
                sine_value * @as(f32, @floatFromInt(sound_output.tone_volume)));

            sample_out[0] = sample_value;
            sample_out += 1;
            sample_out[0] = sample_value;
            sample_out += 1;

            sound_output.t_sine += std.math.tau /
                @as(f32, @floatFromInt(sound_output.wave_period));
            sound_output.running_sample_index += 1;
        }
    }


    if (region_2) |region| {
        var sample_out: [*] align(1) i16 = @alignCast(@ptrCast(region));
        const region_2_sample_count: usize = region_2_size / sound_output.bytes_per_sample;
        for (0..region_2_sample_count) |_| {
            const sine_value: f32 = @sin(sound_output.t_sine);
            const sample_value: i16 = @intFromFloat(sine_value * 
                @as(f32, @floatFromInt(sound_output.tone_volume)));

            sample_out[0] = sample_value;
            sample_out += 1;
            sample_out[0] = sample_value;
            sample_out += 1;

            sound_output.t_sine += std.math.tau /
                @as(f32, @floatFromInt(sound_output.wave_period));
            sound_output.running_sample_index += 1;
        }
    }

    _ = global_secondary_buffer.?.Unlock(
        region_1, region_1_size, 
        region_2, region_2_size,
    );
}

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

pub fn wWinMain(
    instance: ?win32.fnd.HINSTANCE,
    _: ?win32.fnd.HINSTANCE,
    _: [*:0]u16,
    _: u32,
) callconv(winapi) c_int {
    var perf_count_frequency_result: win32.fnd.LARGE_INTEGER = undefined;
    _ = win32.perf.QueryPerformanceFrequency(&perf_count_frequency_result);
    const perf_count_frequency = perf_count_frequency_result.QuadPart;

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

    // NOTE: Graphics test
    var x_offset: i32 = 0;
    var y_offset: i32 = 0;

    var sound_output: Win32SoundOutput = undefined;
    sound_output.samples_per_second = 48000;
    sound_output.tone_hz = 256;
    sound_output.wave_period = 
        sound_output.samples_per_second / @as(u32, @intCast(sound_output.tone_hz));
    sound_output.bytes_per_sample = @sizeOf(i16) * 2;
    sound_output.secondary_buffer_size = 
        sound_output.samples_per_second * sound_output.bytes_per_sample;
    sound_output.latency_sample_count = sound_output.samples_per_second / 15;
    sound_output.running_sample_index = 0;
    sound_output.t_sine = 0;
    sound_output.tone_volume = 3000;

    win32InitDSound(
        window, 
        sound_output.samples_per_second,
        sound_output.secondary_buffer_size,
    );
    win32FillSoundBuffer(&sound_output, 0, 
        sound_output.latency_sample_count * sound_output.bytes_per_sample);
    _ = global_secondary_buffer.?.Play(0, 0, win32.dsound.DSBPLAY_LOOPING);


    var last_counter: win32.fnd.LARGE_INTEGER = undefined;
    _ = win32.perf.QueryPerformanceCounter(&last_counter);
    var last_cycle_count: u64 = rdtsc();

    while (global_running) : (x_offset += 1) {
        var message: win32.wm.MSG = undefined;
        while (win32.wm.PeekMessage(
                &message, null, 0, 0, win32.wm.PM_REMOVE) > 0) {
            if (message.message == win32.wm.WM_QUIT) {
                global_running = false;
            }

            _ = win32.wm.TranslateMessage(&message);
            _ = win32.wm.DispatchMessage(&message);
        }

        var controller_idx: u32 = 0;
        while(controller_idx < win32.xin.XUSER_MAX_COUNT) : 
            (controller_idx += 1) {
            var controller_state: win32.xin.XINPUT_STATE = undefined;
            if (xInputGetState(controller_idx, &controller_state) 
                == @intFromEnum(win32.fnd.ERROR_SUCCESS)) {
                // NOTE: The controller is plugged in
                // TODO: See if controller_state.dwPacketNumber increments too rapidly
                const pad = &controller_state.Gamepad;

                // const up = pad.wButtons & win32.xin.XINPUT_GAMEPAD_DPAD_UP;
                // const down = pad.wButtons & win32.xin.XINPUT_GAMEPAD_DPAD_DOWN;
                // const left = pad.wButtons & win32.xin.XINPUT_GAMEPAD_DPAD_LEFT;
                // const right = pad.wButtons & win32.xin.XINPUT_GAMEPAD_DPAD_RIGHT;
                // const start = pad.wButtons & win32.xin.XINPUT_GAMEPAD_START;
                // const back = pad.wButtons & win32.xin.XINPUT_GAMEPAD_BACK;
                // const left_shoulder = pad.wButtons & win32.xin.XINPUT_GAMEPAD_LEFT_SHOULDER;
                // const right_shoulder = pad.wButtons & win32.xin.XINPUT_GAMEPAD_RIGHT_SHOULDER;
                // const a_button = pad.wButtons & win32.xin.XINPUT_GAMEPAD_A;
                // const b_button = pad.wButtons & win32.xin.XINPUT_GAMEPAD_B;
                // const x_button = pad.wButtons & win32.xin.XINPUT_GAMEPAD_X;
                // const y_button = pad.wButtons & win32.xin.XINPUT_GAMEPAD_Y;

                const stick_x = pad.sThumbLX;
                const stick_y = pad.sThumbLY;

                // TODO: Will do deadzone handling later

                x_offset += @divTrunc(stick_x, @as(i16, 4096));
                y_offset += @divTrunc(stick_y, @as(i16, 4096));

                sound_output.tone_hz = 512 + @as(i32, @intFromFloat(256 * (@as(f32, @floatFromInt(stick_y)) / 30000.0)));
                sound_output.wave_period = 
                    sound_output.samples_per_second / @as(u32, @intCast(sound_output.tone_hz));
            } else {
                // NOTE:The controller is not available
            }
        }

        var vibration: win32.xin.XINPUT_VIBRATION = .{
            .wLeftMotorSpeed = 60000,
            .wRightMotorSpeed = 60000,
        };
        _ = xInputSetState(0, &vibration);

        var buffer = handmade.GameOffscreenBuffer{
            .memory = global_back_buffer.memory,
            .width = global_back_buffer.width,
            .height  = global_back_buffer.height,
            .pitch = global_back_buffer.pitch,
        };

        handmade.gameUpdateAndRender(&buffer, x_offset, y_offset);

        var play_cursor: u32 = undefined;
        var write_cursor: u32 = undefined;
        if (win32.zig.SUCCEEDED(global_secondary_buffer.?.GetCurrentPosition(
                    &play_cursor, &write_cursor))) {

            const byte_to_lock = 
                (sound_output.running_sample_index * sound_output.bytes_per_sample) % 
                sound_output.secondary_buffer_size;

            const target_cursor = (play_cursor + 
                (sound_output.latency_sample_count * sound_output.bytes_per_sample)) % 
                sound_output.secondary_buffer_size;

            var bytes_to_write: u32 = undefined;

            if (byte_to_lock > target_cursor) {
                bytes_to_write = sound_output.secondary_buffer_size - byte_to_lock;
                bytes_to_write += target_cursor;
            } else {
                bytes_to_write = target_cursor - byte_to_lock;
            }

            win32FillSoundBuffer(&sound_output, byte_to_lock, bytes_to_write);
        }

        const device_ctx = win32.gdi.GetDC(window) orelse return 0;
        const dimensions = win32GetWindowDimension(window);
        win32DrawBufferToWindow(
            &global_back_buffer,
            device_ctx,
            dimensions.width,
            dimensions.height,
        );
        _ = win32.gdi.ReleaseDC(window, device_ctx);

        const end_cycle_count: u64 = rdtsc();

        var end_counter: win32.fnd.LARGE_INTEGER = undefined;
        _ = win32.perf.QueryPerformanceCounter(&end_counter);

        const cycles_elapsed = end_cycle_count - last_cycle_count;
        const counter_elapsed = end_counter.QuadPart - last_counter.QuadPart;
        const ms_per_frame: f32 = @as(f32, @floatFromInt((1000 * counter_elapsed))) / 
            @as(f32, @floatFromInt(perf_count_frequency));
        const fps: f32 = @floatFromInt(@divTrunc(perf_count_frequency, counter_elapsed));
        const mc_per_frame: f32 = @as(f32, @floatFromInt(cycles_elapsed)) / (1000.0 * 1000.0);

        _ = ms_per_frame; 
        _ = fps;
        _ = mc_per_frame;
        // std.debug.print("{d: >10}ms/f, {d: >10}f/s, {d: >10}mc/f\n", .{ms_per_frame, fps, mc_per_frame});

        last_counter = end_counter;
        last_cycle_count = end_cycle_count;
    }

    return 0;
}
