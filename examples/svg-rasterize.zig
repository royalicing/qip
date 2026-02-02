const std = @import("std");

const INPUT_CAP: u32 = 1024 * 1024;
const OUTPUT_CAP: u32 = 16 * 1024 * 1024;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&output_buf)));
}

export fn output_bytes_cap() u32 {
    return OUTPUT_CAP;
}

const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

const Mat = struct {
    a: f32,
    b: f32,
    c: f32,
    d: f32,
    tx: f32,
    ty: f32,
};

const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    set_x: bool = false,
    set_y: bool = false,
    set_w: bool = false,
    set_h: bool = false,
};

const Circle = struct {
    cx: f32 = 0,
    cy: f32 = 0,
    r: f32 = 0,
    set_cx: bool = false,
    set_cy: bool = false,
    set_r: bool = false,
};

const MAX_POINTS: usize = 256;

const ParserCtx = struct {
    input: []const u8,
    width: u32,
    height: u32,
    pixel_base: u32,
    out_len: u32,
};

fn matIdentity() Mat {
    return Mat{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = 0, .ty = 0 };
}

fn matMul(a: Mat, b: Mat) Mat {
    return Mat{
        .a = a.a * b.a + a.c * b.b,
        .b = a.b * b.a + a.d * b.b,
        .c = a.a * b.c + a.c * b.d,
        .d = a.b * b.c + a.d * b.d,
        .tx = a.a * b.tx + a.c * b.ty + a.tx,
        .ty = a.b * b.tx + a.d * b.ty + a.ty,
    };
}

fn matApply(m: Mat, x: f32, y: f32) [2]f32 {
    return .{ m.a * x + m.c * y + m.tx, m.b * x + m.d * y + m.ty };
}

fn matInverse(m: Mat) ?Mat {
    const det = m.a * m.d - m.b * m.c;
    if (det == 0) return null;
    const inv_det = 1.0 / det;
    const a = m.d * inv_det;
    const b = -m.b * inv_det;
    const c = -m.c * inv_det;
    const d = m.a * inv_det;
    const tx = -(a * m.tx + c * m.ty);
    const ty = -(b * m.tx + d * m.ty);
    return Mat{ .a = a, .b = b, .c = c, .d = d, .tx = tx, .ty = ty };
}

fn strEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn isNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == ':';
}

fn skipWs(input: []const u8, idx: *usize) void {
    while (idx.* < input.len) {
        const c = input[idx.*];
        if (c == ' ' or c == '\n' or c == '\t' or c == '\r') {
            idx.* += 1;
            continue;
        }
        break;
    }
}

fn readName(input: []const u8, idx: *usize) []const u8 {
    const start = idx.*;
    while (idx.* < input.len and isNameChar(input[idx.*])) {
        idx.* += 1;
    }
    return input[start..idx.*];
}

fn readQuoted(input: []const u8, idx: *usize) []const u8 {
    if (idx.* >= input.len) return input[0..0];
    const quote = input[idx.*];
    if (quote != '"' and quote != '\'') return input[0..0];
    idx.* += 1;
    const start = idx.*;
    while (idx.* < input.len and input[idx.*] != quote) {
        idx.* += 1;
    }
    const slice = input[start..idx.*];
    if (idx.* < input.len and input[idx.*] == quote) {
        idx.* += 1;
    }
    return slice;
}

fn hexVal(c: u8) u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return 0;
}

fn parseColor(value: []const u8) ?Color {
    if (value.len == 4 and value[0] == '#') {
        const r = hexVal(value[1]);
        const g = hexVal(value[2]);
        const b = hexVal(value[3]);
        return Color{ .r = r * 17, .g = g * 17, .b = b * 17, .a = 255 };
    }
    if (value.len >= 7 and value[0] == '#') {
        const r = (hexVal(value[1]) << 4) | hexVal(value[2]);
        const g = (hexVal(value[3]) << 4) | hexVal(value[4]);
        const b = (hexVal(value[5]) << 4) | hexVal(value[6]);
        return Color{ .r = r, .g = g, .b = b, .a = 255 };
    }
    if (strEq(value, "none")) {
        return Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    }
    return null;
}

