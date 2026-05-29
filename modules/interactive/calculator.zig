const std = @import("std");

const RENDER_W: usize = 220;
const RENDER_H: usize = 220;
const OUTPUT_BYTES: usize = RENDER_W * RENDER_H * 4;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const BTN_PRIMARY: i32 = 1 << 0;
const XK_RETURN: i32 = 0xFF0D;
const XK_BACKSPACE: i32 = 0xFF08;

const Color = [4]u8;
const C_BG: Color = .{ 0x2D, 0x32, 0x3D, 0xFF };
const C_FACE: Color = .{ 0xE8, 0xEA, 0xEF, 0xFF };
const C_DISPLAY: Color = .{ 0xC9, 0xD8, 0xBC, 0xFF };
const C_TEXT: Color = .{ 0x1A, 0x25, 0x1A, 0xFF };
const C_KEY: Color = .{ 0xF7, 0xF7, 0xF4, 0xFF };
const C_OP: Color = .{ 0xF0, 0xB3, 0x66, 0xFF };
const C_CLEAR: Color = .{ 0xD9, 0x6B, 0x65, 0xFF };
const C_DARK: Color = .{ 0x1D, 0x1D, 0x20, 0xFF };

const Op = enum(u8) { none, add, sub, mul, div };

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var current: i32 = 0;
var stored: i32 = 0;
var op: Op = .none;
var entering: bool = false;
var has_error: bool = false;
var primary_down: bool = false;
var needs_redraw: bool = true;

const labels = [_]u8{
    'C', '<', '/', '*',
    '7', '8', '9', '-',
    '4', '5', '6', '+',
    '1', '2', '3', '=',
    '0', '0', '.', '=',
};

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

export fn key_event(x11_key: i32, flags: i32, _: i32) i32 {
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;
    if (x11_key >= '0' and x11_key <= '9') {
        pressDigit(@as(u8, @intCast(x11_key - '0')));
    } else switch (x11_key) {
        '+', '-', '*', '/', 'x' => pressOp(keyToOp(x11_key)),
        '=', XK_RETURN => pressEquals(),
        'c', 'C' => resetCalc(),
        XK_BACKSPACE, '<' => backspace(),
        else => return 0,
    }
    needs_redraw = true;
    return 1;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32, _: i32) i32 {
    const down = (button_mask & BTN_PRIMARY) != 0;
    if (down and !primary_down) {
        if (buttonIndexAt(x_px, y_px)) |idx| pressButton(idx);
        primary_down = down;
        needs_redraw = true;
        return 1;
    }
    primary_down = down;
    return 0;
}

export fn tick(_: i32) i32 {
    return if (needs_redraw) 1 else 0;
}

export fn render_output() i32 {
    drawFrame();
    needs_redraw = false;
    return @as(i32, @intCast(OUTPUT_BYTES));
}

fn pressButton(idx: usize) void {
    const label = labels[idx];
    if (label >= '0' and label <= '9') return pressDigit(label - '0');
    switch (label) {
        'C' => resetCalc(),
        '<' => backspace(),
        '+', '-', '*', '/' => pressOp(keyToOp(label)),
        '=' => pressEquals(),
        else => {},
    }
}

fn pressDigit(digit: u8) void {
    if (has_error) resetCalc();
    if (!entering) {
        current = 0;
        entering = true;
    }
    if (current <= 99999999) current = current * 10 + digit;
}

fn pressOp(next: Op) void {
    if (op != .none and entering) applyOp();
    stored = current;
    op = next;
    entering = false;
}

fn pressEquals() void {
    if (op == .none) return;
    applyOp();
    op = .none;
    entering = false;
}

fn applyOp() void {
    current = switch (op) {
        .none => current,
        .add => stored + current,
        .sub => stored - current,
        .mul => stored * current,
        .div => blk: {
            if (current == 0) {
                has_error = true;
                break :blk 0;
            }
            break :blk @divTrunc(stored, current);
        },
    };
}

fn resetCalc() void {
    current = 0;
    stored = 0;
    op = .none;
    entering = false;
    has_error = false;
}

fn backspace() void {
    if (has_error) return resetCalc();
    current = @divTrunc(current, 10);
}

fn keyToOp(k: i32) Op {
    return switch (k) {
        '+' => .add,
        '-' => .sub,
        '*' => .mul,
        '/' => .div,
        'x' => .mul,
        else => .none,
    };
}

fn buttonIndexAt(x: i32, y: i32) ?usize {
    const bx0: i32 = 18;
    const by0: i32 = 72;
    const bw: i32 = 42;
    const bh: i32 = 26;
    const gap: i32 = 6;
    if (x < bx0 or y < by0) return null;
    const col = @divFloor(x - bx0, bw + gap);
    const row = @divFloor(y - by0, bh + gap);
    if (col < 0 or col >= 4 or row < 0 or row >= 5) return null;
    const lx = x - bx0 - col * (bw + gap);
    const ly = y - by0 - row * (bh + gap);
    if (lx >= bw or ly >= bh) return null;
    return @as(usize, @intCast(row * 4 + col));
}

