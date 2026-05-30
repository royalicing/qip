const std = @import("std");

const GRID_N: usize = 3;
const CELL_PX: usize = 96;
const BOARD_PX: usize = GRID_N * CELL_PX;

const PAD_X: usize = 16;
const PAD_Y: usize = 16;
const BOARD_X: usize = PAD_X;
const BOARD_Y: usize = PAD_Y;

const RENDER_W: usize = BOARD_PX + PAD_X * 2;
const RENDER_H: usize = BOARD_Y + BOARD_PX + PAD_Y;
const OUTPUT_BYTES: usize = RENDER_W * RENDER_H * 4;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const BTN_PRIMARY: i32 = 1 << 0;

const XK_RETURN: i32 = 0xFF0D;

const PLAYER_NONE: u8 = 0;
const PLAYER_SUN: u8 = 1;
const PLAYER_MOON: u8 = 2;
const RESULT_DRAW: u8 = 3;

const WIN_LINES = [_][3]usize{
    .{ 0, 1, 2 },
    .{ 3, 4, 5 },
    .{ 6, 7, 8 },
    .{ 0, 3, 6 },
    .{ 1, 4, 7 },
    .{ 2, 5, 8 },
    .{ 0, 4, 8 },
    .{ 2, 4, 6 },
};

const Color = [4]u8;
const COLOR_BG: Color = .{ 0xF3, 0xF8, 0xFC, 0xFF };
const COLOR_GRID: Color = .{ 0x1C, 0x2F, 0x46, 0xFF };
const COLOR_CELL: Color = .{ 0xFA, 0xFD, 0xFF, 0xFF };
const COLOR_SUN_CORE: Color = .{ 0xFF, 0xBE, 0x0B, 0xFF };
const COLOR_SUN_RAY: Color = .{ 0xF2, 0x8C, 0x00, 0xFF };
const COLOR_MOON: Color = .{ 0x7E, 0x88, 0xA8, 0xFF };
const COLOR_MOON_CUTOUT: Color = COLOR_CELL;
const COLOR_WIN_SUN: Color = .{ 0xD9, 0x9D, 0x00, 0xFF };
const COLOR_WIN_MOON: Color = .{ 0x66, 0x71, 0x93, 0xFF };
const COLOR_WIN_DRAW: Color = .{ 0x55, 0x6B, 0x84, 0xFF };
const COLOR_OVERLAY: Color = .{ 0x22, 0x2D, 0x3A, 0xD0 };
const COLOR_PANEL: Color = .{ 0xFB, 0xFD, 0xFF, 0xFF };

var output_buf: [OUTPUT_BYTES]u8 = undefined;

var board: [9]u8 = [_]u8{0} ** 9;
var current_player: u8 = PLAYER_SUN;
var winner: u8 = PLAYER_NONE; // 0 none, 1 sun, 2 moon, 3 draw
var win_line_index: i32 = -1;
var needs_redraw: bool = true;
var primary_down: bool = false;

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

export fn key_event(x11_key: i32, flags: i32, _: i64) i32 {
    const is_down = (flags & FLAG_KEY_DOWN) != 0;
    if (!is_down) return 0;

    // Enter, space, r, and R reset the board.
    if (x11_key == XK_RETURN or x11_key == 0x20 or x11_key == 0x72 or x11_key == 0x52) {
        resetGame();
        return 1;
    }
    return 0;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32, _: i64) i32 {
    const is_down = (button_mask & BTN_PRIMARY) != 0;

    var changed = false;
    if (is_down and !primary_down) {
        changed = handlePrimaryPress(x_px, y_px);
    }
    primary_down = is_down;

    return if (changed) 1 else 0;
}

export fn tick(_: i64) i64 {
    return 0;
}

export fn render_output() i32 {
    drawFrame();
    needs_redraw = false;
    return @as(i32, @intCast(OUTPUT_BYTES));
}

fn resetGame() void {
    board = [_]u8{0} ** 9;
    current_player = PLAYER_SUN;
    winner = PLAYER_NONE;
    win_line_index = -1;
    primary_down = false;
    needs_redraw = true;
}

