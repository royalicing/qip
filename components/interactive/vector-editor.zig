const std = @import("std");
const ktx = @import("ktx2_rgba8_srgb");

const RENDER_W: usize = 960;
const RENDER_H: usize = 640;
const PIXEL_BYTES: usize = RENDER_W * RENDER_H * 4;
const OUTPUT_BYTES: usize = ktx.HEADER_SIZE + PIXEL_BYTES;
const OUTPUT_CONTENT_TYPE = ktx.CONTENT_TYPE;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const BTN_PRIMARY: i32 = 1 << 0;

const XK_RETURN: i32 = 0xFF0D;
const XK_BACKSPACE: i32 = 0xFF08;
const XK_DELETE: i32 = 0xFFFF;
const XK_ESCAPE: i32 = 0xFF1B;

const CANVAS_X: i32 = 64;
const CANVAS_Y: i32 = 18;
const CANVAS_W: i32 = @as(i32, @intCast(RENDER_W)) - CANVAS_X - 14;
const CANVAS_H: i32 = @as(i32, @intCast(RENDER_H)) - CANVAS_Y - 14;

const TOOL_X: i32 = 8;
const TOOL_Y: i32 = 22;
const TOOL_W: i32 = 48;
const TOOL_H: i32 = 20;
const TOOL_GAP: i32 = 8;

const NODE_VIS_R: i32 = 3;
const NODE_HIT_R: i32 = 5;
const HANDLE_VIS_R: i32 = 2;
const EDGE_HIT_PX: f64 = 6.0;

const MAX_SHAPES: usize = 64;
const MAX_POINTS: usize = 24;
const MAX_PATH_POINTS: usize = 1024;
const MAX_FILL_XS: usize = 2048;

const Color = [4]u8;
const C_BG: Color = .{ 0xD2, 0xD6, 0xDD, 0xFF };
const C_PANEL: Color = .{ 0xEA, 0xEE, 0xF4, 0xFF };
const C_PANEL_DARK: Color = .{ 0x89, 0x94, 0xA5, 0xFF };
const C_PANEL_LIGHT: Color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
const C_CANVAS: Color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
const C_GRID: Color = .{ 0xF3, 0xF4, 0xF8, 0xFF };
const C_TEXT: Color = .{ 0x1E, 0x2A, 0x3A, 0xFF };
const C_LINE: Color = .{ 0x2F, 0x63, 0xC8, 0xFF };
const C_LINE_ALT: Color = .{ 0xB8, 0x48, 0x59, 0xFF };
const C_SELECTED: Color = .{ 0xF2, 0x8C, 0x32, 0xFF };
const C_HANDLE: Color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
const C_HANDLE_BORDER: Color = .{ 0x1E, 0x2A, 0x3A, 0xFF };
const C_PREVIEW: Color = .{ 0x3A, 0x9A, 0x6A, 0xFF };
const C_BTN_ACTIVE: Color = .{ 0xB7, 0xD1, 0xFF, 0xFF };
const C_SELECTED_CORE: Color = .{ 0x1E, 0x2A, 0x3A, 0xFF };

const Tool = enum(u8) {
    select,
    line,
    polygon,
    bezier,
};

const Interaction = enum(u8) {
    idle,
    drawing_line,
    drawing_polygon,
    drawing_bezier,
    dragging_node,
};

const ShapeType = enum(u8) {
    line,
    polygon,
    bezier,
};

const NodeKind = enum(u8) {
    anchor,
    handle_in,
    handle_out,
};

const Point = struct {
    x: i32,
    y: i32,
};

const Shape = struct {
    typ: ShapeType = .line,
    color: u8 = 0,
    filled: bool = false,
    point_count: u8 = 0,
    points: [MAX_POINTS]Point = [_]Point{.{ .x = 0, .y = 0 }} ** MAX_POINTS,
    handle_in: [MAX_POINTS]Point = [_]Point{.{ .x = 0, .y = 0 }} ** MAX_POINTS,
    handle_out: [MAX_POINTS]Point = [_]Point{.{ .x = 0, .y = 0 }} ** MAX_POINTS,
};

const Hit = struct {
    shape: i32 = -1,
    node: i32 = -1,
    kind: NodeKind = .anchor,
};

var output_buf: [PIXEL_BYTES]u8 = undefined;
var ktx_buf: [OUTPUT_BYTES]u8 = undefined;
var path_buf: [MAX_PATH_POINTS]Point = [_]Point{.{ .x = 0, .y = 0 }} ** MAX_PATH_POINTS;
var fill_xs: [MAX_FILL_XS]i32 = [_]i32{0} ** MAX_FILL_XS;

var shapes: [MAX_SHAPES]Shape = [_]Shape{.{}} ** MAX_SHAPES;
var shape_count: usize = 0;

var tool: Tool = .select;
var interaction: Interaction = .idle;
var selected_shape: i32 = -1;
var selected_node: i32 = -1;
var selected_kind: NodeKind = .anchor;

var primary_down: bool = false;
var pointer_x: i32 = 0;
var pointer_y: i32 = 0;

var draft_line_a: Point = .{ .x = 0, .y = 0 };
var draft_line_b: Point = .{ .x = 0, .y = 0 };

var draft_poly: [MAX_POINTS]Point = [_]Point{.{ .x = 0, .y = 0 }} ** MAX_POINTS;
var draft_poly_count: usize = 0;
var draft_poly_hover: Point = .{ .x = 0, .y = 0 };
var draft_bez: [MAX_POINTS]Point = [_]Point{.{ .x = 0, .y = 0 }} ** MAX_POINTS;
var draft_bez_in: [MAX_POINTS]Point = [_]Point{.{ .x = 0, .y = 0 }} ** MAX_POINTS;
var draft_bez_out: [MAX_POINTS]Point = [_]Point{.{ .x = 0, .y = 0 }} ** MAX_POINTS;
var draft_bez_count: usize = 0;
var draft_bez_hover: Point = .{ .x = 0, .y = 0 };
var draft_bez_drag_idx: i32 = -1;

var dragging_shape_idx: i32 = -1;
var dragging_node_idx: i32 = -1;

var needs_redraw: bool = true;
var initialized: bool = false;

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_BYTES));
}

export fn input_ptr() u32 {
    return 0;
}

