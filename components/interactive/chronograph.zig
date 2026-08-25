const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");
const font = @import("assets/inter_display_bold_chronograph_digits.zig");

const DRAW_SCALE: i32 = 1;
const RENDER_W: usize = 360;
const RENDER_H: usize = 360;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;
const WAKE_INTERVAL_MS: i64 = 200;

const CX: i32 = @intCast(RENDER_W / 2);
const CY: i32 = @intCast(RENDER_H / 2);
const Color = [4]u8;

const C_BEZEL_DARK: Color = .{ 0x63, 0x70, 0x7A, 0xFF };
const C_BEZEL_LIGHT: Color = .{ 0xEE, 0xF2, 0xF4, 0xFF };
const C_DIAL: Color = .{ 0xD9, 0xDE, 0xE1, 0xFF };
const C_DIAL_EDGE: Color = .{ 0xA8, 0xB2, 0xB9, 0xFF };
const C_INK: Color = .{ 0x08, 0x27, 0x45, 0xFF };
const C_TICK: Color = .{ 0x16, 0x3A, 0x5B, 0xFF };
const C_ACCENT: Color = .{ 0x00, 0x72, 0xAD, 0xFF };
const C_ACCENT_DARK: Color = .{ 0x00, 0x38, 0x68, 0xFF };
const C_SHADOW: Color = .{ 0x0A, 0x1D, 0x2D, 0x4A };

var output_buf: [OUTPUT_BYTES]u8 = undefined;

const Phase = enum { initializing, ready, updating };
var phase: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;
var clock_seconds: f32 = 0;
var committed_seconds: f32 = 0;
var uniform_seconds: f32 = 0;
var uniform_seconds_set: bool = false;
var last_host_seconds: f32 = 0;
var host_seconds_seen: bool = false;

export fn input_ptr() u32 {
    return 0;
}

export fn input_bytes_cap() u32 {
    return 0;
}

