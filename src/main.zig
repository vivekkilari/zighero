const std = @import("std");
const winapi = std.os.windows.WINAPI;
const win32 = struct {
    const winroot = @import("win32");
    const zig = winroot.zig;

    //  NOTE: Foundations has tons of win32 declarations
    const HWND = winroot.foundation.HWND;
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

pub fn windowCallback(
    window: win32.HWND,
    message: u32,
    w_param: win32.WPARAM,
    l_param: win32.LPARAM,
) callconv(winapi) win32.LRESULT {
    var result: win32.LRESULT = undefined;

    switch (message) {
        win32.wm.WM_SIZE => win32.dbg.OutputDebugString("WM_SIZE\n"),
        win32.wm.WM_DESTROY => win32.dbg.OutputDebugString("WM_DESTROY\n"),
        win32.wm.WM_CLOSE => win32.dbg.OutputDebugString("WM_CLOSE\n"),
        win32.wm.WM_ACTIVATEAPP => win32.dbg.OutputDebugString("WM_ACTIVATEAPP\n"),
        win32.wm.WM_PAINT => {
            const paint: ?*win32.gdi.PAINTSTRUCT = null;
            const deviceCtx = win32.gdi.BeginPaint(window, paint);

            if (paint != null) {
                const rect = paint.?.*.rcPaint;
                const x = rect.left;
                const y = rect.top;
                const width = rect.right - rect.left;
                const height = rect.bottom - rect.top;
                _ = win32.gdi.PatBlt(deviceCtx, x, y, width, height, win32.gdi.WHITENESS);
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
        .lpfnWndProc = windowCallback,
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
            while (true) {
                var message: win32.wm.MSG = undefined;
                const messageResult = win32.wm.GetMessage(&message, null, 0, 0);
                if (messageResult > 0) {
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