export fn input_bytes_cap() u32 {
    return 0;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

const Phase = enum { initializing, ready, updating };
var lifecycle_state: Phase = .initializing;
var begun_at_ms: i64 = 0;
var committed_at_ms: i64 = 0;

export fn begin_update_at(now_ms: i64) void {
    if (lifecycle_state != .ready or now_ms <= 0 or now_ms <= committed_at_ms) @trap();
    begun_at_ms = now_ms;
    lifecycle_state = .updating;
}

export fn key_event(x11_key: i32, flags: i32) i32 {
    requireUpdate();
    ensureInit();
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;

    switch (x11_key) {
        '1', 's', 'S', 'v', 'V' => setTool(.select),
        '2', 'l', 'L' => setTool(.line),
        '3', 'p', 'P' => setTool(.polygon),
        '4', 'b', 'B' => setTool(.bezier),
        'f', 'F', XK_RETURN => {
            if (!finalizePolygonDraft()) _ = finalizeBezierDraft();
        },
        'g', 'G' => _ = toggleFillSelected(),
        'c', 'C' => clearAllShapes(),
        'n', 'N', XK_BACKSPACE => deleteSelectionNodeOrShape(),
        'd', 'D', XK_DELETE => _ = deleteSelectedShape(),
        XK_ESCAPE => cancelDraft(),
        else => return 0,
    }
    needs_redraw = true;
    return 1;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32) i32 {
    requireUpdate();
    ensureInit();
    pointer_x = x_px;
    pointer_y = y_px;
    const primary = (button_mask & BTN_PRIMARY) != 0;

    var changed = false;
    if (primary and !primary_down) {
        changed = handlePress(x_px, y_px) or changed;
    } else if (primary and primary_down) {
        changed = handleDrag(x_px, y_px) or changed;
    } else if (!primary and primary_down) {
        changed = handleRelease(x_px, y_px) or changed;
    } else if (interaction == .drawing_polygon) {
        if (canvasPoint(x_px, y_px)) |p| {
            if (p.x != draft_poly_hover.x or p.y != draft_poly_hover.y) {
                draft_poly_hover = p;
                changed = true;
            }
        }
    } else if (interaction == .drawing_bezier) {
        if (canvasPoint(x_px, y_px)) |p| {
            if (p.x != draft_bez_hover.x or p.y != draft_bez_hover.y) {
                draft_bez_hover = p;
                changed = true;
            }
        }
    }

    primary_down = primary;
    if (changed) needs_redraw = true;
    return if (changed) 1 else 0;
}

fn requireUpdate() void {
    if (lifecycle_state != .updating) @trap();
}

export fn finish_update() i64 {
    requireUpdate();
    committed_at_ms = begun_at_ms;
    lifecycle_state = .ready;
    return begun_at_ms;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size != 0 or (lifecycle_state != .initializing and lifecycle_state != .ready)) @trap();
    ensureInit();
    drawFrame();
    needs_redraw = false;
    _ = ktx.writeHeader(&ktx_buf, RENDER_W, RENDER_H) orelse @trap();
    @memcpy(ktx_buf[ktx.HEADER_SIZE..], output_buf[0..]);
    lifecycle_state = .ready;
    return @intCast(OUTPUT_BYTES);
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size),
        .output_ptr = @intCast(@intFromPtr(&ktx_buf[0])),
        .failed = 0,
    };
}

fn ensureInit() void {
    if (initialized) return;
    initialized = true;
    loadDemo();
}

fn loadDemo() void {
    shape_count = 0;
    _ = addLineShape(.{ .x = 20, .y = 24 }, .{ .x = 102, .y = 62 }, 0);

    var p: [5]Point = .{
        .{ .x = 138, .y = 28 },
        .{ .x = 208, .y = 44 },
        .{ .x = 222, .y = 92 },
        .{ .x = 164, .y = 120 },
        .{ .x = 128, .y = 78 },
    };
    if (addPolygonShape(p[0..], 1)) |idx| {
        const si = @as(usize, @intCast(idx));
        shapes[si].filled = true;
    }
}

fn setTool(next: Tool) void {
    if (tool == next) return;
    tool = next;
    if (interaction == .drawing_line or interaction == .drawing_polygon or interaction == .drawing_bezier) {
        cancelDraft();
    } else {
        interaction = .idle;
    }
}

fn clearAllShapes() void {
    shape_count = 0;
    selected_shape = -1;
    selected_node = -1;
    selected_kind = .anchor;
    cancelDraft();
}

fn cancelDraft() void {
    interaction = .idle;
    draft_poly_count = 0;
    draft_bez_count = 0;
    draft_bez_drag_idx = -1;
    dragging_shape_idx = -1;
    dragging_node_idx = -1;
}

fn deleteSelectionNodeOrShape() void {
    if (!deleteSelectedNode()) {
        _ = deleteSelectedShape();
    }
}

fn toggleFillSelected() bool {
    if (selected_shape < 0) return false;
    const si = @as(usize, @intCast(selected_shape));
    if (si >= shape_count) return false;
    if (shapes[si].typ == .line) return false;
    shapes[si].filled = !shapes[si].filled;
    return true;
}

fn canToggleFillSelected() bool {
    if (selected_shape < 0) return false;
    const si = @as(usize, @intCast(selected_shape));
    if (si >= shape_count) return false;
    return shapes[si].typ != .line;
}

fn handlePress(x: i32, y: i32) bool {
    if (handleToolbarPress(x, y)) return true;
    const p = canvasPoint(x, y) orelse return false;

    switch (tool) {
        .select => {
            if (hitNodeAny(p.x, p.y)) |hit| {
                selected_shape = hit.shape;
                selected_node = hit.node;
                selected_kind = hit.kind;
                dragging_shape_idx = hit.shape;
                dragging_node_idx = hit.node;
                interaction = .dragging_node;
                return true;
            }
            if (hitShapeEdge(p.x, p.y)) |shape_idx| {
                selected_shape = shape_idx;
                selected_node = -1;
                selected_kind = .anchor;
                interaction = .idle;
                return true;
            }
            selected_shape = -1;
            selected_node = -1;
            selected_kind = .anchor;
            interaction = .idle;
            return true;
        },
        .line => {
            interaction = .drawing_line;
            draft_line_a = p;
            draft_line_b = p;
            return true;
        },
        .polygon => {
            if (interaction != .drawing_polygon or draft_poly_count == 0) {
                interaction = .drawing_polygon;
                draft_poly_count = 1;
                draft_poly[0] = p;
                draft_poly_hover = p;
                selected_shape = -1;
                selected_node = -1;
                return true;
            }
            if (draft_poly_count >= 3 and nearPoint(p, draft_poly[0], NODE_HIT_R + 1)) {
                _ = finalizePolygonDraft();
                return true;
            }
            if (draft_poly_count < MAX_POINTS and !samePoint(p, draft_poly[draft_poly_count - 1])) {
                draft_poly[draft_poly_count] = p;
                draft_poly_count += 1;
                draft_poly_hover = p;
                return true;
            }
            return false;
        },
        .bezier => {
            if (interaction != .drawing_bezier) {
                interaction = .drawing_bezier;
                draft_bez_count = 0;
            }
            if (draft_bez_count >= MAX_POINTS) return false;
            if (draft_bez_count > 0 and samePoint(draft_bez[draft_bez_count - 1], p)) return false;
            draft_bez[draft_bez_count] = p;
            draft_bez_in[draft_bez_count] = p;
            draft_bez_out[draft_bez_count] = p;
            draft_bez_drag_idx = @as(i32, @intCast(draft_bez_count));
            draft_bez_count += 1;
            draft_bez_hover = p;
            selected_shape = -1;
            selected_node = -1;
            selected_kind = .anchor;
            return true;
        },
    }
}