export fn output_bytes_cap() u32 {
    return @intCast(OUTPUT_BYTES);
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

export fn uniform_set_current_seconds(value: f32) f32 {
    if (!std.math.isFinite(value)) @trap();
    const normalized = normalizeSeconds(value);
    if (host_seconds_seen and normalized == last_host_seconds) {
        uniform_seconds_set = false;
        return quantizeSeconds(normalized);
    }
    last_host_seconds = normalized;
    host_seconds_seen = true;
    uniform_seconds = normalized;
    uniform_seconds_set = true;
    return quantizeSeconds(normalized);
}

export fn begin_update_at(now_ms: i64) void {
    if (phase != .ready or now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    phase = .updating;
}

export fn finish_update() i64 {
    if (phase != .updating) @trap();
    if (uniform_seconds_set) {
        clock_seconds = uniform_seconds;
    } else {
        const elapsed_ms = begun_at_ms - committed_at_ms;
        clock_seconds = normalizeSeconds(clock_seconds + @as(f32, @floatFromInt(elapsed_ms)) / 1000.0);
    }
    committed_seconds = quantizeSeconds(clock_seconds);
    resetUniform();
    committed_at_ms = begun_at_ms;
    phase = .ready;
    if (begun_at_ms > std.math.maxInt(i64) - WAKE_INTERVAL_MS) return begun_at_ms;
    return begun_at_ms + WAKE_INTERVAL_MS;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0 or phase == .updating) @trap();
    if (phase == .initializing) {
        if (uniform_seconds_set) {
            clock_seconds = uniform_seconds;
            committed_seconds = quantizeSeconds(clock_seconds);
        }
        phase = .ready;
    } else if (phase != .ready) {
        @trap();
    } else if (uniform_seconds_set) {
        clock_seconds = uniform_seconds;
        committed_seconds = quantizeSeconds(clock_seconds);
    }

    _ = ktx.writeHeader(&output_buf, RENDER_W, RENDER_H) orelse @trap();
    drawChronograph(committed_seconds);
    resetUniform();
    return @intCast(OUTPUT_BYTES);
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

fn resetUniform() void {
    uniform_seconds = 0;
    uniform_seconds_set = false;
}

fn normalizeSeconds(value: f32) f32 {
    var normalized = value - @floor(value / 60.0) * 60.0;
    if (normalized < 0) normalized += 60.0;
    return normalized;
}

fn quantizeSeconds(value: f32) f32 {
    return @floor(normalizeSeconds(value) * 5.0) / 5.0;
}

fn pixels() []u8 {
    return output_buf[ktx.HEADER_SIZE..];
}

fn drawChronograph(seconds: f32) void {
    drawStaticDial();
    drawHand(seconds);
}

fn drawStaticDial() void {
    drawBackground();
    drawCaseAndDial();
    drawDialGlow();
    drawChapterRing();
    drawLabels();
}

fn drawCaseAndDial() void {
    // Layered metal, inset shadow, and a warm paper dial.
    fillCircle(CX, CY, scale(164), C_BEZEL_DARK);
    fillCircle(CX, CY, scale(159), C_BEZEL_LIGHT);
    fillCircle(CX, CY, scale(153), C_BEZEL_DARK);
    fillCircle(CX, CY, scale(149), C_DIAL_EDGE);
    fillCircle(CX, CY, scale(144), C_DIAL);
}

fn drawChapterRing() void {
    drawRing(CX, CY, scale(140), scale(1), C_INK);
    drawRing(CX, CY, scale(117), scale(1), .{ 0x08, 0x27, 0x45, 0x98 });

    var tick: u32 = 0;
    while (tick < 300) : (tick += 1) {
        const second_tick = tick % 5 == 0;
        const major = tick % 25 == 0;
        const cardinal = tick % 75 == 0;
        const outer_radius: f32 = scaleF(136);
        const inner_radius: f32 = if (cardinal) scaleF(119) else if (major) scaleF(123) else if (second_tick) scaleF(129) else scaleF(133);
        const angle = @as(f32, @floatFromInt(tick)) * std.math.tau / 300.0;
        const x0 = CX + @as(i32, @intFromFloat(@round(std.math.sin(angle) * inner_radius)));
        const y0 = CY - @as(i32, @intFromFloat(@round(std.math.cos(angle) * inner_radius)));
        const x1 = CX + @as(i32, @intFromFloat(@round(std.math.sin(angle) * outer_radius)));
        const y1 = CY - @as(i32, @intFromFloat(@round(std.math.cos(angle) * outer_radius)));
        drawLine(
            x0,
            y0,
            x1,
            y1,
            if (cardinal) scale(3) else if (major) scale(2) else scale(1),
            if (cardinal) C_INK else if (second_tick) C_TICK else .{ 0x16, 0x3A, 0x5B, 0x8C },
        );
    }
}

fn drawLabels() void {
    drawCenteredText("60", CX, CY - scale(105), C_INK);
    drawCenteredText("15", CX + scale(104), CY, C_INK);
    drawCenteredText("30", CX, CY + scale(105), C_INK);
    drawCenteredText("45", CX - scale(104), CY, C_INK);

    drawRing(CX, CY, scale(92), scale(1), .{ 0x4B, 0x62, 0x75, 0x66 });
    drawRing(CX, CY, scale(6), scale(1), C_ACCENT_DARK);
}

fn drawHand(seconds: f32) void {
    const hand_angle = seconds * std.math.tau / 60.0;
    const hand_x = CX + @as(i32, @intFromFloat(@round(std.math.sin(hand_angle) * scaleF(114))));
    const hand_y = CY - @as(i32, @intFromFloat(@round(std.math.cos(hand_angle) * scaleF(114))));
    const tail_x = CX - @as(i32, @intFromFloat(@round(std.math.sin(hand_angle) * scaleF(27))));
    const tail_y = CY + @as(i32, @intFromFloat(@round(std.math.cos(hand_angle) * scaleF(27))));
    drawLine(tail_x + scale(3), tail_y + scale(4), hand_x + scale(3), hand_y + scale(4), scale(5), C_SHADOW);
    drawLine(tail_x, tail_y, hand_x, hand_y, scale(4), C_ACCENT_DARK);
    drawLine(CX, CY, hand_x, hand_y, scale(2), C_ACCENT);
    fillCircle(CX, CY, scale(8), C_ACCENT_DARK);
    fillCircle(CX, CY, scale(4), .{ 0xB9, 0xD3, 0xE2, 0xFF });
}

fn drawBackground() void {
    @memset(pixels(), 0);
}

fn drawDialGlow() void {
    var y: i32 = CY - scale(143);
    while (y <= CY + scale(143)) : (y += 1) {
        var x: i32 = CX - scale(143);
        while (x <= CX + scale(143)) : (x += 1) {
            const dx = x - CX;
            const dy = y - CY;
            if (dx * dx + dy * dy > scale(143) * scale(143)) continue;
            const light = @max(0, 12 - @divTrunc(@abs(dx + dy), @as(u32, @intCast(scale(18)))));
            if (light > 0) blendPixel(x, y, .{ 0xFF, 0xFF, 0xFF, @intCast(light) });

            // Fine deterministic grain gives the silver dial a blasted finish.
            const grain = @mod(x * 37 + y * 19, 17);
            if (grain == 0) {
                blendPixel(x, y, .{ 0xFF, 0xFF, 0xFF, 0x15 });
            } else if (grain == 1) {
                blendPixel(x, y, .{ 0x3D, 0x52, 0x62, 0x0C });
            }

            // Cut the concentric finish into the same dial pass. Computing one
            // distance per inner-dial pixel is cheaper than scanning the dial
            // again for every ring.
            const distance_squared = dx * dx + dy * dy;
            if (distance_squared >= scale(19) * scale(19) and distance_squared <= scale(93) * scale(93)) {
                const distance = std.math.sqrt(@as(f32, @floatFromInt(distance_squared)));
                const ring_index = @round((distance - scaleF(20)) / scaleF(4));
                const ring_radius = scaleF(20) + ring_index * scaleF(4) - 0.5;
                const coverage = std.math.clamp(1.0 - @abs(distance - ring_radius), 0.0, 1.0);
                blendPixelCoverage(x, y, .{ 0x3D, 0x52, 0x62, 0x12 }, coverage);
            }
        }
    }
}

fn scale(value: i32) i32 {
    return value * DRAW_SCALE;
}

fn scaleF(value: comptime_int) f32 {
    return @floatFromInt(value * DRAW_SCALE);
}

fn drawCenteredText(text: []const u8, center_x: i32, center_y: i32, color: Color) void {
    var width: i32 = 0;
    for (text) |character| width += glyphAdvance(character);
    var x = center_x - @divTrunc(width, 2);
    for (text) |character| {
        drawGlyph(character, x, center_y - @as(i32, @intCast(font.GLYPH_H / 2)), color);
        x += glyphAdvance(character);
    }
}

fn glyphAdvance(character: u8) i32 {
    const index = glyphIndex(character) orelse return 0;
    return font.advances[index];
}

fn glyphIndex(character: u8) ?usize {
    for (font.codepoints, 0..) |codepoint, index| {
        if (codepoint == character) return index;
    }
    return null;
}

fn drawGlyph(character: u8, origin_x: i32, origin_y: i32, color: Color) void {
    const glyph_index = glyphIndex(character) orelse return;
    var y: usize = 0;
    while (y < font.GLYPH_H) : (y += 1) {
        var x: usize = 0;
        while (x < font.GLYPH_W) : (x += 1) {
            const pixel_index = y * font.GLYPH_W + x;
            const byte = font.glyph_alpha4[glyph_index][pixel_index / 2];
            const alpha4 = if (pixel_index % 2 == 0) byte >> 4 else byte & 0x0F;
            if (alpha4 == 0) continue;
            var source = color;
            source[3] = @intCast((@as(u16, color[3]) * alpha4) / 15);
            blendPixel(origin_x + @as(i32, @intCast(x)), origin_y + @as(i32, @intCast(y)), source);
        }
    }
}

fn drawLine(x0_in: i32, y0_in: i32, x1: i32, y1: i32, thickness: i32, color: Color) void {
    const ax: f32 = @floatFromInt(x0_in);
    const ay: f32 = @floatFromInt(y0_in);
    const vx: f32 = @floatFromInt(x1 - x0_in);
    const vy: f32 = @floatFromInt(y1 - y0_in);
    const length_squared = vx * vx + vy * vy;
    const half_width = @as(f32, @floatFromInt(@max(1, thickness))) * 0.5;
    const padding = @as(i32, @intFromFloat(@ceil(half_width))) + 1;

    var y = @min(y0_in, y1) - padding;
    while (y <= @max(y0_in, y1) + padding) : (y += 1) {
        var x = @min(x0_in, x1) - padding;
        while (x <= @max(x0_in, x1) + padding) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const t = if (length_squared == 0)
                0.0
            else
                std.math.clamp(((px - ax) * vx + (py - ay) * vy) / length_squared, 0.0, 1.0);
            const dx = px - (ax + vx * t);
            const dy = py - (ay + vy * t);
            const coverage = std.math.clamp(half_width + 0.5 - std.math.sqrt(dx * dx + dy * dy), 0.0, 1.0);
            blendPixelCoverage(x, y, color, coverage);
        }
    }
}

fn fillCircle(cx: i32, cy: i32, radius: i32, color: Color) void {
    var y = cy - radius - 1;
    while (y <= cy + radius + 1) : (y += 1) {
        var x = cx - radius - 1;
        while (x <= cx + radius + 1) : (x += 1) {
            const coverage = circleCoverage(x, y, cx, cy, radius);
            if (coverage >= 1.0) {
                blendPixel(x, y, color);
                continue;
            }
            blendPixelCoverage(x, y, color, coverage);
        }
    }
}

inline fn circleCoverage(x: i32, y: i32, cx: i32, cy: i32, radius: i32) f32 {
    const radius_f: f32 = @floatFromInt(radius);
    const dx = @as(f32, @floatFromInt(x - cx)) + 0.5;
    const dy = @as(f32, @floatFromInt(y - cy)) + 0.5;
    const distance_squared = dx * dx + dy * dy;
    const opaque_radius = radius_f - 0.5;
    const transparent_radius = radius_f + 0.5;
    if (distance_squared <= opaque_radius * opaque_radius) return 1.0;
    if (distance_squared >= transparent_radius * transparent_radius) return 0.0;
    return transparent_radius - std.math.sqrt(distance_squared);
}

fn drawRing(cx: i32, cy: i32, radius: i32, thickness: i32, color: Color) void {
    const outer: f32 = @floatFromInt(radius);
    const inner: f32 = @floatFromInt(@max(0, radius - thickness));
    const reject_inside_squared = @max(0.0, inner - 0.5) * @max(0.0, inner - 0.5);
    const reject_outside_squared = (outer + 0.5) * (outer + 0.5);
    const full_inside_squared = (inner + 0.5) * (inner + 0.5);
    const full_outside_squared = @max(0.0, outer - 0.5) * @max(0.0, outer - 0.5);
    var y = cy - radius - 1;
    while (y <= cy + radius + 1) : (y += 1) {
        var x = cx - radius - 1;
        while (x <= cx + radius + 1) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x - cx)) + 0.5;
            const dy = @as(f32, @floatFromInt(y - cy)) + 0.5;
            const distance_squared = dx * dx + dy * dy;
            if (distance_squared <= reject_inside_squared or distance_squared >= reject_outside_squared) continue;
            if (distance_squared >= full_inside_squared and distance_squared <= full_outside_squared) {
                blendPixel(x, y, color);
                continue;
            }
            const distance = std.math.sqrt(distance_squared);
            const outer_coverage = outer + 0.5 - distance;
            const inner_coverage = distance - inner + 0.5;
            const coverage = std.math.clamp(@min(outer_coverage, inner_coverage), 0.0, 1.0);
            blendPixelCoverage(x, y, color, coverage);
        }
    }
}

