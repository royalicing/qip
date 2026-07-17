const std = @import("std");

const GRID_W: usize = 20;
const GRID_H: usize = 14;
const TILE_PX: usize = 20;
const MAX_CELLS: usize = GRID_W * GRID_H;

const RENDER_W: usize = GRID_W * TILE_PX;
const RENDER_H: usize = GRID_H * TILE_PX;
const OUTPUT_BYTES: usize = RENDER_W * RENDER_H * 4;

const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;
const FLAG_KEY_DOWN: i32 = 1 << 0;

const STEP_MS: i64 = 120;

const Color = [4]u8;
const COLOR_BG: Color = .{ 0x0A, 0x11, 0x17, 0xFF };
const COLOR_GRID: Color = .{ 0x10, 0x1B, 0x24, 0xFF };
const COLOR_SNAKE: Color = .{ 0x56, 0xD3, 0x64, 0xFF };
const COLOR_HEAD: Color = .{ 0x95, 0xF0, 0x3E, 0xFF };
const COLOR_APPLE: Color = .{ 0xE9, 0x3A, 0x49, 0xFF };
const COLOR_OVERLAY: Color = .{ 0x09, 0x0B, 0x0E, 0xB8 };
const COLOR_GAMEOVER: Color = .{ 0xE9, 0x3A, 0x49, 0xFF };
const COLOR_PAUSED: Color = .{ 0xF2, 0xD2, 0x52, 0xFF };

var output_buf: [OUTPUT_BYTES]u8 = undefined;
var snake_x: [MAX_CELLS]i32 = undefined;
var snake_y: [MAX_CELLS]i32 = undefined;
var snake_len: usize = 0;

var dir_x: i32 = 1;
var dir_y: i32 = 0;
var next_dir_x: i32 = 1;
var next_dir_y: i32 = 0;

var apple_x: i32 = 0;
var apple_y: i32 = 0;

var rng_state: u32 = 0xA3575D17;
var has_last_step: bool = false;
var last_step_ms: i64 = 0;

var initialized: bool = false;
var paused: bool = false;
var game_over: bool = false;
var needs_redraw: bool = true;

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

export fn key_event(x11_key: i32, flags: i32, _: i64) i32 {
    const is_down = (flags & FLAG_KEY_DOWN) != 0;
    if (!is_down) return 0;

    if (!initialized) resetGame();

    switch (x11_key) {
        XK_LEFT => trySetDirection(-1, 0),
        XK_RIGHT => trySetDirection(1, 0),
        XK_UP => trySetDirection(0, -1),
        XK_DOWN => trySetDirection(0, 1),
        0x72, 0x52 => resetGame(), // r / R
        0x20 => { // space toggles pause/restart
            if (game_over) {
                resetGame();
            } else {
                paused = !paused;
                needs_redraw = true;
            }
        },
        else => return 0,
    }
    return 1;
}

export fn pointer_event(_: i32, _: i32, _: i32, _: i64) i32 {
    return 0;
}

export fn tick(now_ms: i64) i64 {
    if (!initialized) resetGame();
    if (paused or game_over) {
        return 0;
    }

    if (!has_last_step) {
        has_last_step = true;
        last_step_ms = now_ms;
    }

    var elapsed = now_ms - last_step_ms;
    if (elapsed < 0) elapsed = 0;
    while (elapsed >= STEP_MS and !game_over and !paused) {
        stepSnake();
        last_step_ms += STEP_MS;
        elapsed -= STEP_MS;
    }

    return last_step_ms + STEP_MS;
}

export fn render(input_size: i32) i32 {
    _ = input_size;
    drawFrame();
    needs_redraw = false;
    return @as(i32, @intCast(OUTPUT_BYTES));
}

fn resetGame() void {
    initialized = true;
    paused = false;
    game_over = false;
    has_last_step = false;
    last_step_ms = 0;

    snake_len = 4;
    var i: usize = 0;
    while (i < snake_len) : (i += 1) {
        snake_x[i] = @as(i32, @intCast(6 - i));
        snake_y[i] = 6;
    }

    dir_x = 1;
    dir_y = 0;
    next_dir_x = 1;
    next_dir_y = 0;

    rng_state +%= 0x9E3779B9;
    placeApple();
    needs_redraw = true;
}

fn trySetDirection(dx: i32, dy: i32) void {
    if (game_over) return;
    if (dx == -dir_x and dy == -dir_y) return;
    next_dir_x = dx;
    next_dir_y = dy;
}