fn handlePrimaryPress(x_px: i32, y_px: i32) bool {
    if (winner != PLAYER_NONE) {
        resetGame();
        return true;
    }

    const maybe_idx = cellIndexAtPoint(x_px, y_px);
    if (maybe_idx == null) return false;
    const idx = maybe_idx.?;
    if (board[idx] != PLAYER_NONE) return false;

    board[idx] = current_player;
    winner = computeWinner();
    if (winner == PLAYER_NONE) {
        if (boardIsFull()) {
            winner = RESULT_DRAW;
        } else {
            current_player = if (current_player == PLAYER_SUN) PLAYER_MOON else PLAYER_SUN;
        }
    }

    needs_redraw = true;
    return true;
}

fn computeWinner() u8 {
    for (WIN_LINES, 0..) |line, idx| {
        const a = board[line[0]];
        if (a == PLAYER_NONE) continue;
        if (board[line[1]] == a and board[line[2]] == a) {
            win_line_index = @intCast(idx);
            return a;
        }
    }
    win_line_index = -1;
    return PLAYER_NONE;
}

fn boardIsFull() bool {
    for (board) |cell| {
        if (cell == PLAYER_NONE) return false;
    }
    return true;
}

fn cellIndexAtPoint(x_px: i32, y_px: i32) ?usize {
    const bx: i32 = @intCast(BOARD_X);
    const by: i32 = @intCast(BOARD_Y);
    const board_px_i32: i32 = @intCast(BOARD_PX);
    if (x_px < bx or y_px < by) return null;
    if (x_px >= bx + board_px_i32 or y_px >= by + board_px_i32) return null;

    const lx = x_px - bx;
    const ly = y_px - by;
    const cell_px_i32: i32 = @intCast(CELL_PX);
    const tx_i32 = @divFloor(lx, cell_px_i32);
    const ty_i32 = @divFloor(ly, cell_px_i32);

    const tx: usize = @intCast(tx_i32);
    const ty: usize = @intCast(ty_i32);
    return ty * GRID_N + tx;
}

fn drawFrame() void {
    fillRect(0, 0, RENDER_W, RENDER_H, COLOR_BG);
    drawBoardBase();
    drawPieces();
    if (winner != PLAYER_NONE) {
        drawWinScreen();
    }
}

fn drawBoardBase() void {
    fillRect(BOARD_X, BOARD_Y, BOARD_PX, BOARD_PX, COLOR_GRID);

    var gy: usize = 0;
    while (gy < GRID_N) : (gy += 1) {
        var gx: usize = 0;
        while (gx < GRID_N) : (gx += 1) {
            const x0 = BOARD_X + gx * CELL_PX + 4;
            const y0 = BOARD_Y + gy * CELL_PX + 4;
            const w = CELL_PX - 8;
            const h = CELL_PX - 8;
            fillRect(x0, y0, w, h, COLOR_CELL);
        }
    }
}

fn drawPieces() void {
    var idx: usize = 0;
    while (idx < board.len) : (idx += 1) {
        const piece = board[idx];
        if (piece == PLAYER_NONE) continue;

        const tx = idx % GRID_N;
        const ty = idx / GRID_N;
        const cx: i32 = @intCast(BOARD_X + tx * CELL_PX + CELL_PX / 2);
        const cy: i32 = @intCast(BOARD_Y + ty * CELL_PX + CELL_PX / 2);
        const radius: i32 = 26;

        if (piece == PLAYER_SUN) {
            drawSunSymbol(cx, cy, radius);
        } else {
            drawMoonSymbol(cx, cy, radius);
        }
    }
}

fn drawSunSymbol(cx: i32, cy: i32, radius: i32) void {
    const ring = radius + 8;
    const raw_ray_r = @divFloor(radius, 7);
    const ray_r = if (raw_ray_r < 2) 2 else raw_ray_r;
    const ray_dirs = [_][2]i32{
        .{ 1000, 0 },   .{ 924, 383 },  .{ 707, 707 },  .{ 383, 924 },
        .{ 0, 1000 },   .{ -383, 924 }, .{ -707, 707 }, .{ -924, 383 },
        .{ -1000, 0 },  .{ -924, -383 }, .{ -707, -707 }, .{ -383, -924 },
        .{ 0, -1000 },  .{ 383, -924 }, .{ 707, -707 }, .{ 924, -383 },
    };

    for (ray_dirs) |dir| {
        const rx = cx + @divFloor(ring * dir[0], 1000);
        const ry = cy + @divFloor(ring * dir[1], 1000);
        drawFilledCircle(rx, ry, ray_r, COLOR_SUN_RAY);
    }

    drawFilledCircle(cx, cy, radius, COLOR_SUN_CORE);
    drawFilledCircle(cx, cy, radius - 8, COLOR_CELL);
    drawFilledCircle(cx, cy, radius - 13, COLOR_SUN_CORE);
}

