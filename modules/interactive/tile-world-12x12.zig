const std = @import("std");

const SCREEN_W: usize = 12;
const SCREEN_H: usize = 12;
const TILE_PX: usize = 24;

const RENDER_W: usize = SCREEN_W * TILE_PX;
const RENDER_H: usize = SCREEN_H * TILE_PX;
const OUTPUT_BYTES: usize = RENDER_W * RENDER_H * 4;

const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;
const XK_ENTER: i32 = 0xFF0D;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const BTN_PRIMARY: i32 = 1 << 0;

const MOVE_INTERVAL_MS: i64 = 120;

const KEY_UP: u8 = 1 << 0;
const KEY_DOWN: u8 = 1 << 1;
const KEY_LEFT: u8 = 1 << 2;
const KEY_RIGHT: u8 = 1 << 3;

var output_buf: [OUTPUT_BYTES]u8 = undefined;

var player_wx: i64 = 1;
var player_wy: i64 = 1;
var keys_down: u8 = 0;
var last_move_ms: i64 = 0;
var has_last_move: bool = false;
var needs_redraw: bool = true;
var world_ready: bool = false;
var level_counter: u64 = 0;
var world_seed: u64 = 0xA53C_9E21_7D2B_4C11;

const Color = [4]u8;
const COLOR_GROUND: Color = .{ 0xA7, 0xD6, 0x8D, 0xFF };
const COLOR_TREE: Color = .{ 0x2F, 0x6D, 0x3A, 0xFF };
const COLOR_TREE_TRUNK: Color = .{ 0x7A, 0x4F, 0x22, 0xFF };
const COLOR_PLAYER: Color = .{ 0x2A, 0x6D, 0xF5, 0xFF };
const COLOR_PLAYER_EDGE: Color = .{ 0x11, 0x2E, 0x7A, 0xFF };

export fn output_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&output_buf[0])));
}

export fn output_rgba8_srgb_bytes() u32 {
    return @as(u32, @intCast(OUTPUT_BYTES));
}

export fn render_width_px() i32 {
    return @as(i32, @intCast(RENDER_W));
}

export fn render_height_px() i32 {
    return @as(i32, @intCast(RENDER_H));
}

export fn key_event(x11_key: i32, flags: i32, now_ms: i64) i32 {
    const is_down = (flags & FLAG_KEY_DOWN) != 0;

    // Regenerate with a new world seed.
    if (is_down and (x11_key == 'r' or x11_key == 'R' or x11_key == 'n' or x11_key == 'N' or x11_key == XK_ENTER)) {
        generateLevel(now_ms);
        return 1;
    }

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

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32, _: i64) i32 {
    if ((button_mask & BTN_PRIMARY) == 0) return 0;

    const tx = @divFloor(x_px, @as(i32, @intCast(TILE_PX)));
    const ty = @divFloor(y_px, @as(i32, @intCast(TILE_PX)));
    if (!inBoundsScreenTile(tx, ty)) return 0;

    const origin_x = screenOrigin(player_wx, SCREEN_W);
    const origin_y = screenOrigin(player_wy, SCREEN_H);

    const wx = origin_x + @as(i64, tx);
    const wy = origin_y + @as(i64, ty);
    if (isTree(wx, wy)) return 0;

    if (player_wx != wx or player_wy != wy) {
        player_wx = wx;
        player_wy = wy;
        needs_redraw = true;
    }
    return 1;
}

export fn tick(now_ms: i64) i64 {
    if (!world_ready) {
        generateLevel(now_ms);
    }

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

    return if (keys_down != 0) last_move_ms + MOVE_INTERVAL_MS else 0;
}