fn handleDrag(x: i32, y: i32) bool {
    const p = canvasPoint(x, y) orelse return false;
    switch (interaction) {
        .drawing_line => {
            if (samePoint(p, draft_line_b)) return false;
            draft_line_b = p;
            return true;
        },
        .dragging_node => {
            if (dragging_shape_idx < 0 or dragging_node_idx < 0) return false;
            const si = @as(usize, @intCast(dragging_shape_idx));
            const ni = @as(usize, @intCast(dragging_node_idx));
            if (si >= shape_count) return false;
            const sh = &shapes[si];
            if (ni >= sh.point_count) return false;
            if (selected_kind == .anchor) {
                if (samePoint(sh.points[ni], p)) return false;
                const dx = p.x - sh.points[ni].x;
                const dy = p.y - sh.points[ni].y;
                sh.points[ni] = p;
                if (sh.typ == .bezier) {
                    sh.handle_in[ni].x += dx;
                    sh.handle_in[ni].y += dy;
                    sh.handle_out[ni].x += dx;
                    sh.handle_out[ni].y += dy;
                }
            } else if (selected_kind == .handle_in and sh.typ == .bezier) {
                if (samePoint(sh.handle_in[ni], p)) return false;
                sh.handle_in[ni] = p;
                sh.handle_out[ni] = .{
                    .x = sh.points[ni].x + (sh.points[ni].x - p.x),
                    .y = sh.points[ni].y + (sh.points[ni].y - p.y),
                };
            } else if (selected_kind == .handle_out and sh.typ == .bezier) {
                if (samePoint(sh.handle_out[ni], p)) return false;
                sh.handle_out[ni] = p;
                sh.handle_in[ni] = .{
                    .x = sh.points[ni].x + (sh.points[ni].x - p.x),
                    .y = sh.points[ni].y + (sh.points[ni].y - p.y),
                };
            } else return false;
            selected_shape = dragging_shape_idx;
            selected_node = dragging_node_idx;
            return true;
        },
        .drawing_polygon => {
            if (samePoint(draft_poly_hover, p)) return false;
            draft_poly_hover = p;
            return true;
        },
        .drawing_bezier => {
            if (draft_bez_drag_idx < 0) {
                if (samePoint(draft_bez_hover, p)) return false;
                draft_bez_hover = p;
                return true;
            }
            const idx = @as(usize, @intCast(draft_bez_drag_idx));
            if (idx >= draft_bez_count) return false;
            const anchor = draft_bez[idx];
            if (samePoint(draft_bez_out[idx], p)) return false;
            draft_bez_out[idx] = p;
            draft_bez_in[idx] = .{
                .x = anchor.x + (anchor.x - p.x),
                .y = anchor.y + (anchor.y - p.y),
            };
            draft_bez_hover = p;
            return true;
        },
        .idle => return false,
    }
}

fn handleRelease(x: i32, y: i32) bool {
    const p = canvasPoint(x, y) orelse Point{ .x = draft_line_b.x, .y = draft_line_b.y };
    defer {
        if (interaction == .dragging_node) interaction = .idle;
        if (interaction == .drawing_bezier) draft_bez_drag_idx = -1;
        dragging_shape_idx = -1;
        dragging_node_idx = -1;
    }

    switch (interaction) {
        .drawing_line => {
            interaction = .idle;
            draft_line_b = p;
            if (samePoint(draft_line_a, draft_line_b)) return false;
            if (addLineShape(draft_line_a, draft_line_b, 0)) |idx| {
                selected_shape = idx;
                selected_node = -1;
                selected_kind = .anchor;
                tool = .select;
                return true;
            }
            return false;
        },
        .dragging_node => return true,
        .drawing_bezier => {
            draft_bez_hover = p;
            return true;
        },
        .drawing_polygon, .idle => return false,
    }
}

fn handleToolbarPress(x: i32, y: i32) bool {
    if (buttonHit(x, y, TOOL_X, TOOL_Y, TOOL_W, TOOL_H)) {
        setTool(.select);
        return true;
    }
    if (buttonHit(x, y, TOOL_X, TOOL_Y + (TOOL_H + TOOL_GAP), TOOL_W, TOOL_H)) {
        setTool(.line);
        return true;
    }
    if (buttonHit(x, y, TOOL_X, TOOL_Y + 2 * (TOOL_H + TOOL_GAP), TOOL_W, TOOL_H)) {
        setTool(.polygon);
        return true;
    }
    if (buttonHit(x, y, TOOL_X, TOOL_Y + 3 * (TOOL_H + TOOL_GAP), TOOL_W, TOOL_H)) {
        setTool(.bezier);
        return true;
    }
    if (buttonHit(x, y, TOOL_X, 128, TOOL_W, TOOL_H)) {
        _ = toggleFillSelected();
        return true;
    }
    if (buttonHit(x, y, TOOL_X, 152, TOOL_W, TOOL_H)) {
        if (!finalizePolygonDraft()) _ = finalizeBezierDraft();
        return true;
    }
    if (buttonHit(x, y, TOOL_X, 176, TOOL_W, TOOL_H)) {
        _ = deleteSelectedNode();
        return true;
    }
    if (buttonHit(x, y, TOOL_X, 200, TOOL_W, TOOL_H)) {
        _ = deleteSelectedShape();
        return true;
    }
    return false;
}

fn addLineShape(a: Point, b: Point, color: u8) ?i32 {
    if (shape_count >= MAX_SHAPES) return null;
    var sh = Shape{};
    sh.typ = .line;
    sh.color = color;
    sh.point_count = 2;
    sh.points[0] = a;
    sh.points[1] = b;
    sh.handle_in[0] = a;
    sh.handle_out[0] = a;
    sh.handle_in[1] = b;
    sh.handle_out[1] = b;
    shapes[shape_count] = sh;
    const idx = @as(i32, @intCast(shape_count));
    shape_count += 1;
    return idx;
}

fn addPolygonShape(pts: []const Point, color: u8) ?i32 {
    if (shape_count >= MAX_SHAPES or pts.len < 3 or pts.len > MAX_POINTS) return null;
    var sh = Shape{};
    sh.typ = .polygon;
    sh.color = color;
    sh.point_count = @as(u8, @intCast(pts.len));
    var i: usize = 0;
    while (i < pts.len) : (i += 1) {
        sh.points[i] = pts[i];
        sh.handle_in[i] = pts[i];
        sh.handle_out[i] = pts[i];
    }
    shapes[shape_count] = sh;
    const idx = @as(i32, @intCast(shape_count));
    shape_count += 1;
    return idx;
}

fn addBezierShape(pts: []const Point, color: u8) ?i32 {
    if (shape_count >= MAX_SHAPES or pts.len < 2 or pts.len > MAX_POINTS) return null;
    var sh = Shape{};
    sh.typ = .bezier;
    sh.color = color;
    sh.point_count = @as(u8, @intCast(pts.len));

    var i: usize = 0;
    while (i < pts.len) : (i += 1) {
        sh.points[i] = pts[i];
        sh.handle_in[i] = pts[i];
        sh.handle_out[i] = pts[i];
    }
    computeSmoothHandles(sh.points[0..pts.len], sh.handle_in[0..pts.len], sh.handle_out[0..pts.len]);

    shapes[shape_count] = sh;
    const idx = @as(i32, @intCast(shape_count));
    shape_count += 1;
    return idx;
}