fn drawMoonSymbol(cx: i32, cy: i32, radius: i32) void {
    drawFilledCircle(cx, cy, radius, COLOR_MOON);
    drawFilledCircle(cx + @divFloor(radius, 3), cy - @divFloor(radius, 6), radius - 6, COLOR_MOON_CUTOUT);
}

fn drawWinScreen() void {
    fillRect(0, 0, RENDER_W, RENDER_H, COLOR_OVERLAY);

    const panel_w: usize = 208;
    const panel_h: usize = 168;
    const panel_x: usize = (RENDER_W - panel_w) / 2;
    const panel_y: usize = (RENDER_H - panel_h) / 2;
    fillRect(panel_x, panel_y, panel_w, panel_h, COLOR_PANEL);

    const border_color = switch (winner) {
        PLAYER_SUN => COLOR_WIN_SUN,
        PLAYER_MOON => COLOR_WIN_MOON,
        else => COLOR_WIN_DRAW,
    };
    fillRect(panel_x, panel_y, panel_w, 6, border_color);
    fillRect(panel_x, panel_y + panel_h - 6, panel_w, 6, border_color);
    fillRect(panel_x, panel_y, 6, panel_h, border_color);
    fillRect(panel_x + panel_w - 6, panel_y, 6, panel_h, border_color);

    const cx: i32 = @intCast(panel_x + panel_w / 2);
    const cy: i32 = @intCast(panel_y + panel_h / 2 - 8);
    if (winner == PLAYER_SUN) {
        drawSunSymbol(cx, cy, 34);
    } else if (winner == PLAYER_MOON) {
        drawMoonSymbol(cx, cy, 34);
    } else {
        drawSunSymbol(cx - 26, cy, 16);
        drawMoonSymbol(cx + 26, cy, 16);
    }

    // Simple reset hint as two dots near the bottom edge of the panel.
    drawFilledCircle(cx - 10, @intCast(panel_y + panel_h - 24), 4, border_color);
    drawFilledCircle(cx + 10, @intCast(panel_y + panel_h - 24), 4, border_color);
}

fn drawFilledCircle(cx: i32, cy: i32, radius: i32, color: Color) void {
    const r2 = radius * radius;
    var dy: i32 = -radius;
    while (dy <= radius) : (dy += 1) {
        var dx: i32 = -radius;
        while (dx <= radius) : (dx += 1) {
            if (dx * dx + dy * dy <= r2) {
                setPixelI32(cx + dx, cy + dy, color);
            }
        }
    }
}

fn fillRect(x0: usize, y0: usize, w: usize, h: usize, color: Color) void {
    var y = y0;
    while (y < y0 + h) : (y += 1) {
        var x = x0;
        while (x < x0 + w) : (x += 1) {
            setPixel(x, y, color);
        }
    }
}

fn fillRectI32(x0: i32, y0: i32, w: i32, h: i32, color: Color) void {
    var y = y0;
    while (y < y0 + h) : (y += 1) {
        var x = x0;
        while (x < x0 + w) : (x += 1) {
            setPixelI32(x, y, color);
        }
    }
}

fn setPixelI32(x: i32, y: i32, color: Color) void {
    if (x < 0 or y < 0) return;
    const ux: usize = @intCast(x);
    const uy: usize = @intCast(y);
    if (ux >= RENDER_W or uy >= RENDER_H) return;
    setPixel(ux, uy, color);
}

fn setPixel(x: usize, y: usize, color: Color) void {
    const idx = (y * RENDER_W + x) * 4;
    output_buf[idx + 0] = color[0];
    output_buf[idx + 1] = color[1];
    output_buf[idx + 2] = color[2];
    output_buf[idx + 3] = color[3];
}

test "winner detection works for row win" {
    board = [_]u8{ PLAYER_SUN, PLAYER_SUN, PLAYER_SUN, 0, 0, 0, 0, 0, 0 };
    try std.testing.expect(computeWinner() == PLAYER_SUN);
}

test "cellIndexAtPoint maps center of top-left cell" {
    const x: i32 = @intCast(BOARD_X + CELL_PX / 2);
    const y: i32 = @intCast(BOARD_Y + CELL_PX / 2);
    try std.testing.expect(cellIndexAtPoint(x, y).? == 0);
}