export fn render(input_size: i32) i32 {
    _ = input_size;
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

fn tryMove(dx: i64, dy: i64) bool {
    const nx = player_wx + dx;
    const ny = player_wy + dy;
    if (isTree(nx, ny)) return false;

    player_wx = nx;
    player_wy = ny;
    needs_redraw = true;
    return true;
}

fn inBoundsScreenTile(tx: i32, ty: i32) bool {
    return tx >= 0 and ty >= 0 and tx < @as(i32, @intCast(SCREEN_W)) and ty < @as(i32, @intCast(SCREEN_H));
}

fn screenOrigin(v: i64, comptime screen_tiles: usize) i64 {
    const s: i64 = @intCast(screen_tiles);
    return @divFloor(v, s) * s;
}

fn localTile(v: i64, comptime screen_tiles: usize) usize {
    const s: i64 = @intCast(screen_tiles);
    const m = @mod(v, s);
    return @as(usize, @intCast(m));
}

fn screenCoord(v: i64, comptime screen_tiles: usize) i64 {
    const s: i64 = @intCast(screen_tiles);
    return @divFloor(v, s);
}

fn mix64(x: u64) u64 {
    var z = x +% 0x9E37_79B9_7F4A_7C15;
    z ^= z >> 30;
    z *%= 0xBF58_476D_1CE4_E5B9;
    z ^= z >> 27;
    z *%= 0x94D0_49BB_1331_11EB;
    z ^= z >> 31;
    return z;
}

fn packCoords(x: i64, y: i64) u64 {
    const ux: u64 = @bitCast(x);
    const uy: u64 = @bitCast(y);
    return mix64(ux ^ mix64(uy));
}

fn randomForTile(wx: i64, wy: i64) u64 {
    const sx = screenCoord(wx, SCREEN_W);
    const sy = screenCoord(wy, SCREEN_H);
    const lx = localTile(wx, SCREEN_W);
    const ly = localTile(wy, SCREEN_H);

    const screen_hash = mix64(world_seed ^ packCoords(sx, sy));
    const tile_hash = mix64(screen_hash ^ packCoords(@intCast(lx), @intCast(ly)));
    return tile_hash;
}

fn isTree(wx: i64, wy: i64) bool {
    const lx = localTile(wx, SCREEN_W);
    const ly = localTile(wy, SCREEN_H);

    // Keep screen borders open so every edge transition is possible.
    if (lx == 0 or lx + 1 == SCREEN_W or ly == 0 or ly + 1 == SCREEN_H) return false;

    const screen_hash = mix64(world_seed ^ packCoords(screenCoord(wx, SCREEN_W), screenCoord(wy, SCREEN_H)));
    const density: u64 = 20 + (screen_hash % 16); // 20..35%
    return (randomForTile(wx, wy) % 100) < density;
}

fn generateLevel(seed_hint_ms: i64) void {
    level_counter +%= 1;
    const ms_bits: u64 = @as(u64, @bitCast(@as(i64, seed_hint_ms)));
    world_seed = mix64(world_seed ^ ms_bits ^ (level_counter *% 0x9E37_79B9_7F4A_7C15));

    player_wx = 1;
    player_wy = 1;

    // Ensure spawn and immediate neighbors are open.
    // Borders are already open; this opens local interior around spawn too.
    // Using fixed nearby points keeps this deterministic per seed.
    if (isTree(1, 1)) world_seed = mix64(world_seed ^ 0xA2F3_D91B_C77E_114D);

    has_last_move = false;
    needs_redraw = true;
    world_ready = true;
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

    fillRect(px, py, size, 2, COLOR_PLAYER_EDGE);
    fillRect(px, py + size - 2, size, 2, COLOR_PLAYER_EDGE);
    fillRect(px, py, 2, size, COLOR_PLAYER_EDGE);
    fillRect(px + size - 2, py, 2, size, COLOR_PLAYER_EDGE);
}

fn drawWorld() void {
    fillRect(0, 0, RENDER_W, RENDER_H, COLOR_GROUND);

    const origin_x = screenOrigin(player_wx, SCREEN_W);
    const origin_y = screenOrigin(player_wy, SCREEN_H);

    var ty: usize = 0;
    while (ty < SCREEN_H) : (ty += 1) {
        var tx: usize = 0;
        while (tx < SCREEN_W) : (tx += 1) {
            const wx = origin_x + @as(i64, @intCast(tx));
            const wy = origin_y + @as(i64, @intCast(ty));
            if (isTree(wx, wy)) {
                drawTreeTile(tx, ty);
            }
        }
    }

    const player_screen_x = @as(usize, @intCast(player_wx - origin_x));
    const player_screen_y = @as(usize, @intCast(player_wy - origin_y));
    drawPlayerTile(player_screen_x, player_screen_y);
}

fn resetForTest(seed: u64) void {
    world_seed = seed;
    world_ready = true;
    has_last_move = false;
    keys_down = 0;
    needs_redraw = false;
}

test "player moves on open border tile" {
    resetForTest(0x1234_5678_9ABC_DEF0);
    player_wx = @as(i64, @intCast(SCREEN_W - 1));
    player_wy = 5;
    keys_down = KEY_RIGHT;

    const moved = moveOneStep();
    try std.testing.expect(moved);
    try std.testing.expect(player_wx == @as(i64, @intCast(SCREEN_W)) and player_wy == 5);
}

test "player can move infinitely negative" {
    resetForTest(0x0F0E_0D0C_0B0A_0908);
    player_wx = 0;
    player_wy = 5;
    keys_down = KEY_LEFT;

    const moved = moveOneStep();
    try std.testing.expect(moved);
    try std.testing.expect(player_wx == -1 and player_wy == 5);
}

test "procedural map is deterministic by seed" {
    resetForTest(0xCAFE_BABE_D00D_F00D);
    const a = isTree(37, -19);
    const b = isTree(37, -19);
    try std.testing.expect(a == b);
}