fn addBezierShapeWithHandles(pts: []const Point, hin: []const Point, hout: []const Point, color: u8) ?i32 {
    if (shape_count >= MAX_SHAPES or pts.len < 2 or pts.len > MAX_POINTS) return null;
    if (hin.len != pts.len or hout.len != pts.len) return null;
    var sh = Shape{};
    sh.typ = .bezier;
    sh.color = color;
    sh.point_count = @as(u8, @intCast(pts.len));
    var i: usize = 0;
    while (i < pts.len) : (i += 1) {
        sh.points[i] = pts[i];
        sh.handle_in[i] = hin[i];
        sh.handle_out[i] = hout[i];
    }
    shapes[shape_count] = sh;
    const idx = @as(i32, @intCast(shape_count));
    shape_count += 1;
    return idx;
}

fn finalizePolygonDraft() bool {
    if (interaction != .drawing_polygon or draft_poly_count < 3) return false;
    if (addPolygonShape(draft_poly[0..draft_poly_count], 1)) |idx| {
        selected_shape = idx;
        selected_node = -1;
        selected_kind = .anchor;
        draft_poly_count = 0;
        interaction = .idle;
        tool = .select;
        return true;
    }
    return false;
}

fn finalizeBezierDraft() bool {
    if (interaction != .drawing_bezier or draft_bez_count < 2) return false;
    if (addBezierShapeWithHandles(draft_bez[0..draft_bez_count], draft_bez_in[0..draft_bez_count], draft_bez_out[0..draft_bez_count], 0)) |idx| {
        selected_shape = idx;
        selected_node = -1;
        selected_kind = .anchor;
        draft_bez_count = 0;
        draft_bez_drag_idx = -1;
        interaction = .idle;
        tool = .select;
        return true;
    }
    return false;
}

fn deleteSelectedShape() bool {
    if (selected_shape < 0) return false;
    const idx = @as(usize, @intCast(selected_shape));
    if (idx >= shape_count) return false;
    var i = idx;
    while (i + 1 < shape_count) : (i += 1) {
        shapes[i] = shapes[i + 1];
    }
    shape_count -= 1;
    selected_shape = -1;
    selected_node = -1;
    selected_kind = .anchor;
    return true;
}

fn deleteSelectedNode() bool {
    if (selected_shape < 0 or selected_node < 0) return false;
    const si = @as(usize, @intCast(selected_shape));
    const ni = @as(usize, @intCast(selected_node));
    if (si >= shape_count) return false;
    const sh = &shapes[si];
    if (ni >= sh.point_count) return false;
    if (sh.typ == .bezier and selected_kind != .anchor) {
        if (selected_kind == .handle_in) sh.handle_in[ni] = sh.points[ni];
        if (selected_kind == .handle_out) sh.handle_out[ni] = sh.points[ni];
        return true;
    }
    if (sh.typ == .line) return deleteSelectedShape();

    const min_points: u8 = if (sh.typ == .polygon) 3 else 2;
    if (sh.point_count <= min_points) return deleteSelectedShape();
    var i = ni;
    while (i + 1 < sh.point_count) : (i += 1) {
        sh.points[i] = sh.points[i + 1];
        sh.handle_in[i] = sh.handle_in[i + 1];
        sh.handle_out[i] = sh.handle_out[i + 1];
    }
    sh.point_count -= 1;
    selected_node = -1;
    selected_kind = .anchor;
    return true;
}

fn hitNodeAny(x: i32, y: i32) ?Hit {
    var si = @as(i32, @intCast(shape_count)) - 1;
    while (si >= 0) : (si -= 1) {
        const sh = shapes[@as(usize, @intCast(si))];
        if (sh.typ == .bezier) {
            var j: usize = 0;
            while (j < sh.point_count) : (j += 1) {
                if (!samePoint(sh.handle_in[j], sh.points[j]) and nearPoint(.{ .x = x, .y = y }, sh.handle_in[j], NODE_HIT_R)) {
                    return .{ .shape = si, .node = @as(i32, @intCast(j)), .kind = .handle_in };
                }
                if (!samePoint(sh.handle_out[j], sh.points[j]) and nearPoint(.{ .x = x, .y = y }, sh.handle_out[j], NODE_HIT_R)) {
                    return .{ .shape = si, .node = @as(i32, @intCast(j)), .kind = .handle_out };
                }
            }
        }
        var i: usize = 0;
        while (i < sh.point_count) : (i += 1) {
            if (nearPoint(.{ .x = x, .y = y }, sh.points[i], NODE_HIT_R)) {
                return .{ .shape = si, .node = @as(i32, @intCast(i)), .kind = .anchor };
            }
        }
    }
    return null;
}

fn hitShapeEdge(x: i32, y: i32) ?i32 {
    var si = @as(i32, @intCast(shape_count)) - 1;
    while (si >= 0) : (si -= 1) {
        const sh = shapes[@as(usize, @intCast(si))];
        if (shapeEdgeHit(sh, .{ .x = x, .y = y })) return si;
    }
    return null;
}

fn shapeEdgeHit(sh: Shape, p: Point) bool {
    if (sh.point_count < 2) return false;
    if (sh.typ == .line) {
        return distancePointSegmentSq(p, sh.points[0], sh.points[1]) <= EDGE_HIT_PX * EDGE_HIT_PX;
    }
    if (sh.typ == .bezier) {
        var i: usize = 0;
        while (i + 1 < sh.point_count) : (i += 1) {
            if (bezierEdgeHit(sh.points[i], sh.handle_out[i], sh.handle_in[i + 1], sh.points[i + 1], p)) return true;
        }
        return false;
    }

    var i: usize = 0;
    while (i < sh.point_count) : (i += 1) {
        const a = sh.points[i];
        const b = sh.points[(i + 1) % sh.point_count];
        if (distancePointSegmentSq(p, a, b) <= EDGE_HIT_PX * EDGE_HIT_PX) return true;
    }
    return false;
}

fn distancePointSegmentSq(p: Point, a: Point, b: Point) f64 {
    const px = @as(f64, @floatFromInt(p.x));
    const py = @as(f64, @floatFromInt(p.y));
    const ax = @as(f64, @floatFromInt(a.x));
    const ay = @as(f64, @floatFromInt(a.y));
    const bx = @as(f64, @floatFromInt(b.x));
    const by = @as(f64, @floatFromInt(b.y));

    const dx = bx - ax;
    const dy = by - ay;
    const len_sq = dx * dx + dy * dy;
    if (len_sq <= 0.00001) {
        const rx = px - ax;
        const ry = py - ay;
        return rx * rx + ry * ry;
    }
    var t = ((px - ax) * dx + (py - ay) * dy) / len_sq;
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;
    const qx = ax + t * dx;
    const qy = ay + t * dy;
    const rx = px - qx;
    const ry = py - qy;
    return rx * rx + ry * ry;
}

fn bezierEdgeHit(a: Point, c1: Point, c2: Point, b: Point, p: Point) bool {
    var prev = a;
    var i: i32 = 1;
    while (i <= 24) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / 24.0;
        const cur = cubicPoint(a, c1, c2, b, t);
        if (distancePointSegmentSq(p, prev, cur) <= EDGE_HIT_PX * EDGE_HIT_PX) return true;
        prev = cur;
    }
    return false;
}

