// TODO: Services that the platform layer provides to the game
//
// TODO: Services that the game provides to the platform layer.
// (this may expand in the future - sound on separate thread, etc.)
//

// TODO: In the future, rendering _specifically_ will become a three-tiered abstraction!!!
pub const GameOffscreenBuffer = struct {
    memory: ?*anyopaque,
    width: i32,
    height: i32,
    pitch: i32,
};

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

pub fn gameUpdateAndRender(buffer: *GameOffscreenBuffer, blue_offset: i32, green_offset: i32) void {
    renderWeirdGradient(buffer, blue_offset, green_offset);
}