fn drawFrame() void {
    fillRect(0, 0, RENDER_W, RENDER_H, C_BG);
    fillRectI32(10, 10, 200, 200, C_FACE);
    drawBorder(10, 10, 200, 200);
    fillRectI32(18, 24, 184, 34, C_DISPLAY);
    drawBorder(18, 24, 184, 34);
    if (has_error) {
        drawText(156, 38, "ERR", C_TEXT);
    } else {
        drawNumberRight(194, 38, current, C_TEXT);
    }
    drawButtons();
}

fn drawButtons() void {
    var i: usize = 0;
    while (i < labels.len) : (i += 1) {
        const row = @as(i32, @intCast(i / 4));
        const col = @as(i32, @intCast(i % 4));
        const x = 18 + col * 48;
        const y = 72 + row * 32;
        const label = labels[i];
        const color = if (label == 'C') C_CLEAR else if (label == '+' or label == '-' or label == '*' or label == '/' or label == '=') C_OP else C_KEY;
        fillRectI32(x, y, 42, 26, color);
        drawBorder(x, y, 42, 26);
        drawChar(x + 18, y + 10, label, C_DARK);
    }
}

fn drawNumberRight(x_right: i32, y: i32, n: i32, c: Color) void {
    var digits: [12]u8 = undefined;
    var count: usize = 0;
    var value = if (n < 0) -n else n;
    if (value == 0) {
        digits[0] = 0;
        count = 1;
    } else {
        while (value > 0 and count < digits.len) : (count += 1) {
            digits[count] = @as(u8, @intCast(@mod(value, 10)));
            value = @divTrunc(value, 10);
        }
    }
    var x = x_right - @as(i32, @intCast(count * 8));
    if (n < 0) {
        drawChar(x - 8, y, '-', c);
    }
    var i: usize = 0;
    while (i < count) : (i += 1) {
        drawDigit(x, y, digits[count - 1 - i], c);
        x += 8;
    }
}

fn drawText(x: i32, y: i32, text: []const u8, c: Color) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) drawChar(x + @as(i32, @intCast(i * 8)), y, text[i], c);
}

fn drawChar(x: i32, y: i32, ch: u8, c: Color) void {
    if (ch >= '0' and ch <= '9') return drawDigit(x, y, ch - '0', c);
    const rows = switch (ch) {
        '+' => [_]u8{ 0b000, 0b010, 0b111, 0b010, 0b000 },
        '-' => [_]u8{ 0b000, 0b000, 0b111, 0b000, 0b000 },
        '*' => [_]u8{ 0b101, 0b010, 0b111, 0b010, 0b101 },
        '/' => [_]u8{ 0b001, 0b001, 0b010, 0b100, 0b100 },
        '=' => [_]u8{ 0b000, 0b111, 0b000, 0b111, 0b000 },
        '<' => [_]u8{ 0b001, 0b010, 0b100, 0b010, 0b001 },
        'E' => [_]u8{ 0b111, 0b100, 0b110, 0b100, 0b111 },
        'R' => [_]u8{ 0b110, 0b101, 0b110, 0b101, 0b101 },
        else => [_]u8{ 0, 0, 0, 0, 0 },
    };
    drawRows(x, y, rows, c);
}

fn drawDigit(x: i32, y: i32, digit: u8, c: Color) void {
    const rows = switch (digit) {
        0 => [_]u8{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        1 => [_]u8{ 0b010, 0b110, 0b010, 0b010, 0b111 },
        2 => [_]u8{ 0b111, 0b001, 0b111, 0b100, 0b111 },
        3 => [_]u8{ 0b111, 0b001, 0b111, 0b001, 0b111 },
        4 => [_]u8{ 0b101, 0b101, 0b111, 0b001, 0b001 },
        5 => [_]u8{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        6 => [_]u8{ 0b111, 0b100, 0b111, 0b101, 0b111 },
        7 => [_]u8{ 0b111, 0b001, 0b001, 0b001, 0b001 },
        8 => [_]u8{ 0b111, 0b101, 0b111, 0b101, 0b111 },
        9 => [_]u8{ 0b111, 0b101, 0b111, 0b001, 0b111 },
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

fn drawBorder(x: i32, y: i32, w: i32, h: i32) void {
    fillRectI32(x, y, w, 1, C_DARK);
    fillRectI32(x, y, 1, h, C_DARK);
    fillRectI32(x, y + h - 1, w, 1, C_DARK);
    fillRectI32(x + w - 1, y, 1, h, C_DARK);
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

fn setPixel(x: usize, y: usize, c: Color) void {
    const idx = (y * RENDER_W + x) * 4;
    output_buf[idx + 0] = c[0];
    output_buf[idx + 1] = c[1];
    output_buf[idx + 2] = c[2];
    output_buf[idx + 3] = c[3];
}

test "addition" {
    resetCalc();
    pressDigit(2);
    pressOp(.add);
    pressDigit(3);
    pressEquals();
    try std.testing.expect(current == 5);
}