fn buildBezierPathPointsScreen(sh: Shape, out: *[MAX_PATH_POINTS]Point) usize {
    if (sh.point_count < 2) return 0;
    var n: usize = 0;
    out[n] = toScreen(sh.points[0]);
    n += 1;
    var i: usize = 0;
    while (i + 1 < sh.point_count and n < out.len) : (i += 1) {
        const a = toScreen(sh.points[i]);
        const c1 = toScreen(sh.handle_out[i]);
        const c2 = toScreen(sh.handle_in[i + 1]);
        const b = toScreen(sh.points[i + 1]);
        var s: i32 = 1;
        while (s <= 24 and n < out.len) : (s += 1) {
            const t = @as(f64, @floatFromInt(s)) / 24.0;
            out[n] = cubicPoint(a, c1, c2, b, t);
            n += 1;
        }
    }
    return n;
}

fn fillClosedPath(points: []const Point, color: Color) void {
    if (points.len < 3) return;
    var min_y = points[0].y;
    var max_y = points[0].y;
    var i: usize = 1;
    while (i < points.len) : (i += 1) {
        if (points[i].y < min_y) min_y = points[i].y;
        if (points[i].y > max_y) max_y = points[i].y;
    }

    min_y = @max(min_y, CANVAS_Y);
    max_y = @min(max_y, CANVAS_Y + CANVAS_H - 1);
    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x_count: usize = 0;
        i = 0;
        while (i < points.len) : (i += 1) {
            const a = points[i];
            const b = points[(i + 1) % points.len];
            if (a.y == b.y) continue;
            const y0 = @min(a.y, b.y);
            const y1 = @max(a.y, b.y);
            if (y < y0 or y >= y1) continue;
            if (x_count >= fill_xs.len) break;
            const t = (@as(f64, @floatFromInt(y)) + 0.5 - @as(f64, @floatFromInt(a.y))) /
                (@as(f64, @floatFromInt(b.y - a.y)));
            const x = @as(f64, @floatFromInt(a.x)) + t * @as(f64, @floatFromInt(b.x - a.x));
            fill_xs[x_count] = @as(i32, @intFromFloat(x));
            x_count += 1;
        }
        if (x_count < 2) continue;
        insertionSortI32(fill_xs[0..x_count]);

        var k: usize = 0;
        while (k + 1 < x_count) : (k += 2) {
            var x0 = fill_xs[k];
            var x1 = fill_xs[k + 1];
            if (x0 > x1) {
                const t = x0;
                x0 = x1;
                x1 = t;
            }
            x0 = @max(x0, CANVAS_X);
            x1 = @min(x1, CANVAS_X + CANVAS_W - 1);
            if (x1 >= x0) {
                fillRectI32(x0, y, x1 - x0 + 1, 1, color);
            }
        }
    }
}

fn insertionSortI32(values: []i32) void {
    var i: usize = 1;
    while (i < values.len) : (i += 1) {
        const key = values[i];
        var j = i;
        while (j > 0 and values[j - 1] > key) : (j -= 1) {
            values[j] = values[j - 1];
        }
        values[j] = key;
    }
}

fn cubicPoint(a: Point, c1: Point, c2: Point, b: Point, t: f64) Point {
    const u = 1.0 - t;
    const tt = t * t;
    const uu = u * u;
    const uuu = uu * u;
    const ttt = tt * t;
    const x = uuu * @as(f64, @floatFromInt(a.x)) +
        3.0 * uu * t * @as(f64, @floatFromInt(c1.x)) +
        3.0 * u * tt * @as(f64, @floatFromInt(c2.x)) +
        ttt * @as(f64, @floatFromInt(b.x));
    const y = uuu * @as(f64, @floatFromInt(a.y)) +
        3.0 * uu * t * @as(f64, @floatFromInt(c1.y)) +
        3.0 * u * tt * @as(f64, @floatFromInt(c2.y)) +
        ttt * @as(f64, @floatFromInt(b.y));
    return .{ .x = @as(i32, @intFromFloat(x + 0.5)), .y = @as(i32, @intFromFloat(y + 0.5)) };
}

fn drawFrame() void {
    fillRect(0, 0, RENDER_W, RENDER_H, C_BG);
    fillRectI32(0, 0, 58, @as(i32, @intCast(RENDER_H)), C_PANEL);
    drawBorder(0, 0, 58, @as(i32, @intCast(RENDER_H)), C_PANEL_LIGHT, C_PANEL_DARK);
    drawToolbar();

    fillRectI32(CANVAS_X - 1, CANVAS_Y - 1, CANVAS_W + 2, CANVAS_H + 2, C_PANEL_DARK);
    fillRectI32(CANVAS_X, CANVAS_Y, CANVAS_W, CANVAS_H, C_CANVAS);
    drawCanvasGrid();
    drawShapes();
    drawDraft();
    drawCanvasFrame();
}

fn drawToolbar() void {
    drawToolButton(TOOL_X, TOOL_Y, tool == .select, "SEL");
    drawToolButton(TOOL_X, TOOL_Y + (TOOL_H + TOOL_GAP), tool == .line, "LIN");
    drawToolButton(TOOL_X, TOOL_Y + 2 * (TOOL_H + TOOL_GAP), tool == .polygon, "POL");
    drawToolButton(TOOL_X, TOOL_Y + 3 * (TOOL_H + TOOL_GAP), tool == .bezier, "BEZ");

    const can_finish = (interaction == .drawing_polygon and draft_poly_count >= 3) or (interaction == .drawing_bezier and draft_bez_count >= 2);
    const fill_enabled = canToggleFillSelected();
    const fill_on = fill_enabled and shapes[@as(usize, @intCast(selected_shape))].filled;
    drawActionButton(TOOL_X, 128, fill_enabled, if (fill_on) "FIL1" else "FIL0");
    drawActionButton(TOOL_X, 152, can_finish, "FIN");
    drawActionButton(TOOL_X, 176, selected_shape >= 0 and selected_node >= 0, "DELN");
    drawActionButton(TOOL_X, 200, selected_shape >= 0, "DELS");

    drawText(8, 8, "1/2/3/4", C_TEXT);
    drawText(8, 124, "G", C_TEXT);
}

fn drawToolButton(x: i32, y: i32, active: bool, label: []const u8) void {
    fillRectI32(x, y, TOOL_W, TOOL_H, if (active) C_BTN_ACTIVE else C_PANEL);
    drawBorder(x, y, TOOL_W, TOOL_H, C_PANEL_LIGHT, C_PANEL_DARK);
    drawText(x + 6, y + 7, label, C_TEXT);
}

fn drawActionButton(x: i32, y: i32, enabled: bool, label: []const u8) void {
    fillRectI32(x, y, TOOL_W, TOOL_H, if (enabled) C_PANEL else .{ 0xD8, 0xDE, 0xE8, 0xFF });
    drawBorder(x, y, TOOL_W, TOOL_H, C_PANEL_LIGHT, C_PANEL_DARK);
    drawText(x + 4, y + 7, label, if (enabled) C_TEXT else .{ 0x6E, 0x78, 0x87, 0xFF });
}

fn drawCanvasGrid() void {
    var x = CANVAS_X;
    while (x <= CANVAS_X + CANVAS_W) : (x += 20) {
        drawLineScreen(x, CANVAS_Y, x, CANVAS_Y + CANVAS_H - 1, C_GRID);
    }
    var y = CANVAS_Y;
    while (y <= CANVAS_Y + CANVAS_H) : (y += 20) {
        drawLineScreen(CANVAS_X, y, CANVAS_X + CANVAS_W - 1, y, C_GRID);
    }
}