fn parseFloat(input: []const u8, idx: *usize) ?f32 {
    skipWs(input, idx);
    if (idx.* >= input.len) return null;
    var i = idx.*;
    var sign: f32 = 1.0;
    if (input[i] == '-') {
        sign = -1.0;
        i += 1;
    } else if (input[i] == '+') {
        i += 1;
    }
    var int_part: f32 = 0.0;
    var has_digit = false;
    while (i < input.len and input[i] >= '0' and input[i] <= '9') {
        int_part = int_part * 10.0 + @as(f32, @floatFromInt(input[i] - '0'));
        i += 1;
        has_digit = true;
    }
    var frac_part: f32 = 0.0;
    var div: f32 = 1.0;
    if (i < input.len and input[i] == '.') {
        i += 1;
        while (i < input.len and input[i] >= '0' and input[i] <= '9') {
            frac_part = frac_part * 10.0 + @as(f32, @floatFromInt(input[i] - '0'));
            div *= 10.0;
            i += 1;
            has_digit = true;
        }
    }
    if (!has_digit) return null;
    idx.* = i;
    return sign * (int_part + frac_part / div);
}

fn parseNumber(value: []const u8) ?f32 {
    var i: usize = 0;
    return parseFloat(value, &i);
}

fn parseTransform(value: []const u8) Mat {
    var idx: usize = 0;
    var result = matIdentity();
    while (idx < value.len) {
        skipWs(value, &idx);
        if (idx >= value.len) break;
        const name_start = idx;
        while (idx < value.len and ((value[idx] >= 'a' and value[idx] <= 'z') or (value[idx] >= 'A' and value[idx] <= 'Z'))) {
            idx += 1;
        }
        const name = value[name_start..idx];
        skipWs(value, &idx);
        if (idx >= value.len or value[idx] != '(') break;
        idx += 1;
        var nums: [6]f32 = undefined;
        var count: usize = 0;
        while (idx < value.len and value[idx] != ')') {
            if (count >= nums.len) {
                while (idx < value.len and value[idx] != ')') idx += 1;
                break;
            }
            if (parseFloat(value, &idx)) |v| {
                nums[count] = v;
                count += 1;
            } else {
                idx += 1;
            }
            skipWs(value, &idx);
            if (idx < value.len and value[idx] == ',') idx += 1;
        }
        if (idx < value.len and value[idx] == ')') idx += 1;

        var op = matIdentity();
        if (strEq(name, "translate")) {
            const tx = if (count >= 1) nums[0] else 0.0;
            const ty = if (count >= 2) nums[1] else 0.0;
            op = Mat{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = tx, .ty = ty };
        } else if (strEq(name, "scale")) {
            const sx = if (count >= 1) nums[0] else 1.0;
            const sy = if (count >= 2) nums[1] else sx;
            op = Mat{ .a = sx, .b = 0, .c = 0, .d = sy, .tx = 0, .ty = 0 };
        } else if (strEq(name, "rotate")) {
            const angle = if (count >= 1) nums[0] else 0.0;
            const rad = angle * (std.math.pi / 180.0);
            const c = std.math.cos(rad);
            const s = std.math.sin(rad);
            op = Mat{ .a = c, .b = s, .c = -s, .d = c, .tx = 0, .ty = 0 };
            if (count >= 3) {
                const cx = nums[1];
                const cy = nums[2];
                const t1 = Mat{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = cx, .ty = cy };
                const t2 = Mat{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = -cx, .ty = -cy };
                op = matMul(t1, matMul(op, t2));
            }
        }
        result = matMul(result, op);
    }
    return result;
}

