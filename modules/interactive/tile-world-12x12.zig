const std = @import("std");

const WORLD_W: usize = 12;
const WORLD_H: usize = 12;
const TILE_PX: usize = 24;

const RENDER_W: usize = WORLD_W * TILE_PX;
const RENDER_H: usize = WORLD_H * TILE_PX;
const OUTPUT_BYTES: usize = RENDER_W * RENDER_H * 4;

const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;

const FLAG_KEY_DOWN: i32 = 1 << 0;

const BTN_PRIMARY: i32 = 1 << 0;

const MOVE_INTERVAL_MS: i32 = 120;

const KEY_UP: u8 = 1 << 0;
const KEY_DOWN: u8 = 1 << 1;
const KEY_LEFT: u8 = 1 << 2;
const KEY_RIGHT: u8 = 1 << 3;

const WORLD_ROWS = [_][]const u8{
    "............",
    "..###.......",
    "......##....",
    ".#..........",
    ".#..####....",
    ".#..........",
    ".#....###...",
    ".#..........",
    ".####.......",
    ".....#......",
    "..#..#..##..",
    "............",
};

comptime {
    if (WORLD_ROWS.len != WORLD_H) @compileError("WORLD_ROWS height mismatch");
    for (WORLD_ROWS) |row| {
        if (row.len != WORLD_W) @compileError("WORLD_ROWS width mismatch");
    }
}

var output_buf: [OUTPUT_BYTES]u8 = undefined;

var player_tx: i32 = 1;
var player_ty: i32 = 1;
var keys_down: u8 = 0;
var last_move_ms: i32 = 0;
var has_last_move: bool = false;
var needs_redraw: bool = true;

const Color = [4]u8;
const COLOR_GROUND: Color = .{ 0xA7, 0xD6, 0x8D, 0xFF };
const COLOR_TREE: Color = .{ 0x2F, 0x6D, 0x3A, 0xFF };
const COLOR_TREE_TRUNK: Color = .{ 0x7A, 0x4F, 0x22, 0xFF };
const COLOR_PLAYER: Color = .{ 0x2A, 0x6D, 0xF5, 0xFF };
const COLOR_PLAYER_EDGE: Color = .{ 0x11, 0x2E, 0x7A, 0xFF };

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
    const is_down = (flags & FLAG_KEY_DOWN) != 0;

    const key_bit: u8 = switch (x11_key) {
        XK_UP => KEY_UP,
        XK_DOWN => KEY_DOWN,
        XK_LEFT => KEY_LEFT,
        XK_RIGHT => KEY_RIGHT,
        else => return 0,
    };

    if (is_down) {
        keys_down |= key_bit;
    } else {
        keys_down &= ~key_bit;
    }

    return 1;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32, _: i32) i32 {
    if ((button_mask & BTN_PRIMARY) == 0) return 0;

    const tx = @divFloor(x_px, @as(i32, @intCast(TILE_PX)));
    const ty = @divFloor(y_px, @as(i32, @intCast(TILE_PX)));
    if (!inBoundsTile(tx, ty) or isTree(tx, ty)) return 0;

    if (player_tx != tx or player_ty != ty) {
        player_tx = tx;
        player_ty = ty;
        needs_redraw = true;
    }
    return 1;
}

export fn tick(now_ms: i32) i32 {
    if (!has_last_move) {
        has_last_move = true;
        last_move_ms = now_ms;
    }

    if (keys_down != 0) {
        var elapsed = now_ms - last_move_ms;
        if (elapsed < 0) elapsed = 0;
        while (elapsed >= MOVE_INTERVAL_MS) {
            _ = moveOneStep();
            last_move_ms += MOVE_INTERVAL_MS;
            elapsed -= MOVE_INTERVAL_MS;
        }
    } else {
        last_move_ms = now_ms;
    }

    // Keep ticking while any movement key is held so host-side loops can stay
    // event-driven at idle, but continuous during active input.
    return if (needs_redraw or keys_down != 0) 1 else 0;
}

export fn render_output() i32 {
    drawWorld();
    needs_redraw = false;
    return @as(i32, @intCast(OUTPUT_BYTES));
}

