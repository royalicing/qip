const std = @import("std");

const RENDER_W: usize = 320;
const RENDER_H: usize = 220;
const OUTPUT_BYTES: usize = RENDER_W * RENDER_H * 4;

const BTN_PRIMARY: i32 = 1 << 0;
const FLAG_KEY_DOWN: i32 = 1 << 0;

const Color = [4]u8;
const C_BG: Color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
const C_TEXT: Color = .{ 0x0B, 0x13, 0x0B, 0xFF };
const C_YELLOW: Color = .{ 0xDD, 0xBB, 0x02, 0xFF };
const C_BLUE: Color = .{ 0x10, 0x88, 0xFF, 0xFF };
const C_PURPLE: Color = .{ 0xAA, 0x22, 0xFF, 0xFF };

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var total_tick_count: i32 = 0;
var total_render_count: i32 = 0;
var total_key_count: i32 = 0;
var total_pointer_count: i32 = 0;
var last_tick_ms: i32 = 0;
var last_key_ms: i32 = 0;
var last_key_char: u8 = 0;
var last_pointer_ms: i32 = 0;
var needs_redraw: bool = false;

export fn output_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&output_buf[0])));
}

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_BYTES));
}

export fn render_width_px() i32 {
    return @as(i32, @intCast(RENDER_W));
}

export fn render_height_px() i32 {
    return @as(i32, @intCast(RENDER_H));
}

export fn key_event(x11_key: i32, flags: i32, ms: i32) i32 {
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;

    switch (x11_key) {
        '0'...'9', 'a'...'z' => last_key_char = @as(u8, @intCast(x11_key)),
        else => return 0,
    }
    total_key_count += 1;
    last_key_ms = ms;
    needs_redraw = true;
    return 1;
}

export fn pointer_event(_: i32, _: i32, _: i32, ms: i32) i32 {
    total_pointer_count += 1;
    last_pointer_ms = ms;
    return 0;
}

export fn tick(now_ms: i32) i32 {
    total_tick_count += 1;
    last_tick_ms = now_ms;
    return if (needs_redraw) 1 else 0;
}

export fn render_output() i32 {
    total_render_count += 1;
    drawFrame();
    needs_redraw = false;
    return @as(i32, @intCast(OUTPUT_BYTES));
}

fn parseFloat(s: []const u8) f64 {
    var value: f64 = 0;
    var frac: f64 = 0.1;
    var after_dot = false;
    for (s) |ch| {
        if (ch == '.') {
            after_dot = true;
        } else if (ch >= '0' and ch <= '9') {
            const d = @as(f64, @floatFromInt(ch - '0'));
            if (after_dot) {
                value += d * frac;
                frac *= 0.1;
            } else {
                value = value * 10 + d;
            }
        }
    }
    return value;
}

fn drawFrame() void {
    fillRect(0, 0, RENDER_W, RENDER_H, C_BG);

    var print_buf: [32]u8 = undefined;

    drawText(20, 20, print32(&print_buf, total_key_count, ""), C_YELLOW);
    drawText(80, 20, print32(&print_buf, last_key_ms, "ms key"), C_YELLOW);
    drawText(200, 20, &[1]u8{last_key_char}, C_YELLOW);

    drawText(20, 40, print32(&print_buf, total_pointer_count, ""), C_YELLOW);
    drawText(80, 40, print32(&print_buf, last_pointer_ms, "ms pointer"), C_YELLOW);

    drawText(20, 60, print32(&print_buf, total_tick_count, ""), C_PURPLE);
    drawText(80, 60, print32(&print_buf, last_tick_ms, "ms tick"), C_PURPLE);

    drawText(20, 80, print32(&print_buf, total_render_count, ""), C_BLUE);
}

fn print32(buf: *[32]u8, number: i32, item: []const u8) []const u8 {
    var value: u32 = @as(u32, @intCast(@max(1, number)));
    var digits_rev: [10]u8 = undefined;
    var digits_len: usize = 0;
    while (true) {
        digits_rev[digits_len] = @as(u8, @intCast('0')) + @as(u8, @intCast(value % 10));
        digits_len += 1;
        value = @divTrunc(value, 10);
        if (value == 0) break;
    }

    var out: usize = 0;
    var i = digits_len;
    while (i > 0) {
        i -= 1;
        buf[out] = digits_rev[i];
        out += 1;
    }
    buf[out] = '.';
    out += 1;
    buf[out] = ' ';
    out += 1;

    const copy_len = @min(item.len, buf.len - out);
    std.mem.copyForwards(u8, buf[out .. out + copy_len], item[0..copy_len]);
    return buf[0 .. out + copy_len];
}

fn drawText(x: i32, y: i32, text: []const u8, c: Color) void {
    var i: usize = 0;
    while (i < text.len and i < 36) : (i += 1) drawChar(x + @as(i32, @intCast(i * 7)), y, text[i], c);
}

