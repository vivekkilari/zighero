const std = @import("std");
const winapi = std.os.windows.WINAPI;
const win32 = struct {
    const winroot = @import("win32");
    const zig = winroot.zig;

    //  NOTE: Foundations has tons of win32 declarations
    const HWND = winroot.foundation.HWND;
    const RECT = winroot.foundation.RECT;
    const WPARAM = winroot.foundation.WPARAM;
    const LPARAM = winroot.foundation.LPARAM;
    const LRESULT = winroot.foundation.LRESULT;
    const HINSTANCE = winroot.foundation.HINSTANCE;

    const wm = winroot.ui.windows_and_messaging;
    const dbg = winroot.system.diagnostics.debug;
    const gdi = winroot.graphics.gdi;
};

// Required for win32 API to convert automatically choose ANSI : WIDE
pub const UNICODE = false;

// TODO: Make this more safe
var running = true;
const bitmap_info: ?*win32.gdi.BITMAPINFO = null;
var bitmap_memory: ?*?*anyopaque = undefined;
var bitmap_handle: ?win32.gdi.HBITMAP = undefined;
var bitmap_device_context: ?win32.gdi.HDC = undefined;

fn win32ResizeDIBSection(width: i32, height: i32) void {

    if (bitmap_handle != null) {
        _ = win32.gdi.DeleteObject(bitmap_handle);
    } 

    if (bitmap_device_context == null) {
        bitmap_device_context = win32.gdi.CreateCompatibleDC(null);
    }

    if (bitmap_info != null) {
        bitmap_info.?.bmiHeader.biSize = @sizeOf(win32.gdi.BITMAPINFOHEADER);
        bitmap_info.?.bmiHeader.biWidth = width;
        bitmap_info.?.bmiHeader.biHeight = height;
        bitmap_info.?.bmiHeader.biPlanes = 1;
        bitmap_info.?.bmiHeader.biBitCount = 32;
        bitmap_info.?.bmiHeader.biCompression = win32.gdi.BI_RGB;
    }
    // bitmap_info.bmiHeader.biSizeImage = 0;
    // bitmap_info.bmiHeader.biXPelsPerMeter = 0;
    // bitmap_info.bmiHeader.biYPelsPerMeter = 0;
    // bitmap_info.bmiHeader.biClrUsed = 0;
    // bitmap_info.bmiHeader.biClrImportant = 0;
    
    bitmap_handle = win32.gdi.CreateDIBSection(
        bitmap_device_context,
        bitmap_info,
        win32.gdi.DIB_USAGE.RGB_COLORS,
        bitmap_memory,
        null, 0,
    );
}

fn win32UpdateWindow(device_context: win32.gdi.HDC, x: i32, y: i32, width: i32, height: i32) void {
    win32.gdi.StretchDIBits(
        device_context,
        x, y, width, height,
        x, y, width, height,
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
            const paint: ?*win32.gdi.PAINTSTRUCT = null;
            const deviceContext = win32.gdi.BeginPaint(window, paint);

            if (paint != null) {
                const rect = paint.?.*.rcPaint;
                const x = rect.left;
                const y = rect.top;
                const width = rect.right - rect.left;
                const height = rect.bottom - rect.top;
                win32UpdateWindow(deviceContext, x, y, width, height);
                _ = win32.gdi.PatBlt(deviceContext, x, y, width, height, win32.gdi.WHITENESS);
            }

            _ = win32.gdi.EndPaint(window, paint);
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

    if (win32.wm.RegisterClass(&window_class) > 0) {
        const window_handle = win32.wm.CreateWindowEx(
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
        );

        if (window_handle != null) {
            while (running) {
                var message: win32.wm.MSG = undefined;
                const message_result = win32.wm.GetMessage(&message, null, 0, 0);
                if (message_result > 0) {
                    _ = win32.wm.TranslateMessage(&message);
                    _ = win32.wm.DispatchMessage(&message);
                } else {
                    break;
                }
            }
        } else {}
    } else {}
    return 0;
}