fn drawShapes() void {
    var i: usize = 0;
    while (i < shape_count) : (i += 1) {
        const sh = shapes[i];
        const is_selected = selected_shape == @as(i32, @intCast(i));
        const base = strokeColor(sh.color);
        const stroke = if (is_selected) C_SELECTED else base;
        if (sh.filled and sh.typ != .line) {
            drawShapeFill(sh, fillColor(sh.color));
        }
        drawShape(stroke, sh);
        if (is_selected) drawShapeHandles(sh);
    }
}

fn strokeColor(color_idx: u8) Color {
    return if (color_idx == 0) C_LINE else C_LINE_ALT;
}

fn fillColor(color_idx: u8) Color {
    return if (color_idx == 0) .{ 0xD7, 0xE5, 0xFF, 0xFF } else .{ 0xF6, 0xD9, 0xDE, 0xFF };
}

fn drawShapeFill(sh: Shape, color: Color) void {
    var n: usize = 0;
    if (sh.typ == .polygon) {
        n = sh.point_count;
        var i: usize = 0;
        while (i < n and i < path_buf.len) : (i += 1) {
            path_buf[i] = toScreen(sh.points[i]);
        }
    } else if (sh.typ == .bezier) {
        n = buildBezierPathPointsScreen(sh, &path_buf);
    } else return;
    fillClosedPath(path_buf[0..n], color);
}

fn drawShape(color: Color, sh: Shape) void {
    if (sh.point_count < 2) return;
    if (sh.typ == .line) {
        const a = toScreen(sh.points[0]);
        const b = toScreen(sh.points[1]);
        drawStrokeLineScreen(a.x, a.y, b.x, b.y, color);
        return;
    }
    if (sh.typ == .bezier) {
        var i: usize = 0;
        while (i + 1 < sh.point_count) : (i += 1) {
            drawBezierSegment(
                toScreen(sh.points[i]),
                toScreen(sh.handle_out[i]),
                toScreen(sh.handle_in[i + 1]),
                toScreen(sh.points[i + 1]),
                color,
            );
        }
        return;
    }

    var i: usize = 0;
    while (i < sh.point_count) : (i += 1) {
        const a = toScreen(sh.points[i]);
        const b = toScreen(sh.points[(i + 1) % sh.point_count]);
        drawStrokeLineScreen(a.x, a.y, b.x, b.y, color);
    }
}

fn drawShapeHandles(sh: Shape) void {
    if (sh.typ == .bezier) {
        var i: usize = 0;
        while (i < sh.point_count) : (i += 1) {
            const anchor = toScreen(sh.points[i]);
            const hin = toScreen(sh.handle_in[i]);
            const hout = toScreen(sh.handle_out[i]);
            if (!samePoint(hin, anchor)) {
                drawStrokeLineScreen(anchor.x, anchor.y, hin.x, hin.y, .{ 0x92, 0x9F, 0xB2, 0xFF });
                drawHandleDot(hin, selected_node == @as(i32, @intCast(i)) and selected_kind == .handle_in);
            }
            if (!samePoint(hout, anchor)) {
                drawStrokeLineScreen(anchor.x, anchor.y, hout.x, hout.y, .{ 0x92, 0x9F, 0xB2, 0xFF });
                drawHandleDot(hout, selected_node == @as(i32, @intCast(i)) and selected_kind == .handle_out);
            }
        }
    }
    var i: usize = 0;
    while (i < sh.point_count) : (i += 1) {
        const p = toScreen(sh.points[i]);
        const anchor_selected = selected_node == @as(i32, @intCast(i)) and selected_kind == .anchor;
        if (anchor_selected) {
            fillRectI32(p.x - 4, p.y - 4, 9, 9, C_SELECTED);
            drawRectScreen(p.x - 4, p.y - 4, 9, 9, C_HANDLE_BORDER);
            fillRectI32(p.x - 1, p.y - 1, 3, 3, C_SELECTED_CORE);
        } else {
            fillRectI32(p.x - NODE_VIS_R, p.y - NODE_VIS_R, NODE_VIS_R * 2 + 1, NODE_VIS_R * 2 + 1, C_HANDLE);
            drawRectScreen(p.x - NODE_VIS_R, p.y - NODE_VIS_R, NODE_VIS_R * 2 + 1, NODE_VIS_R * 2 + 1, C_HANDLE_BORDER);
        }
    }
}

fn drawHandleDot(p: Point, selected: bool) void {
    fillRectI32(
        p.x - HANDLE_VIS_R,
        p.y - HANDLE_VIS_R,
        HANDLE_VIS_R * 2 + 1,
        HANDLE_VIS_R * 2 + 1,
        if (selected) C_SELECTED else C_HANDLE,
    );
    drawRectScreen(
        p.x - HANDLE_VIS_R,
        p.y - HANDLE_VIS_R,
        HANDLE_VIS_R * 2 + 1,
        HANDLE_VIS_R * 2 + 1,
        C_HANDLE_BORDER,
    );
}

fn drawDraft() void {
    switch (interaction) {
        .drawing_line => {
            const a = toScreen(draft_line_a);
            const b = toScreen(draft_line_b);
            drawStrokeLineScreen(a.x, a.y, b.x, b.y, C_PREVIEW);
            drawNodePreview(a);
            drawNodePreview(b);
        },
        .drawing_polygon => {
            if (draft_poly_count == 0) return;
            var i: usize = 0;
            while (i + 1 < draft_poly_count) : (i += 1) {
                const a = toScreen(draft_poly[i]);
                const b = toScreen(draft_poly[i + 1]);
                drawStrokeLineScreen(a.x, a.y, b.x, b.y, C_PREVIEW);
            }
            const last = toScreen(draft_poly[draft_poly_count - 1]);
            const hover = toScreen(draft_poly_hover);
            drawStrokeLineScreen(last.x, last.y, hover.x, hover.y, C_PREVIEW);
            if (draft_poly_count >= 3) {
                const first = toScreen(draft_poly[0]);
                drawStrokeLineScreen(hover.x, hover.y, first.x, first.y, .{ 0x92, 0xC9, 0xAF, 0xFF });
            }

            i = 0;
            while (i < draft_poly_count) : (i += 1) {
                drawNodePreview(toScreen(draft_poly[i]));
            }
        },
        .drawing_bezier => {
            if (draft_bez_count == 0) return;
            var i: usize = 0;
            while (i + 1 < draft_bez_count) : (i += 1) {
                const a = toScreen(draft_bez[i]);
                const b = toScreen(draft_bez[i + 1]);
                const c1 = toScreen(draft_bez_out[i]);
                const c2 = toScreen(draft_bez_in[i + 1]);
                drawBezierSegment(a, c1, c2, b, C_PREVIEW);
            }

            const last = draft_bez[draft_bez_count - 1];
            if (!samePoint(last, draft_bez_hover)) {
                const a = toScreen(last);
                const b = toScreen(draft_bez_hover);
                const c1 = toScreen(draft_bez_out[draft_bez_count - 1]);
                const c2 = toScreen(lerpThird(draft_bez_hover, last));
                drawBezierSegment(a, c1, c2, b, .{ 0x7E, 0xBA, 0x97, 0xFF });
            }

            i = 0;
            while (i < draft_bez_count) : (i += 1) {
                const a = toScreen(draft_bez[i]);
                const hin = toScreen(draft_bez_in[i]);
                const hout = toScreen(draft_bez_out[i]);
                if (!samePoint(hin, a)) {
                    drawStrokeLineScreen(a.x, a.y, hin.x, hin.y, .{ 0xA8, 0xB9, 0xAE, 0xFF });
                    drawHandleDot(hin, false);
                }
                if (!samePoint(hout, a)) {
                    drawStrokeLineScreen(a.x, a.y, hout.x, hout.y, .{ 0xA8, 0xB9, 0xAE, 0xFF });
                    drawHandleDot(hout, false);
                }
                drawNodePreview(a);
            }
        },
        .dragging_node, .idle => {},
    }
}