fn setPixel(ctx: *ParserCtx, x: i32, y: i32, color: Color) void {
    if (color.a == 0) return;
    if (x < 0 or y < 0) return;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= ctx.width or uy >= ctx.height) return;
    const row = ctx.height - 1 - uy;
    const idx: u32 = ctx.pixel_base + (row * ctx.width + ux) * 4;
    output_buf[idx] = color.b;
    output_buf[idx + 1] = color.g;
    output_buf[idx + 2] = color.r;
    output_buf[idx + 3] = color.a;
}

fn drawRect(ctx: *ParserCtx, transform: Mat, color: Color, rect: Rect) void {
    if (!(rect.set_w and rect.set_h)) return;
    const inv = matInverse(transform) orelse return;
    const corners = [_][2]f32{
        matApply(transform, rect.x, rect.y),
        matApply(transform, rect.x + rect.w, rect.y),
        matApply(transform, rect.x, rect.y + rect.h),
        matApply(transform, rect.x + rect.w, rect.y + rect.h),
    };
    var min_x = corners[0][0];
    var max_x = corners[0][0];
    var min_y = corners[0][1];
    var max_y = corners[0][1];
    for (corners[1..]) |pt| {
        if (pt[0] < min_x) min_x = pt[0];
        if (pt[0] > max_x) max_x = pt[0];
        if (pt[1] < min_y) min_y = pt[1];
        if (pt[1] > max_y) max_y = pt[1];
    }
    var x0: i32 = @intFromFloat(@floor(min_x));
    var y0: i32 = @intFromFloat(@floor(min_y));
    var x1: i32 = @intFromFloat(@ceil(max_x));
    var y1: i32 = @intFromFloat(@ceil(max_y));
    if (x1 < 0 or y1 < 0) return;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 >= @as(i32, @intCast(ctx.width))) x1 = @as(i32, @intCast(ctx.width)) - 1;
    if (y1 >= @as(i32, @intCast(ctx.height))) y1 = @as(i32, @intCast(ctx.height)) - 1;

    var y: i32 = y0;
    while (y <= y1) : (y += 1) {
        var x: i32 = x0;
        while (x <= x1) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const local = matApply(inv, px, py);
            if (local[0] >= rect.x and local[0] <= rect.x + rect.w and local[1] >= rect.y and local[1] <= rect.y + rect.h) {
                setPixel(ctx, x, y, color);
            }
        }
    }
}

fn drawCircle(ctx: *ParserCtx, transform: Mat, color: Color, circle: Circle) void {
    if (!circle.set_r) return;
    const inv = matInverse(transform) orelse return;
    const center = matApply(transform, circle.cx, circle.cy);
    const rx = circle.r * std.math.sqrt(transform.a * transform.a + transform.c * transform.c);
    const ry = circle.r * std.math.sqrt(transform.b * transform.b + transform.d * transform.d);
    var x0: i32 = @intFromFloat(@floor(center[0] - rx));
    var x1: i32 = @intFromFloat(@ceil(center[0] + rx));
    var y0: i32 = @intFromFloat(@floor(center[1] - ry));
    var y1: i32 = @intFromFloat(@ceil(center[1] + ry));
    if (x1 < 0 or y1 < 0) return;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 >= @as(i32, @intCast(ctx.width))) x1 = @as(i32, @intCast(ctx.width)) - 1;
    if (y1 >= @as(i32, @intCast(ctx.height))) y1 = @as(i32, @intCast(ctx.height)) - 1;
    const r2 = circle.r * circle.r;

    var y: i32 = y0;
    while (y <= y1) : (y += 1) {
        var x: i32 = x0;
        while (x <= x1) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const local = matApply(inv, px, py);
            const dx = local[0] - circle.cx;
            const dy = local[1] - circle.cy;
            if (dx * dx + dy * dy <= r2) {
                setPixel(ctx, x, y, color);
            }
        }
    }
}