fn stepSnake() void {
    dir_x = next_dir_x;
    dir_y = next_dir_y;

    const hx = snake_x[0];
    const hy = snake_y[0];
    const nx = hx + dir_x;
    const ny = hy + dir_y;

    if (nx < 0 or ny < 0 or nx >= @as(i32, @intCast(GRID_W)) or ny >= @as(i32, @intCast(GRID_H))) {
        game_over = true;
        needs_redraw = true;
        return;
    }

    var collide = false;
    var i: usize = 0;
    while (i < snake_len) : (i += 1) {
        if (snake_x[i] == nx and snake_y[i] == ny) {
            collide = true;
            break;
        }
    }
    if (collide) {
        game_over = true;
        needs_redraw = true;
        return;
    }

    var grow = false;
    if (nx == apple_x and ny == apple_y) {
        grow = true;
    }

    if (grow and snake_len < MAX_CELLS) {
        var j = snake_len;
        while (j > 0) : (j -= 1) {
            snake_x[j] = snake_x[j - 1];
            snake_y[j] = snake_y[j - 1];
        }
        snake_len += 1;
    } else {
        var j = snake_len - 1;
        while (j > 0) : (j -= 1) {
            snake_x[j] = snake_x[j - 1];
            snake_y[j] = snake_y[j - 1];
        }
    }
    snake_x[0] = nx;
    snake_y[0] = ny;

    if (grow) {
        if (snake_len >= MAX_CELLS) {
            game_over = true;
        } else {
            placeApple();
        }
    }
    needs_redraw = true;
}

fn placeApple() void {
    while (true) {
        const x = @as(i32, @intCast(rngNext() % GRID_W));
        const y = @as(i32, @intCast(rngNext() % GRID_H));

        var blocked = false;
        var i: usize = 0;
        while (i < snake_len) : (i += 1) {
            if (snake_x[i] == x and snake_y[i] == y) {
                blocked = true;
                break;
            }
        }
        if (!blocked) {
            apple_x = x;
            apple_y = y;
            return;
        }
    }
}

fn rngNext() u32 {
    var x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

fn drawFrame() void {
    fillRect(0, 0, RENDER_W, RENDER_H, COLOR_BG);
    drawGrid();
    drawApple();
    drawSnake();
    if (game_over) {
        drawOverlay(COLOR_GAMEOVER);
    } else if (paused) {
        drawOverlay(COLOR_PAUSED);
    }
}

fn drawGrid() void {
    var y: usize = 0;
    while (y < GRID_H) : (y += 1) {
        var x: usize = 0;
        while (x < GRID_W) : (x += 1) {
            if (((x + y) & 1) == 0) {
                fillRect(x * TILE_PX, y * TILE_PX, TILE_PX, TILE_PX, COLOR_GRID);
            }
        }
    }
}

fn drawSnake() void {
    var i: usize = 0;
    while (i < snake_len) : (i += 1) {
        const x: usize = @intCast(snake_x[i]);
        const y: usize = @intCast(snake_y[i]);
        const px = x * TILE_PX;
        const py = y * TILE_PX;
        const inset: usize = 2;
        fillRect(px + inset, py + inset, TILE_PX - inset * 2, TILE_PX - inset * 2, if (i == 0) COLOR_HEAD else COLOR_SNAKE);
    }
}

fn drawApple() void {
    const x: usize = @intCast(apple_x);
    const y: usize = @intCast(apple_y);
    const px = x * TILE_PX;
    const py = y * TILE_PX;
    fillRect(px + 4, py + 4, TILE_PX - 8, TILE_PX - 8, COLOR_APPLE);
}

fn drawOverlay(color: Color) void {
    fillRect(0, 0, RENDER_W, RENDER_H, COLOR_OVERLAY);
    const w: usize = 140;
    const h: usize = 70;
    const x = (RENDER_W - w) / 2;
    const y = (RENDER_H - h) / 2;
    fillRect(x, y, w, h, .{ 0xF4, 0xF8, 0xFC, 0xFF });
    fillRect(x, y, w, 6, color);
    fillRect(x, y + h - 6, w, 6, color);
}

fn fillRect(x0: usize, y0: usize, w: usize, h: usize, color: Color) void {
    var y = y0;
    while (y < y0 + h) : (y += 1) {
        var x = x0;
        while (x < x0 + w) : (x += 1) {
            const idx = (y * RENDER_W + x) * 4;
            output_buf[idx + 0] = color[0];
            output_buf[idx + 1] = color[1];
            output_buf[idx + 2] = color[2];
            output_buf[idx + 3] = color[3];
        }
    }
}