fn drawChar(x: i32, y: i32, ch: u8, c: Color) void {
    const rows = switch (ch) {
        '0' => [_]u8{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        '1' => [_]u8{ 0b010, 0b110, 0b010, 0b010, 0b111 },
        '2' => [_]u8{ 0b111, 0b001, 0b111, 0b100, 0b111 },
        '3' => [_]u8{ 0b111, 0b001, 0b111, 0b001, 0b111 },
        '4' => [_]u8{ 0b101, 0b101, 0b111, 0b001, 0b001 },
        '5' => [_]u8{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        '6' => [_]u8{ 0b111, 0b100, 0b111, 0b101, 0b111 },
        '7' => [_]u8{ 0b111, 0b001, 0b001, 0b001, 0b001 },
        '8' => [_]u8{ 0b111, 0b101, 0b111, 0b101, 0b111 },
        '9' => [_]u8{ 0b111, 0b101, 0b111, 0b001, 0b111 },
        'Y', 'y' => [_]u8{ 0b101, 0b101, 0b010, 0b010, 0b010 },
        'X', 'x' => [_]u8{ 0b101, 0b101, 0b010, 0b101, 0b101 },
        'E' => [_]u8{ 0b111, 0b100, 0b110, 0b100, 0b111 },
        'R' => [_]u8{ 0b110, 0b101, 0b110, 0b101, 0b101 },
        's' => [_]u8{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        'i' => [_]u8{ 0b010, 0b000, 0b010, 0b010, 0b010 },
        'n' => [_]u8{ 0b000, 0b110, 0b101, 0b101, 0b101 },
        'c' => [_]u8{ 0b000, 0b111, 0b100, 0b100, 0b111 },
        'o' => [_]u8{ 0b000, 0b111, 0b101, 0b101, 0b111 },
        't' => [_]u8{ 0b010, 0b111, 0b010, 0b010, 0b011 },
        'a' => [_]u8{ 0b000, 0b111, 0b001, 0b111, 0b111 },
        'q' => [_]u8{ 0b000, 0b111, 0b101, 0b111, 0b001 },
        'r' => [_]u8{ 0b000, 0b101, 0b110, 0b100, 0b100 },
        '+', '=' => [_]u8{ 0b000, 0b010, 0b111, 0b010, 0b000 },
        '-' => [_]u8{ 0b000, 0b000, 0b111, 0b000, 0b000 },
        '*' => [_]u8{ 0b101, 0b010, 0b111, 0b010, 0b101 },
        '/' => [_]u8{ 0b001, 0b001, 0b010, 0b100, 0b100 },
        '^' => [_]u8{ 0b010, 0b101, 0b000, 0b000, 0b000 },
        '(' => [_]u8{ 0b001, 0b010, 0b010, 0b010, 0b001 },
        ')' => [_]u8{ 0b100, 0b010, 0b010, 0b010, 0b100 },
        '.' => [_]u8{ 0b000, 0b000, 0b000, 0b000, 0b010 },
        else => [_]u8{ 0, 0, 0, 0, 0 },
    };
    drawRows(x, y, rows, c);
}

fn drawRows(x0: i32, y0: i32, rows: [5]u8, c: Color) void {
    var y: usize = 0;
    while (y < 5) : (y += 1) {
        var x: usize = 0;
        while (x < 3) : (x += 1) {
            if ((rows[y] & (@as(u8, 1) << @as(u3, @intCast(2 - x)))) != 0) fillRectI32(x0 + @as(i32, @intCast(x * 2)), y0 + @as(i32, @intCast(y * 2)), 2, 2, c);
        }
    }
}

fn fillRect(x0: usize, y0: usize, w: usize, h: usize, c: Color) void {
    var y = y0;
    while (y < y0 + h and y < RENDER_H) : (y += 1) {
        var x = x0;
        while (x < x0 + w and x < RENDER_W) : (x += 1) setPixel(x, y, c);
    }
}

fn fillRectI32(x0: i32, y0: i32, w: i32, h: i32, c: Color) void {
    if (w <= 0 or h <= 0) return;
    const sx = @max(0, x0);
    const sy = @max(0, y0);
    const ex = @min(@as(i32, @intCast(RENDER_W)), x0 + w);
    const ey = @min(@as(i32, @intCast(RENDER_H)), y0 + h);
    if (sx >= ex or sy >= ey) return;
    fillRect(@as(usize, @intCast(sx)), @as(usize, @intCast(sy)), @as(usize, @intCast(ex - sx)), @as(usize, @intCast(ey - sy)), c);
}

fn setPixelI32(x: i32, y: i32, c: Color) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    setPixel(@as(usize, @intCast(x)), @as(usize, @intCast(y)), c);
}

fn setPixel(x: usize, y: usize, c: Color) void {
    const idx = (y * RENDER_W + x) * 4;
    output_buf[idx + 0] = c[0];
    output_buf[idx + 1] = c[1];
    output_buf[idx + 2] = c[2];
    output_buf[idx + 3] = c[3];
}