fn drawPolygon(ctx: *ParserCtx, transform: Mat, color: Color, xs: *const [MAX_POINTS]f32, ys: *const [MAX_POINTS]f32, count: usize) void {
    if (count < 3) return;
    const inv = matInverse(transform) orelse return;
    var min_x = std.math.inf(f32);
    var min_y = std.math.inf(f32);
    var max_x = -std.math.inf(f32);
    var max_y = -std.math.inf(f32);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const pt = matApply(transform, xs[i], ys[i]);
        if (pt[0] < min_x) min_x = pt[0];
        if (pt[0] > max_x) max_x = pt[0];
        if (pt[1] < min_y) min_y = pt[1];
        if (pt[1] > max_y) max_y = pt[1];
    }
    var x0: i32 = @intFromFloat(@floor(min_x));
    var y0: i32 = @intFromFloat(@floor(min_y));
    var x1: i32 = @intFromFloat(@ceil(max_x));
    var y1: i32 = @intFromFloat(@ceil(max_y));
    if (x1 < 0 or y1 < 0) return;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 >= @as(i32, @intCast(ctx.width))) x1 = @as(i32, @intCast(ctx.width)) - 1;
    if (y1 >= @as(i32, @intCast(ctx.height))) y1 = @as(i32, @intCast(ctx.height)) - 1;

    var y: i32 = y0;
    while (y <= y1) : (y += 1) {
        var x: i32 = x0;
        while (x <= x1) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const local = matApply(inv, px, py);
            var inside = false;
            var j: usize = count - 1;
            var k: usize = 0;
            while (k < count) : (k += 1) {
                const xi = xs[k];
                const yi = ys[k];
                const xj = xs[j];
                const yj = ys[j];
                const intersect = (yi > local[1]) != (yj > local[1]) and
                    (local[0] < (xj - xi) * (local[1] - yi) / (yj - yi + 0.0000001) + xi);
                if (intersect) inside = !inside;
                j = k;
            }
            if (inside) {
                setPixel(ctx, x, y, color);
            }
        }
    }
}

fn parsePoints(value: []const u8, xs: *[MAX_POINTS]f32, ys: *[MAX_POINTS]f32, count: *usize) void {
    var idx: usize = 0;
    var have_x = false;
    var current_x: f32 = 0;
    count.* = 0;
    while (idx < value.len) {
        skipWs(value, &idx);
        if (idx < value.len and value[idx] == ',') {
            idx += 1;
            continue;
        }
        if (parseFloat(value, &idx)) |v| {
            if (!have_x) {
                current_x = v;
                have_x = true;
            } else {
                if (count.* < MAX_POINTS) {
                    xs[count.*] = current_x;
                    ys[count.*] = v;
                    count.* += 1;
                }
                have_x = false;
            }
        } else {
            idx += 1;
        }
    }
}

fn parseAttributes(input: []const u8, idx: *usize, base_fill: Color, base_transform: Mat, rect: *Rect, circle: *Circle, xs: *[MAX_POINTS]f32, ys: *[MAX_POINTS]f32, poly_count: *usize, attr_fill: *Color, fill_set: *bool, attr_transform: *Mat, transform_set: *bool, self_closing: *bool) void {
    while (idx.* < input.len) {
        skipWs(input, idx);
        if (idx.* >= input.len) return;
        if (input[idx.*] == '/') {
            if (idx.* + 1 < input.len and input[idx.* + 1] == '>') {
                idx.* += 2;
                self_closing.* = true;
                return;
            }
        }
        if (input[idx.*] == '>') {
            idx.* += 1;
            return;
        }
        const name = readName(input, idx);
        skipWs(input, idx);
        if (idx.* >= input.len or input[idx.*] != '=') continue;
        idx.* += 1;
        skipWs(input, idx);
        const value = readQuoted(input, idx);
        if (value.len == 0) continue;

        if (strEq(name, "fill")) {
            if (parseColor(value)) |c| {
                attr_fill.* = c;
                fill_set.* = true;
            }
        } else if (strEq(name, "transform")) {
            attr_transform.* = parseTransform(value);
            transform_set.* = true;
        } else if (strEq(name, "x")) {
            if (parseNumber(value)) |v| {
                rect.x = v;
                rect.set_x = true;
            }
        } else if (strEq(name, "y")) {
            if (parseNumber(value)) |v| {
                rect.y = v;
                rect.set_y = true;
            }
        } else if (strEq(name, "width")) {
            if (parseNumber(value)) |v| {
                rect.w = v;
                rect.set_w = true;
            }
        } else if (strEq(name, "height")) {
            if (parseNumber(value)) |v| {
                rect.h = v;
                rect.set_h = true;
            }
        } else if (strEq(name, "cx")) {
            if (parseNumber(value)) |v| {
                circle.cx = v;
                circle.set_cx = true;
            }
        } else if (strEq(name, "cy")) {
            if (parseNumber(value)) |v| {
                circle.cy = v;
                circle.set_cy = true;
            }
        } else if (strEq(name, "r")) {
            if (parseNumber(value)) |v| {
                circle.r = v;
                circle.set_r = true;
            }
        } else if (strEq(name, "points")) {
            parsePoints(value, xs, ys, poly_count);
        }
    }
    _ = base_fill;
    _ = base_transform;
}