fn moveOneStep() bool {
    const up = (keys_down & KEY_UP) != 0;
    const down = (keys_down & KEY_DOWN) != 0;
    const left = (keys_down & KEY_LEFT) != 0;
    const right = (keys_down & KEY_RIGHT) != 0;

    if (up and !down) return tryMove(0, -1);
    if (down and !up) return tryMove(0, 1);
    if (left and !right) return tryMove(-1, 0);
    if (right and !left) return tryMove(1, 0);
    return false;
}

fn tryMove(dx: i32, dy: i32) bool {
    const nx = player_tx + dx;
    const ny = player_ty + dy;
    if (!inBoundsTile(nx, ny)) return false;
    if (isTree(nx, ny)) return false;

    if (nx != player_tx or ny != player_ty) {
        player_tx = nx;
        player_ty = ny;
        needs_redraw = true;
        return true;
    }
    return false;
}

fn inBoundsTile(tx: i32, ty: i32) bool {
    return tx >= 0 and ty >= 0 and tx < @as(i32, @intCast(WORLD_W)) and ty < @as(i32, @intCast(WORLD_H));
}

fn isTree(tx: i32, ty: i32) bool {
    if (!inBoundsTile(tx, ty)) return true;
    const ux: usize = @intCast(tx);
    const uy: usize = @intCast(ty);
    return WORLD_ROWS[uy][ux] == '#';
}

fn setPixel(x: usize, y: usize, color: Color) void {
    const idx = (y * RENDER_W + x) * 4;
    output_buf[idx + 0] = color[0];
    output_buf[idx + 1] = color[1];
    output_buf[idx + 2] = color[2];
    output_buf[idx + 3] = color[3];
}

fn fillRect(x0: usize, y0: usize, w: usize, h: usize, color: Color) void {
    var y: usize = y0;
    while (y < y0 + h) : (y += 1) {
        var x: usize = x0;
        while (x < x0 + w) : (x += 1) {
            setPixel(x, y, color);
        }
    }
}

fn drawTreeTile(tx: usize, ty: usize) void {
    const x0 = tx * TILE_PX;
    const y0 = ty * TILE_PX;

    fillRect(x0, y0, TILE_PX, TILE_PX, COLOR_TREE);

    const trunk_w = TILE_PX / 4;
    const trunk_h = TILE_PX / 3;
    const trunk_x = x0 + (TILE_PX - trunk_w) / 2;
    const trunk_y = y0 + TILE_PX - trunk_h;
    fillRect(trunk_x, trunk_y, trunk_w, trunk_h, COLOR_TREE_TRUNK);
}

fn drawPlayerTile(tx: usize, ty: usize) void {
    const x0 = tx * TILE_PX;
    const y0 = ty * TILE_PX;

    const pad = TILE_PX / 6;
    const px = x0 + pad;
    const py = y0 + pad;
    const size = TILE_PX - pad * 2;

    fillRect(px, py, size, size, COLOR_PLAYER);

    // Simple edge to make the player stand out from the map.
    fillRect(px, py, size, 2, COLOR_PLAYER_EDGE);
    fillRect(px, py + size - 2, size, 2, COLOR_PLAYER_EDGE);
    fillRect(px, py, 2, size, COLOR_PLAYER_EDGE);
    fillRect(px + size - 2, py, 2, size, COLOR_PLAYER_EDGE);
}

fn drawWorld() void {
    fillRect(0, 0, RENDER_W, RENDER_H, COLOR_GROUND);

    var ty: usize = 0;
    while (ty < WORLD_H) : (ty += 1) {
        var tx: usize = 0;
        while (tx < WORLD_W) : (tx += 1) {
            if (WORLD_ROWS[ty][tx] == '#') {
                drawTreeTile(tx, ty);
            }
        }
    }

    drawPlayerTile(@intCast(player_tx), @intCast(player_ty));
}

test "player cannot move into a tree" {
    player_tx = 1;
    player_ty = 1;
    keys_down = KEY_RIGHT;
    needs_redraw = false;

    // Tile (2,1) is a tree in WORLD_ROWS.
    const moved = moveOneStep();
    try std.testing.expect(!moved);
    try std.testing.expect(player_tx == 1 and player_ty == 1);
}

test "player moves on open tile" {
    player_tx = 1;
    player_ty = 1;
    keys_down = KEY_DOWN;
    needs_redraw = false;

    // Tile (1,2) is open.
    const moved = moveOneStep();
    try std.testing.expect(moved);
    try std.testing.expect(player_tx == 1 and player_ty == 2);
}
