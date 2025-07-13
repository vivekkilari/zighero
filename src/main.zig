const std = @import("std");
const WINAPI = std.os.windows.WINAPI;
const win32 = struct {
    const fnd = @import("win32").foundation;
    const wm = @import("win32").ui.windows_and_messaging;
};

pub fn wWinMain(_: ?win32.fnd.HINSTANCE, _: ?win32.fnd.HINSTANCE, _: [*:0]u16, _: u32) callconv(WINAPI) c_int {
    _ = win32.wm.MessageBoxA(null, "This is Zig Hero!", "ZigHero", .{ .ICONASTERISK = 1 });
    return 0;
}
