const std = @import("std");

const RENDER_W: usize = 480;
const RENDER_H: usize = 320;
const OUTPUT_BYTES: usize = RENDER_W * RENDER_H * 4;

const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const BTN_PRIMARY: i32 = 1 << 0;

var output_buf: [OUTPUT_BYTES]u8 = undefined;

var center_x: f64 = -0.5;
var center_y: f64 = 0.0;
var span_x: f64 = 3.0;
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

    const span_y = span_x * @as(f64, @floatFromInt(RENDER_H)) / @as(f64, @floatFromInt(RENDER_W));
    const pan_step_x = span_x * 0.12;
    const pan_step_y = span_y * 0.12;

    switch (x11_key) {
        XK_LEFT => center_x -= pan_step_x,
        XK_RIGHT => center_x += pan_step_x,
        XK_UP => center_y -= pan_step_y,
        XK_DOWN => center_y += pan_step_y,
        // '=' and '+' zoom in.
        '=' => span_x *= 0.80,
        '+' => span_x *= 0.80,
        // '-' zooms out.
        '-' => span_x *= 1.25,
        else => return 0,
    }

    if (span_x < 0.0000003) span_x = 0.0000003;
    if (span_x > 6.0) span_x = 6.0;
    needs_redraw = true;
    return 1;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32, _: i64) i32 {
    if ((button_mask & BTN_PRIMARY) == 0) return 0;
    if (x_px < 0 or y_px < 0) return 0;
    if (x_px >= @as(i32, @intCast(RENDER_W)) or y_px >= @as(i32, @intCast(RENDER_H))) return 0;

    const fx = @as(f64, @floatFromInt(x_px)) / @as(f64, @floatFromInt(RENDER_W));
    const fy = @as(f64, @floatFromInt(y_px)) / @as(f64, @floatFromInt(RENDER_H));

    const span_y = span_x * @as(f64, @floatFromInt(RENDER_H)) / @as(f64, @floatFromInt(RENDER_W));
    center_x = (center_x - span_x * 0.5) + fx * span_x;
    center_y = (center_y - span_y * 0.5) + fy * span_y;
    needs_redraw = true;
    return 1;
}

export fn tick(_: i64) i64 {
    return 0;
}

export fn render(input_size: i32) i32 {
    _ = input_size;
    renderMandelbrot();
    needs_redraw = false;
    return @as(i32, @intCast(OUTPUT_BYTES));
}

fn renderMandelbrot() void {
    const span_y = span_x * @as(f64, @floatFromInt(RENDER_H)) / @as(f64, @floatFromInt(RENDER_W));
    const x0 = center_x - span_x * 0.5;
    const y0 = center_y - span_y * 0.5;

    const max_iter: i32 = 96;

    var py: usize = 0;
    while (py < RENDER_H) : (py += 1) {
        const cy = y0 + (@as(f64, @floatFromInt(py)) / @as(f64, @floatFromInt(RENDER_H))) * span_y;
        var px: usize = 0;
        while (px < RENDER_W) : (px += 1) {
            const cx = x0 + (@as(f64, @floatFromInt(px)) / @as(f64, @floatFromInt(RENDER_W))) * span_x;

            var zx: f64 = 0.0;
            var zy: f64 = 0.0;
            var iter: i32 = 0;
            while (iter < max_iter) : (iter += 1) {
                const zx2 = zx * zx;
                const zy2 = zy * zy;
                if (zx2 + zy2 > 4.0) break;
                zy = 2.0 * zx * zy + cy;
                zx = zx2 - zy2 + cx;
            }

            const idx = (py * RENDER_W + px) * 4;
            if (iter >= max_iter) {
                output_buf[idx + 0] = 5;
                output_buf[idx + 1] = 6;
                output_buf[idx + 2] = 12;
                output_buf[idx + 3] = 255;
            } else {
                const c = @as(u8, @intCast(@divFloor(iter * 255, max_iter)));
                output_buf[idx + 0] = 20 + @as(u8, @intCast((@as(u16, c) * 2) / 3));
                output_buf[idx + 1] = @as(u8, @intCast((@as(u16, c) * 7) / 10));
                output_buf[idx + 2] = 120 + @as(u8, @intCast((@as(u16, c) * 5) / 10));
                output_buf[idx + 3] = 255;
            }
        }
    }
}