fn drawNodePreview(p: Point) void {
    fillRectI32(p.x - 2, p.y - 2, 5, 5, C_PREVIEW);
}

fn drawCanvasFrame() void {
    drawRectScreen(CANVAS_X - 1, CANVAS_Y - 1, CANVAS_W + 2, CANVAS_H + 2, C_PANEL_DARK);
}

fn canvasPoint(x: i32, y: i32) ?Point {
    if (x < CANVAS_X or y < CANVAS_Y) return null;
    const cx = x - CANVAS_X;
    const cy = y - CANVAS_Y;
    if (cx >= CANVAS_W or cy >= CANVAS_H) return null;
    return .{ .x = cx, .y = cy };
}

fn toScreen(p: Point) Point {
    return .{ .x = CANVAS_X + p.x, .y = CANVAS_Y + p.y };
}

fn buttonHit(x: i32, y: i32, bx: i32, by: i32, bw: i32, bh: i32) bool {
    return x >= bx and y >= by and x < bx + bw and y < by + bh;
}

fn nearPoint(a: Point, b: Point, radius: i32) bool {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return dx * dx + dy * dy <= radius * radius;
}

fn samePoint(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y;
}

fn computeSmoothHandles(points: []const Point, in_handles: []Point, out_handles: []Point) void {
    if (points.len == 0) return;
    var i: usize = 0;
    while (i < points.len) : (i += 1) {
        in_handles[i] = points[i];
        out_handles[i] = points[i];
    }
    if (points.len == 1) return;

    out_handles[0] = lerpThird(points[0], points[1]);
    in_handles[points.len - 1] = lerpThird(points[points.len - 1], points[points.len - 2]);
    if (points.len == 2) return;

    i = 1;
    while (i + 1 < points.len) : (i += 1) {
        const p_prev = points[i - 1];
        const p = points[i];
        const p_next = points[i + 1];
        const vx = @as(f64, @floatFromInt(p_next.x - p_prev.x));
        const vy = @as(f64, @floatFromInt(p_next.y - p_prev.y));
        const vlen = std.math.sqrt(vx * vx + vy * vy);
        if (vlen < 0.0001) continue;
        const tx = vx / vlen;
        const ty = vy / vlen;
        const d_prev = pointDistance(p, p_prev);
        const d_next = pointDistance(p_next, p);
        const s = @min(d_prev, d_next) / 3.0;
        out_handles[i] = .{
            .x = p.x + @as(i32, @intFromFloat(tx * s)),
            .y = p.y + @as(i32, @intFromFloat(ty * s)),
        };
        in_handles[i] = .{
            .x = p.x - @as(i32, @intFromFloat(tx * s)),
            .y = p.y - @as(i32, @intFromFloat(ty * s)),
        };
    }
}

fn lerpThird(a: Point, b: Point) Point {
    return .{
        .x = a.x + @divTrunc(b.x - a.x, 3),
        .y = a.y + @divTrunc(b.y - a.y, 3),
    };
}

fn pointDistance(a: Point, b: Point) f64 {
    const dx = @as(f64, @floatFromInt(a.x - b.x));
    const dy = @as(f64, @floatFromInt(a.y - b.y));
    return std.math.sqrt(dx * dx + dy * dy);
}

fn drawBorder(x: i32, y: i32, w: i32, h: i32, hi: Color, lo: Color) void {
    fillRectI32(x, y, w, 1, hi);
    fillRectI32(x, y, 1, h, hi);
    fillRectI32(x, y + h - 1, w, 1, lo);
    fillRectI32(x + w - 1, y, 1, h, lo);
}

fn drawRectScreen(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    fillRectI32(x, y, w, 1, c);
    fillRectI32(x, y + h - 1, w, 1, c);
    fillRectI32(x, y, 1, h, c);
    fillRectI32(x + w - 1, y, 1, h, c);
}

fn drawLineScreen(x0_in: i32, y0_in: i32, x1: i32, y1: i32, c: Color) void {
    var x0 = x0_in;
    var y0 = y0_in;
    const dx = absI32(x1 - x0);
    const sx: i32 = if (x0 < x1) 1 else -1;
    const dy = -absI32(y1 - y0);
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    while (true) {
        setPixelI32(x0, y0, c);
        if (x0 == x1 and y0 == y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x0 += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y0 += sy;
        }
    }
}

fn drawStrokeLineScreen(x0: i32, y0: i32, x1: i32, y1: i32, c: Color) void {
    const dx = absI32(x1 - x0);
    const dy = absI32(y1 - y0);
    if (dx == 0 and dy == 0) {
        setPixelI32(x0, y0, c);
        return;
    }
    if (dx == 0 or dy == 0) {
        drawLineScreen(x0, y0, x1, y1, c);
        return;
    }
    drawLineScreenAA(x0, y0, x1, y1, c);
}

fn drawLineScreenAA(x0_in: i32, y0_in: i32, x1_in: i32, y1_in: i32, c: Color) void {
    var x0 = @as(f64, @floatFromInt(x0_in));
    var y0 = @as(f64, @floatFromInt(y0_in));
    var x1 = @as(f64, @floatFromInt(x1_in));
    var y1 = @as(f64, @floatFromInt(y1_in));

    const steep = @abs(y1 - y0) > @abs(x1 - x0);
    if (steep) {
        const tx0 = x0;
        x0 = y0;
        y0 = tx0;
        const tx1 = x1;
        x1 = y1;
        y1 = tx1;
    }
    if (x0 > x1) {
        const tx0 = x0;
        x0 = x1;
        x1 = tx0;
        const ty0 = y0;
        y0 = y1;
        y1 = ty0;
    }

    const dx = x1 - x0;
    const dy = y1 - y0;
    const gradient = if (@abs(dx) < 0.000_001) 1.0 else dy / dx;

    var xend = @floor(x0 + 0.5);
    var yend = y0 + gradient * (xend - x0);
    var xgap = rfpartF64(x0 + 0.5);
    const xpxl1 = @as(i32, @intFromFloat(xend));
    const ypxl1 = @as(i32, @intFromFloat(@floor(yend)));
    plotAAPixel(steep, xpxl1, ypxl1, rfpartF64(yend) * xgap, c);
    plotAAPixel(steep, xpxl1, ypxl1 + 1, fpartF64(yend) * xgap, c);
    var intery = yend + gradient;

    xend = @floor(x1 + 0.5);
    yend = y1 + gradient * (xend - x1);
    xgap = fpartF64(x1 + 0.5);
    const xpxl2 = @as(i32, @intFromFloat(xend));
    const ypxl2 = @as(i32, @intFromFloat(@floor(yend)));
    plotAAPixel(steep, xpxl2, ypxl2, rfpartF64(yend) * xgap, c);
    plotAAPixel(steep, xpxl2, ypxl2 + 1, fpartF64(yend) * xgap, c);

    var x: i32 = xpxl1 + 1;
    while (x < xpxl2) : (x += 1) {
        const yi = @as(i32, @intFromFloat(@floor(intery)));
        plotAAPixel(steep, x, yi, rfpartF64(intery), c);
        plotAAPixel(steep, x, yi + 1, fpartF64(intery), c);
        intery += gradient;
    }
}