fn blendPixelCoverage(x: i32, y: i32, color: Color, coverage: f32) void {
    if (coverage <= 0.0) return;
    var covered = color;
    covered[3] = @intFromFloat(@round(@as(f32, @floatFromInt(color[3])) * coverage));
    blendPixel(x, y, covered);
}

fn setPixel(x: i32, y: i32, color: Color) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    const index = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    @memcpy(pixels()[index .. index + 4], &color);
}

fn blendPixel(x: i32, y: i32, source: Color) void {
    if (source[3] == 0 or x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    if (source[3] == 255) {
        setPixel(x, y, source);
        return;
    }
    const index = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    const source_alpha: u32 = source[3];
    const destination_alpha: u32 = pixels()[index + 3];
    if (destination_alpha == 0) {
        setPixel(x, y, source);
        return;
    }
    const inverse: u32 = 255 - source_alpha;
    if (destination_alpha == 255) {
        var channel: usize = 0;
        while (channel < 3) : (channel += 1) {
            const mixed = @as(u32, source[channel]) * source_alpha +
                @as(u32, pixels()[index + channel]) * inverse;
            pixels()[index + channel] = @intCast(@divTrunc(mixed + 127, 255));
        }
        return;
    }
    const output_alpha: u32 = source_alpha + @divTrunc(destination_alpha * inverse + 127, 255);
    if (output_alpha == 0) return;
    var channel: usize = 0;
    while (channel < 3) : (channel += 1) {
        const source_term = @as(u32, source[channel]) * source_alpha;
        const destination_term = @divTrunc(@as(u32, pixels()[index + channel]) * destination_alpha * inverse + 127, 255);
        pixels()[index + channel] = @intCast(@divTrunc(source_term + destination_term + output_alpha / 2, output_alpha));
    }
    pixels()[index + 3] = @intCast(output_alpha);
}

test "renders the requested second as canonical KTX2" {
    resetForTest();
    try std.testing.expectApproxEqAbs(@as(f32, 15.2), uniform_set_current_seconds(75.39), 0.001);
    const size = renderImpl(0);
    const image = ktx.parse(output_buf[0..size]).?;
    try std.testing.expectEqual(RENDER_W, image.width);
    try std.testing.expectEqual(RENDER_H, image.height);
    try std.testing.expectEqual(@as(u8, 0), image.pixels[3]);
    const center = (RENDER_H / 2 * RENDER_W + RENDER_W / 2) * 4;
    try std.testing.expectEqual(@as(u8, 255), image.pixels[center + 3]);
    var has_antialiased_silhouette = false;
    var pixel_index: usize = 3;
    while (pixel_index < image.pixels.len) : (pixel_index += 4) {
        const alpha = image.pixels[pixel_index];
        if (alpha > 0 and alpha < 255) {
            has_antialiased_silhouette = true;
            break;
        }
    }
    try std.testing.expect(has_antialiased_silhouette);
}

test "Timed update commits a fifth-second step and schedules 200 ms" {
    resetForTest();
    _ = uniform_set_current_seconds(14.0);
    _ = renderImpl(0);
    begin_update_at(1);
    _ = uniform_set_current_seconds(15.2);
    try std.testing.expectEqual(@as(i64, 201), finish_update());
    try std.testing.expectApproxEqAbs(@as(f32, 15.2), committed_seconds, 0.001);
    try std.testing.expect(!uniform_seconds_set);
}

test "repeated initial clock input does not stop lifecycle time" {
    resetForTest();
    _ = uniform_set_current_seconds(14.0);
    _ = renderImpl(0);
    begin_update_at(201);
    _ = uniform_set_current_seconds(14.0);
    try std.testing.expectEqual(@as(i64, 401), finish_update());
    try std.testing.expectApproxEqAbs(@as(f32, 14.2), committed_seconds, 0.001);
}

fn resetForTest() void {
    phase = .initializing;
    begun_at_ms = 0;
    committed_at_ms = 0;
    clock_seconds = 0.0;
    committed_seconds = 0.0;
    last_host_seconds = 0.0;
    host_seconds_seen = false;
    resetUniform();
}
