const std = @import("std");
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

var global_back_buffer = Win32OffscreenBuffer{
    .info = undefined,
    .memory = null,
    .width = 0,
    .height = 0,
    .pitch = 0,
    .bytes_per_pixel = 0,
};

// TODO: Global for now
var global_running: bool = true;

fn xInputGetStateStub(_: u32, _: ?*win32.xin.XINPUT_STATE) callconv(winapi) isize {
    return @intFromEnum(win32.fnd.ERROR_DEVICE_NOT_CONNECTED);
}

fn xInputSetStateStub(_: u32, _: ?*win32.xin.XINPUT_VIBRATION) callconv(winapi) isize {
    return @intFromEnum(win32.fnd.ERROR_DEVICE_NOT_CONNECTED);
}

var xInputGetState: *const fn (u32, ?*win32.xin.XINPUT_STATE) callconv(winapi) isize = &xInputGetStateStub;
var xInputSetState: *const fn (u32, ?*win32.xin.XINPUT_VIBRATION) callconv(winapi) isize = &xInputSetStateStub;

fn win32LoadXInput() void {
    const library = win32.lib.LoadLibrary("xinput1_4.dll") orelse l: {
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

fn win32InitDSound(window: win32.fnd.HWND, samples_per_second: u32, buffer_size: u32) void {
    // NOTE: Load the library
    const lib = win32.lib.LoadLibrary("dsound.dll") orelse {
        // TODO: Diagnostic
        std.debug.print("Failed to load dsound.dll!", .{});
        return;
    };

    const procedure = win32.lib.GetProcAddress(lib, "DirectSoundCreate") orelse {
        // TODO: Diagnostic
        std.debug.print("Failed to get DirectSoundCreate procedure!", .{});
        return;
    };
    win32DirectSoundCreate = @as(@TypeOf(win32DirectSoundCreate), @ptrCast(procedure));

    // NOTE: Get a DirectSound object
    var direct_sound_opt: ?*win32.dsound.IDirectSound = null;
    if (!win32.zig.SUCCEEDED(win32DirectSoundCreate(null, &direct_sound_opt, null)) or 
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

        if (!win32.zig.SUCCEEDED(primary_buffer.?.*.SetFormat(&wave_format))) {
            // TODO: Diagnostic
            std.debug.print("Failed to set primary sound buffer format!", .{}); 
            break :pb;
        }
        // ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
        // NOTE: The format has finally been set!
    } else {
        // TODO: Diagnostic
        std.debug.print("Failed to set direct sound object cooperation level!", .{}); 
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

    var secondary_buffer: ?*win32.dsound.IDirectSoundBuffer = null;
    if (!win32.zig.SUCCEEDED(direct_sound.CreateSoundBuffer(
                &buffer_desc, &secondary_buffer, null))) {
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

fn renderWeirdGradient(buffer: *Win32OffscreenBuffer, x_offset: i32, y_offset: i32) void {
    var row: [*]u8 = @as(?[*]u8, @ptrCast(buffer.*.memory)) orelse return;

    // NOTE: Written as bgrx due to endianness flipping
    const rgb = packed struct(u32) {
        b: u8 = 0,
        g: u8 = 0,
        r: u8 = 0,
        _: u8 = 0,
    };

    const b_height: usize = @intCast(buffer.*.height);
    const b_width: usize = @intCast(buffer.*.width);

    for (0..b_height) |y| {
        var pixel: [*]rgb = @ptrCast(@alignCast(row));
        for (1..b_width) |x| {
            const blue: u32 = @bitCast(@as(i32, @intCast(x)) + x_offset);
            const green: u32 = @bitCast(@as(i32, @intCast(y)) + y_offset);

            pixel[x] = .{
                .b = @truncate(blue),
                .g = @truncate(green),
                .r = 0,
            };
        }

        row += @intCast(buffer.*.pitch);
    }
}

fn win32ResizeDIBSection(buffer: *Win32OffscreenBuffer, width: i32, height: i32) void {
    if (buffer.*.memory != null) {
        _ = win32.mem.VirtualFree(buffer.*.memory, 0, win32.mem.MEM_RELEASE);
    }

    buffer.*.width = width;
    buffer.*.height = height;
    buffer.*.bytes_per_pixel = 4;

    // NOTE: When the biHeight field is negative, Windows treats the bitmap as 
    // topdown, not bottom up, meaning that the first three bytes correspond 
    // to the top-left pixel of the window
    buffer.*.info.bmiHeader.biSize = @sizeOf(win32.gdi.BITMAPINFOHEADER);
    buffer.*.info.bmiHeader.biWidth = buffer.*.width;
    buffer.*.info.bmiHeader.biHeight = -buffer.*.height;
    buffer.*.info.bmiHeader.biPlanes = 1;
    buffer.*.info.bmiHeader.biBitCount = 32;
    buffer.*.info.bmiHeader.biCompression = win32.gdi.BI_RGB;

    const memory_size: usize = @intCast(buffer.*.bytes_per_pixel * buffer.*.width * buffer.*.height);
    buffer.*.memory = win32.mem.VirtualAlloc(
        buffer.*.memory,
        memory_size,
        win32.mem.MEM_COMMIT,
        win32.mem.PAGE_READWRITE,
    );

    buffer.*.pitch = width * buffer.*.bytes_per_pixel;
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
        0, 0, buffer.*.width, buffer.*.height,
        buffer.*.memory,
        &buffer.*.info,
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
        win32.wm.WM_ACTIVATEAPP => win32.dbg.OutputDebugString("WM_ACTIVATEAPP\n"),
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
        else => result = win32.wm.DefWindowProc(window, message, w_param, l_param),
    }

         return result;
}

pub fn wWinMain(
    instance: ?win32.fnd.HINSTANCE,
    _: ?win32.fnd.HINSTANCE,
    _: [*:0]u16,
    _: u32,
) callconv(winapi) c_int {
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

    win32InitDSound(window, 48000, 48000 * @sizeOf(i16) * 2);

    var x_offset: i32 = 0;
    var y_offset: i32 = 0;
    while (global_running) : (x_offset += 1) {
        var message: win32.wm.MSG = undefined;
        while (win32.wm.PeekMessage(&message, null, 0, 0, win32.wm.PM_REMOVE) > 0) {
            if (message.message == win32.wm.WM_QUIT) {
                global_running = false;
            }

            _ = win32.wm.TranslateMessage(&message);
            _ = win32.wm.DispatchMessage(&message);
        }

        var controller_idx: u32 = 0;
        while(controller_idx < win32.xin.XUSER_MAX_COUNT) : (controller_idx += 1) {
            var controller_state: win32.xin.XINPUT_STATE = undefined;
            if (xInputGetState(controller_idx, &controller_state) 
                == @intFromEnum(win32.fnd.ERROR_SUCCESS)) {
                // NOTE:The controller is plugged in
                // TODO:See if controller_state.dwPacketNumber increments too rapidly
                const pad = &controller_state.Gamepad;

                // const up = pad.*.wButtons & win32.xin.XINPUT_GAMEPAD_DPAD_UP;
                // const down = pad.*.wButtons & win32.xin.XINPUT_GAMEPAD_DPAD_DOWN;
                // const left = pad.*.wButtons & win32.xin.XINPUT_GAMEPAD_DPAD_LEFT;
                // const right = pad.*.wButtons & win32.xin.XINPUT_GAMEPAD_DPAD_RIGHT;
                // const start = pad.*.wButtons & win32.xin.XINPUT_GAMEPAD_START;
                // const back = pad.*.wButtons & win32.xin.XINPUT_GAMEPAD_BACK;
                // const left_shoulder = pad.*.wButtons & win32.xin.XINPUT_GAMEPAD_LEFT_SHOULDER;
                // const right_shoulder = pad.*.wButtons & win32.xin.XINPUT_GAMEPAD_RIGHT_SHOULDER;
                // const a_button = pad.*.wButtons & win32.xin.XINPUT_GAMEPAD_A;
                // const b_button = pad.*.wButtons & win32.xin.XINPUT_GAMEPAD_B;
                // const x_button = pad.*.wButtons & win32.xin.XINPUT_GAMEPAD_X;
                // const y_button = pad.*.wButtons & win32.xin.XINPUT_GAMEPAD_Y;
                //
                const stick_x = pad.*.sThumbLX;
                const stick_y = pad.*.sThumbLY;

                x_offset += stick_x >> 12;
                y_offset += stick_y >> 12;
            } else {
                // NOTE:The controller is not available

            }
        }

        var vibration: win32.xin.XINPUT_VIBRATION = .{
            .wLeftMotorSpeed = 60000,
            .wRightMotorSpeed = 60000,
        };
        _ = xInputSetState(0, &vibration);

        renderWeirdGradient(&global_back_buffer, x_offset, y_offset);

        const device_ctx = win32.gdi.GetDC(window) orelse return 0;
        const dimensions = win32GetWindowDimension(window);
        win32DrawBufferToWindow(
            &global_back_buffer,
            device_ctx,
            dimensions.width,
            dimensions.height,
        );
        _ = win32.gdi.ReleaseDC(window, device_ctx);
    }

    return 0;
}