fn plotAAPixel(steep: bool, x: i32, y: i32, coverage: f64, c: Color) void {
    if (coverage <= 0.0) return;
    const cov = clampF64(coverage, 0.0, 1.0);
    const alpha = @as(u8, @intFromFloat(cov * 255.0));
    if (alpha == 0) return;
    if (steep) {
        blendPixelI32(y, x, c, alpha);
    } else {
        blendPixelI32(x, y, c, alpha);
    }
}

fn blendPixelI32(x: i32, y: i32, src: Color, alpha: u8) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    const a_src = @as(u32, @intCast(alpha)) * @as(u32, @intCast(src[3])) / 255;
    if (a_src == 0) return;
    const a_inv = 255 - a_src;
    output_buf[idx + 0] = @as(u8, @intCast((@as(u32, @intCast(src[0])) * a_src + @as(u32, @intCast(output_buf[idx + 0])) * a_inv + 127) / 255));
    output_buf[idx + 1] = @as(u8, @intCast((@as(u32, @intCast(src[1])) * a_src + @as(u32, @intCast(output_buf[idx + 1])) * a_inv + 127) / 255));
    output_buf[idx + 2] = @as(u8, @intCast((@as(u32, @intCast(src[2])) * a_src + @as(u32, @intCast(output_buf[idx + 2])) * a_inv + 127) / 255));
    output_buf[idx + 3] = 0xFF;
}

fn fpartF64(v: f64) f64 {
    return v - @floor(v);
}

fn rfpartF64(v: f64) f64 {
    return 1.0 - fpartF64(v);
}

fn drawBezierSegment(a: Point, c1: Point, c2: Point, b: Point, color: Color) void {
    var prev = a;
    var i: i32 = 1;
    while (i <= 24) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / 24.0;
        const cur = cubicPoint(a, c1, c2, b, t);
        drawStrokeLineScreen(prev.x, prev.y, cur.x, cur.y, color);
        prev = cur;
    }
}

fn drawText(x0: i32, y0: i32, text: []const u8, color: Color) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        drawChar(x0 + @as(i32, @intCast(i * 4)), y0, text[i], color);
    }
}

fn drawChar(x: i32, y: i32, ch: u8, c: Color) void {
    const rows = switch (ch) {
        '1' => [_]u8{ 0b010, 0b110, 0b010, 0b010, 0b111 },
        '2' => [_]u8{ 0b111, 0b001, 0b111, 0b100, 0b111 },
        '3' => [_]u8{ 0b111, 0b001, 0b111, 0b001, 0b111 },
        '4' => [_]u8{ 0b101, 0b101, 0b111, 0b001, 0b001 },
        '/' => [_]u8{ 0b001, 0b001, 0b010, 0b100, 0b100 },
        'A' => [_]u8{ 0b010, 0b101, 0b111, 0b101, 0b101 },
        'B' => [_]u8{ 0b110, 0b101, 0b110, 0b101, 0b110 },
        'C' => [_]u8{ 0b111, 0b100, 0b100, 0b100, 0b111 },
        'D' => [_]u8{ 0b110, 0b101, 0b101, 0b101, 0b110 },
        'E' => [_]u8{ 0b111, 0b100, 0b111, 0b100, 0b111 },
        'F' => [_]u8{ 0b111, 0b100, 0b111, 0b100, 0b100 },
        'G' => [_]u8{ 0b111, 0b100, 0b101, 0b101, 0b111 },
        'I' => [_]u8{ 0b111, 0b010, 0b010, 0b010, 0b111 },
        'L' => [_]u8{ 0b100, 0b100, 0b100, 0b100, 0b111 },
        'N' => [_]u8{ 0b101, 0b111, 0b111, 0b111, 0b101 },
        'O' => [_]u8{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        'P' => [_]u8{ 0b110, 0b101, 0b110, 0b100, 0b100 },
        'R' => [_]u8{ 0b110, 0b101, 0b110, 0b101, 0b101 },
        'S' => [_]u8{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        'T' => [_]u8{ 0b111, 0b010, 0b010, 0b010, 0b010 },
        'V' => [_]u8{ 0b101, 0b101, 0b101, 0b101, 0b010 },
        'Z' => [_]u8{ 0b111, 0b001, 0b010, 0b100, 0b111 },
        else => [_]u8{ 0, 0, 0, 0, 0 },
    };
    drawRows(x, y, rows, c);
}

fn drawRows(x0: i32, y0: i32, rows: [5]u8, color: Color) void {
    var y: usize = 0;
    while (y < 5) : (y += 1) {
        var x: usize = 0;
        while (x < 3) : (x += 1) {
            if ((rows[y] & (@as(u8, 1) << @as(u3, @intCast(2 - x)))) != 0) {
                setPixelI32(x0 + @as(i32, @intCast(x)), y0 + @as(i32, @intCast(y)), color);
            }
        }
    }
}

fn fillRect(x0: usize, y0: usize, w: usize, h: usize, c: Color) void {
    var y = y0;
    while (y < y0 + h and y < RENDER_H) : (y += 1) {
        var x = x0;
        while (x < x0 + w and x < RENDER_W) : (x += 1) {
            setPixel(x, y, c);
        }
    }
}

fn fillRectI32(x0: i32, y0: i32, w: i32, h: i32, c: Color) void {
    if (w <= 0 or h <= 0) return;
    const sx = clampI32(x0, 0, @as(i32, @intCast(RENDER_W)));
    const sy = clampI32(y0, 0, @as(i32, @intCast(RENDER_H)));
    const ex = clampI32(x0 + w, 0, @as(i32, @intCast(RENDER_W)));
    const ey = clampI32(y0 + h, 0, @as(i32, @intCast(RENDER_H)));
    if (sx >= ex or sy >= ey) return;
    fillRect(
        @as(usize, @intCast(sx)),
        @as(usize, @intCast(sy)),
        @as(usize, @intCast(ex - sx)),
        @as(usize, @intCast(ey - sy)),
        c,
    );
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

fn clampI32(v: i32, lo: i32, hi: i32) i32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn clampF64(v: f64, lo: f64, hi: f64) f64 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn absI32(v: i32) i32 {
    return if (v < 0) -v else v;
}

test "segment distance hits midpoint" {
    const d = distancePointSegmentSq(.{ .x = 5, .y = 2 }, .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 });
    try std.testing.expect(d == 4.0);
}