fn skipSpecial(input: []const u8, idx: *usize) void {
    if (idx.* >= input.len) return;
    if (input[idx.*] == '?') {
        while (idx.* + 1 < input.len) : (idx.* += 1) {
            if (input[idx.*] == '?' and input[idx.* + 1] == '>') {
                idx.* += 2;
                return;
            }
        }
    } else if (input[idx.*] == '!') {
        if (idx.* + 2 < input.len and input[idx.* + 1] == '-' and input[idx.* + 2] == '-') {
            idx.* += 3;
            while (idx.* + 2 < input.len) : (idx.* += 1) {
                if (input[idx.*] == '-' and input[idx.* + 1] == '-' and input[idx.* + 2] == '>') {
                    idx.* += 3;
                    return;
                }
            }
        } else {
            while (idx.* < input.len and input[idx.*] != '>') idx.* += 1;
            if (idx.* < input.len) idx.* += 1;
        }
    }
}

fn parseElements(ctx: *ParserCtx, idx: *usize, transform: Mat, fill: Color, end_tag: ?[]const u8) void {
    const input = ctx.input;
    while (idx.* < input.len) {
        while (idx.* < input.len and input[idx.*] != '<') idx.* += 1;
        if (idx.* >= input.len) return;
        idx.* += 1;
        if (idx.* >= input.len) return;

        if (input[idx.*] == '/' ) {
            idx.* += 1;
            skipWs(input, idx);
            const name = readName(input, idx);
            while (idx.* < input.len and input[idx.*] != '>') idx.* += 1;
            if (idx.* < input.len) idx.* += 1;
            if (end_tag != null and strEq(name, end_tag.?)) return;
            continue;
        }
        if (input[idx.*] == '?' or input[idx.*] == '!') {
            skipSpecial(input, idx);
            continue;
        }

        const name = readName(input, idx);
        var rect = Rect{};
        var circle = Circle{};
        var xs: [MAX_POINTS]f32 = undefined;
        var ys: [MAX_POINTS]f32 = undefined;
        var poly_count: usize = 0;
        var attr_fill = fill;
        var fill_set = false;
        var attr_transform = matIdentity();
        var transform_set = false;
        var self_closing = false;

        parseAttributes(input, idx, fill, transform, &rect, &circle, &xs, &ys, &poly_count, &attr_fill, &fill_set, &attr_transform, &transform_set, &self_closing);

        const final_transform = if (transform_set) matMul(transform, attr_transform) else transform;
        const final_fill = if (fill_set) attr_fill else fill;

        if (strEq(name, "g") or strEq(name, "svg")) {
            if (!self_closing) {
                parseElements(ctx, idx, final_transform, final_fill, name);
            }
        } else if (strEq(name, "rect")) {
            drawRect(ctx, final_transform, final_fill, rect);
        } else if (strEq(name, "circle")) {
            drawCircle(ctx, final_transform, final_fill, circle);
        } else if (strEq(name, "polygon")) {
            drawPolygon(ctx, final_transform, final_fill, &xs, &ys, poly_count);
        }
    }
}

