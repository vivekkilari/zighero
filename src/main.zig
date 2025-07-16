const std = @import("std");
const winapi = std.os.windows.WINAPI;
const win32 = struct {
    const winroot = @import("win32");
    const zig = winroot.zig;

    // NOTE: Foundations has tons of win32 declarations
    const HWND = winroot.foundation.HWND;
    const RECT = winroot.foundation.RECT;
    const WPARAM = winroot.foundation.WPARAM;
    const LPARAM = winroot.foundation.LPARAM;
    const LRESULT = winroot.foundation.LRESULT;
    const HINSTANCE = winroot.foundation.HINSTANCE;

    const wm = winroot.ui.windows_and_messaging;
    const dbg = winroot.system.diagnostics.debug;
    const gdi = winroot.graphics.gdi;
    const mem = winroot.system.memory;
};

// NOTE: Required for win32 API to convert automatically choose ? ANSI : WIDE
pub const UNICODE = false;

// TODO: Make this section more safe
const bytes_per_pixel = 4;
var running = true;
var bitmap_info: win32.gdi.BITMAPINFO = undefined;
var bitmap_memory: ?*anyopaque = null;
var bitmap_width: i32 = undefined;
var bitmap_height: i32 = undefined;

fn RenderWeirdGradient(x_offset: i32, y_offset: i32) void {
    const pitch = bitmap_width * bytes_per_pixel;
    var row: ?[*]u8 = @ptrCast(bitmap_memory);

    if (row == null) return;

    const b_height: usize = @intCast(bitmap_height);
    const b_width: usize = @intCast(bitmap_width);

    const rgb = packed struct(u32) {
        b: u8 = 0,
        g: u8 = 0,
        r: u8 = 0,
        _: u8 = 0,
    };

    for (0..b_height) |y| {
        var pixel: [*]rgb = @ptrCast(@alignCast(row));
        for (0..b_width) |x| {

            const blue: u32 = @bitCast(@as(i32, @intCast(x)) + x_offset);
            const green: u32 = @bitCast(@as(i32, @intCast(y)) + y_offset);

            pixel[x]  = .{
                .b = @truncate(blue),
                .g = @truncate(green),
                .r = 0,
            };
        }
        
        row.? += @intCast(pitch);
    }
}


fn win32ResizeDIBSection(width: i32, height: i32) void {
    if (bitmap_memory != null) {
        _ = win32.mem.VirtualFree(bitmap_memory, 0, win32.mem.MEM_RELEASE);
    }

    bitmap_width = width;
    bitmap_height = height;

    bitmap_info.bmiHeader.biSize = @sizeOf(win32.gdi.BITMAPINFOHEADER);
    bitmap_info.bmiHeader.biWidth = bitmap_width;
    bitmap_info.bmiHeader.biHeight = -bitmap_height;
    bitmap_info.bmiHeader.biPlanes = 1;
    bitmap_info.bmiHeader.biBitCount = 32;
    bitmap_info.bmiHeader.biCompression = win32.gdi.BI_RGB;

    const bitmap_memory_size: usize = @intCast(bytes_per_pixel * bitmap_width * bitmap_height);
    bitmap_memory = win32.mem.VirtualAlloc(
        bitmap_memory, bitmap_memory_size, 
        win32.mem.MEM_COMMIT,
        win32.mem.PAGE_READWRITE,
    );
}

fn win32UpdateWindow(device_context: win32.gdi.HDC, client_rect: *win32.RECT, x: i32, y: i32, _: i32, _: i32) void {
    const window_width = client_rect.*.right - client_rect.*.left;
    const window_height = client_rect.*.bottom - client_rect.*.top;
    _ = win32.gdi.StretchDIBits(
        device_context,
        0, 0, bitmap_width, bitmap_height,
        x, y, window_width, window_height,
        bitmap_memory,
        &bitmap_info,
        win32.gdi.DIB_USAGE.RGB_COLORS,
        win32.gdi.SRCCOPY,
    );
}

fn win32WindowCallback(
    window: win32.HWND,
    message: u32,
    w_param: win32.WPARAM,
    l_param: win32.LPARAM,
) callconv(winapi) win32.LRESULT {
    var result: win32.LRESULT = undefined;

    switch (message) {
        win32.wm.WM_SIZE => {
            var rect: win32.RECT = undefined;
            _ = win32.wm.GetClientRect(window, &rect);
            const width = rect.right - rect.left;
            const height = rect.bottom - rect.top;
            win32ResizeDIBSection(width, height);
        },
        win32.wm.WM_CLOSE => {
            running = false;
        },
        win32.wm.WM_DESTROY => {
            running = false;
        },
        win32.wm.WM_ACTIVATEAPP => win32.dbg.OutputDebugString("WM_ACTIVATEAPP\n"),
        win32.wm.WM_PAINT => {
            var paint: win32.gdi.PAINTSTRUCT = undefined;
            const deviceContext = win32.gdi.BeginPaint(window, &paint);

            if (deviceContext != null) {
                const x = paint.rcPaint.left;
                const y = paint.rcPaint.top;
                const width = paint.rcPaint.right - x;
                const height = paint.rcPaint.bottom - y;

                var rect: win32.RECT = undefined;
                _ = win32.wm.GetClientRect(window, &rect);

                win32UpdateWindow(deviceContext.?, &rect, x, y, width, height);
            }

            _ = win32.gdi.EndPaint(window, &paint);
        },
        else => result = win32.wm.DefWindowProc(window, message, w_param, l_param),
    }

    return result;
}

pub fn wWinMain(
    instance: ?win32.HINSTANCE,
    _: ?win32.HINSTANCE,
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

    if (win32.wm.RegisterClass(&window_class) < 1) return 0;
    const window = win32.wm.CreateWindowEx(
        .{}, window_class.lpszClassName,
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
        null, null, instance, null,
    );

    if (window == null) return 0;

    var x: i32 = 0;
    var y: i32 = 0;
    while (running) : ({ x += 1; y += 1; }) {
        var message: win32.wm.MSG = undefined;
        while (win32.wm.PeekMessage(&message, null, 0, 0, win32.wm.PM_REMOVE) > 0) {
            if (message.message == win32.wm.WM_QUIT) {
                running = false;
            }

            _ = win32.wm.TranslateMessage(&message);
            _ = win32.wm.DispatchMessage(&message);
        }
        RenderWeirdGradient(x, y);

        const device_ctx = win32.gdi.GetDC(window);
        var client_rect: win32.RECT = undefined;
        _ = win32.wm.GetClientRect(window, &client_rect);
        const width = client_rect.right - client_rect.left;
        const height = client_rect.bottom - client_rect.top;
        win32UpdateWindow(device_ctx.?, &client_rect, 0, 0, width, height);
        _ = win32.gdi.ReleaseDC(window, device_ctx);
    }

    return 0;
}