fn findSvgSize(input: []const u8) ?[2]u32 {
    var idx: usize = 0;
    while (idx + 4 < input.len) : (idx += 1) {
        if (input[idx] == '<' and input[idx + 1] == 's' and input[idx + 2] == 'v' and input[idx + 3] == 'g') {
            idx += 4;
            var width: ?u32 = null;
            var height: ?u32 = null;
            while (idx < input.len) {
                skipWs(input, &idx);
                if (idx >= input.len) break;
                if (input[idx] == '>') {
                    idx += 1;
                    break;
                }
                if (input[idx] == '/' and idx + 1 < input.len and input[idx + 1] == '>') {
                    idx += 2;
                    break;
                }
                const name = readName(input, &idx);
                skipWs(input, &idx);
                if (idx >= input.len or input[idx] != '=') continue;
                idx += 1;
                skipWs(input, &idx);
                const value = readQuoted(input, &idx);
                if (strEq(name, "width")) {
                    if (parseNumber(value)) |v| width = @intFromFloat(v);
                } else if (strEq(name, "height")) {
                    if (parseNumber(value)) |v| height = @intFromFloat(v);
                }
                if (width != null and height != null) return .{ width.?, height.? };
            }
        }
    }
    return null;
}

fn writeU16LE(buf: []u8, off: u32, value: u16) void {
    buf[off] = @intCast(value & 0xFF);
    buf[off + 1] = @intCast((value >> 8) & 0xFF);
}

fn writeU32LE(buf: []u8, off: u32, value: u32) void {
    buf[off] = @intCast(value & 0xFF);
    buf[off + 1] = @intCast((value >> 8) & 0xFF);
    buf[off + 2] = @intCast((value >> 16) & 0xFF);
    buf[off + 3] = @intCast((value >> 24) & 0xFF);
}

export fn run(input_size: u32) u32 {
    const size = if (input_size > INPUT_CAP) INPUT_CAP else input_size;
    const input = input_buf[0..size];

    const dims = findSvgSize(input) orelse return 0;
    const width = dims[0];
    const height = dims[1];
    if (width == 0 or height == 0) return 0;

    const pixel_bytes: u64 = @as(u64, width) * @as(u64, height) * 4;
    const header_size: u32 = 54;
    const needed: u64 = @as(u64, header_size) + pixel_bytes;
    if (needed > OUTPUT_CAP) return 0;

    var i: usize = 0;
    while (i < needed) : (i += 1) {
        output_buf[i] = 0;
    }

    // BMP header (BITMAPFILEHEADER + BITMAPINFOHEADER).
    output_buf[0] = 'B';
    output_buf[1] = 'M';
    writeU32LE(output_buf[0..], 2, @intCast(needed));
    writeU32LE(output_buf[0..], 6, 0);
    writeU32LE(output_buf[0..], 10, header_size);
    writeU32LE(output_buf[0..], 14, 40);
    writeU32LE(output_buf[0..], 18, width);
    writeU32LE(output_buf[0..], 22, height);
    writeU16LE(output_buf[0..], 26, 1);
    writeU16LE(output_buf[0..], 28, 32);
    writeU32LE(output_buf[0..], 30, 0);
    writeU32LE(output_buf[0..], 34, @intCast(pixel_bytes));
    writeU32LE(output_buf[0..], 38, 2835);
    writeU32LE(output_buf[0..], 42, 2835);
    writeU32LE(output_buf[0..], 46, 0);
    writeU32LE(output_buf[0..], 50, 0);

    var ctx = ParserCtx{
        .input = input,
        .width = width,
        .height = height,
        .pixel_base = header_size,
        .out_len = @intCast(needed),
    };
    var idx: usize = 0;
    const default_fill = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    parseElements(&ctx, &idx, matIdentity(), default_fill, null);

    return ctx.out_len;
}
