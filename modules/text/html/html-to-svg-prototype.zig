const std = @import("std");

const INPUT_CAP: usize = 512 * 1024;
const OUTPUT_CAP: usize = 4 * 1024 * 1024;
const TEXT_POOL_CAP: usize = 512 * 1024;
const MAX_NODES: usize = 4096;
const MAX_STACK: usize = 512;
const MAX_OPS: usize = 16384;
const MAX_FLEX_LINE_ITEMS: usize = 256;
const MAX_LAYOUT_DEPTH: usize = 256;

const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "image/svg+xml";

const DEFAULT_WIDTH: i32 = 1200;
const DEFAULT_HEIGHT: i32 = 800;
const MIN_DIM: i32 = 64;
const MAX_DIM: i32 = 4096;

const DEFAULT_FONT_SIZE: f32 = 16.0;
const DEFAULT_LINE_HEIGHT: f32 = 22.0;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var text_pool: [TEXT_POOL_CAP]u8 = undefined;

var canvas_width: i32 = DEFAULT_WIDTH;
var canvas_height: i32 = DEFAULT_HEIGHT;

const Display = enum(u8) {
    block,
    inline,
    flex,
};

const FlexDirection = enum(u8) {
    row,
    column,
};

const Justify = enum(u8) {
    start,
    center,
    end,
    between,
};

const Align = enum(u8) {
    start,
    center,
    end,
    stretch,
};

const Tag = enum(u8) {
    root,
    unknown,
    body,
    div,
    section,
    article,
    header,
    footer,
    main,
    nav,
    p,
    span,
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,
    ul,
    ol,
    li,
    a,
    img,
    br,
};

const NodeKind = enum(u8) {
    element,
    text,
    image,
    br,
};

const Style = struct {
    display: Display = .block,
    flex_direction: FlexDirection = .row,
    flex_wrap: bool = false,
    justify: Justify = .start,
    align: Align = .start,
    gap: f32 = 0,
    padding_top: f32 = 0,
    padding_right: f32 = 0,
    padding_bottom: f32 = 0,
    padding_left: f32 = 0,
    font_size: f32 = DEFAULT_FONT_SIZE,
    font_weight: u16 = 400,
    line_height: f32 = DEFAULT_LINE_HEIGHT,
    color_rgba: u32 = 0x1f2937ff,
    width_px: f32 = 0,
    height_px: f32 = 0,

    fn inheritText(self: *Style, parent: Style) void {
        self.font_size = parent.font_size;
        self.font_weight = parent.font_weight;
        self.line_height = parent.line_height;
        self.color_rgba = parent.color_rgba;
    }
};

const Node = struct {
    kind: NodeKind = .element,
    tag: Tag = .unknown,
    parent: i32 = -1,
    first_child: i32 = -1,
    last_child: i32 = -1,
    next_sibling: i32 = -1,
    style: Style = .{},
    text_start: u32 = 0,
    text_len: u32 = 0,
    list_index: u16 = 0,
    has_href: bool = false,
};

const LayoutSize = struct {
    width: f32,
    height: f32,
};

const OpKind = enum(u8) {
    rect,
    text,
};

const DrawOp = struct {
    kind: OpKind,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color_rgba: u32,
    font_size: f32,
    font_weight: u16,
    text_start: u32,
    text_len: u32,
};

const ParseResult = struct {
    root_idx: usize,
    warnings: u32,
};

var nodes_buf: [MAX_NODES]Node = undefined;
var nodes_len: usize = 0;
var text_pool_len: usize = 0;

var draw_ops: [MAX_OPS]DrawOp = undefined;
var draw_ops_len: usize = 0;

const Writer = struct {
    idx: usize = 0,

    fn writeByte(self: *Writer, b: u8) !void {
        if (self.idx >= OUTPUT_CAP) return error.OutputOverflow;
        output_buf[self.idx] = b;
        self.idx += 1;
    }

    fn writeSlice(self: *Writer, s: []const u8) !void {
        if (self.idx + s.len > OUTPUT_CAP) return error.OutputOverflow;
        @memcpy(output_buf[self.idx .. self.idx + s.len], s);
        self.idx += s.len;
    }

    fn writeFmt(self: *Writer, comptime fmt: []const u8, args: anytype) !void {
        var tmp: [128]u8 = undefined;
        const rendered = try std.fmt.bufPrint(&tmp, fmt, args);
        try self.writeSlice(rendered);
    }
};

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&output_buf)));
}

export fn output_utf8_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

export fn input_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr)));
}

export fn input_content_type_size() u32 {
    return @as(u32, @intCast(INPUT_CONTENT_TYPE.len));
}

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(OUTPUT_CONTENT_TYPE.len));
}

export fn uniform_set_width(value: i32) i32 {
    var v = value;
    if (v < MIN_DIM) v = MIN_DIM;
    if (v > MAX_DIM) v = MAX_DIM;
    canvas_width = v;
    return v;
}

export fn uniform_set_height(value: i32) i32 {
    var v = value;
    if (v < MIN_DIM) v = MIN_DIM;
    if (v > MAX_DIM) v = MAX_DIM;
    canvas_height = v;
    return v;
}

fn asciiLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t' or c == 0x0C;
}

fn isNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == ':';
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (asciiLower(x) != asciiLower(y)) return false;
    }
    return true;
}

fn startsWithIgnoreCase(a: []const u8, b: []const u8) bool {
    if (b.len > a.len) return false;
    var i: usize = 0;
    while (i < b.len) : (i += 1) {
        if (asciiLower(a[i]) != asciiLower(b[i])) return false;
    }
    return true;
}

fn parseUnsignedInt(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var value: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        const digit: u32 = c - '0';
        if (value > (std.math.maxInt(u32) - digit) / 10) return null;
        value = value * 10 + digit;
    }
    return value;
}

fn parsePxValue(raw: []const u8) ?f32 {
    var s = raw;
    while (s.len > 0 and isSpace(s[0])) s = s[1..];
    while (s.len > 0 and isSpace(s[s.len - 1])) s = s[0 .. s.len - 1];
    if (s.len == 0) return null;

    if (std.mem.endsWith(u8, s, "px")) {
        s = s[0 .. s.len - 2];
        while (s.len > 0 and isSpace(s[s.len - 1])) s = s[0 .. s.len - 1];
    }

    if (std.fmt.parseFloat(f32, s)) |value| {
        if (value < 0) return null;
        return value;
    } else |_| {
        return null;
    }
}

fn parseCssColor(raw: []const u8) ?u32 {
    var s = raw;
    while (s.len > 0 and isSpace(s[0])) s = s[1..];
    while (s.len > 0 and isSpace(s[s.len - 1])) s = s[0 .. s.len - 1];
    if (s.len == 0) return null;

    if (s[0] == '#' and (s.len == 7 or s.len == 9)) {
        var value: u32 = 0;
        var i: usize = 1;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            var nibble: u32 = 0;
            if (c >= '0' and c <= '9') {
                nibble = c - '0';
            } else if (c >= 'a' and c <= 'f') {
                nibble = c - 'a' + 10;
            } else if (c >= 'A' and c <= 'F') {
                nibble = c - 'A' + 10;
            } else return null;
            value = (value << 4) | nibble;
        }
        if (s.len == 7) return (value << 8) | 0xff;
        return value;
    }

    if (eqIgnoreCase(s, "black")) return 0x000000ff;
    if (eqIgnoreCase(s, "white")) return 0xffffffff;
    if (eqIgnoreCase(s, "gray") or eqIgnoreCase(s, "grey")) return 0x6b7280ff;
    if (eqIgnoreCase(s, "red")) return 0xef4444ff;
    if (eqIgnoreCase(s, "blue")) return 0x2563ebff;
    if (eqIgnoreCase(s, "green")) return 0x16a34aff;

    return null;
}

fn colorRgb(c: u32) struct { r: u8, g: u8, b: u8, a: u8 } {
    return .{
        .r = @intCast((c >> 24) & 0xff),
        .g = @intCast((c >> 16) & 0xff),
        .b = @intCast((c >> 8) & 0xff),
        .a = @intCast(c & 0xff),
    };
}

fn mapTag(name: []const u8) Tag {
    if (eqIgnoreCase(name, "body")) return .body;
    if (eqIgnoreCase(name, "div")) return .div;
    if (eqIgnoreCase(name, "section")) return .section;
    if (eqIgnoreCase(name, "article")) return .article;
    if (eqIgnoreCase(name, "header")) return .header;
    if (eqIgnoreCase(name, "footer")) return .footer;
    if (eqIgnoreCase(name, "main")) return .main;
    if (eqIgnoreCase(name, "nav")) return .nav;
    if (eqIgnoreCase(name, "p")) return .p;
    if (eqIgnoreCase(name, "span")) return .span;
    if (eqIgnoreCase(name, "h1")) return .h1;
    if (eqIgnoreCase(name, "h2")) return .h2;
    if (eqIgnoreCase(name, "h3")) return .h3;
    if (eqIgnoreCase(name, "h4")) return .h4;
    if (eqIgnoreCase(name, "h5")) return .h5;
    if (eqIgnoreCase(name, "h6")) return .h6;
    if (eqIgnoreCase(name, "ul")) return .ul;
    if (eqIgnoreCase(name, "ol")) return .ol;
    if (eqIgnoreCase(name, "li")) return .li;
    if (eqIgnoreCase(name, "a")) return .a;
    if (eqIgnoreCase(name, "img")) return .img;
    if (eqIgnoreCase(name, "br")) return .br;
    return .unknown;
}

fn isVoidTag(tag: Tag) bool {
    return tag == .img or tag == .br;
}

fn newNode() usize {
    if (nodes_len >= MAX_NODES) @trap();
    const idx = nodes_len;
    nodes_buf[idx] = Node{};
    nodes_len += 1;
    return idx;
}

fn appendChild(parent_idx: usize, child_idx: usize) void {
    var parent = &nodes_buf[parent_idx];
    nodes_buf[child_idx].parent = @intCast(parent_idx);
    if (parent.first_child < 0) {
        parent.first_child = @intCast(child_idx);
        parent.last_child = @intCast(child_idx);
        return;
    }
    const last_idx: usize = @intCast(parent.last_child);
    nodes_buf[last_idx].next_sibling = @intCast(child_idx);
    parent.last_child = @intCast(child_idx);
}

fn writeTextToPool(bytes: []const u8) u32 {
    if (text_pool_len + bytes.len > TEXT_POOL_CAP) @trap();
    const start = text_pool_len;
    @memcpy(text_pool[start .. start + bytes.len], bytes);
    text_pool_len += bytes.len;
    return @intCast(start);
}

fn appendByteToPool(b: u8) void {
    if (text_pool_len >= TEXT_POOL_CAP) @trap();
    text_pool[text_pool_len] = b;
    text_pool_len += 1;
}

fn decodeEntity(input: []const u8, pos: usize, consumed: *usize, out: *u8) bool {
    if (input[pos] != '&') return false;
    const remain = input[pos..];
    if (std.mem.startsWith(u8, remain, "&amp;")) {
        consumed.* = 5;
        out.* = '&';
        return true;
    }
    if (std.mem.startsWith(u8, remain, "&lt;")) {
        consumed.* = 4;
        out.* = '<';
        return true;
    }
    if (std.mem.startsWith(u8, remain, "&gt;")) {
        consumed.* = 4;
        out.* = '>';
        return true;
    }
    if (std.mem.startsWith(u8, remain, "&quot;")) {
        consumed.* = 6;
        out.* = '"';
        return true;
    }
    if (std.mem.startsWith(u8, remain, "&apos;")) {
        consumed.* = 6;
        out.* = '\'';
        return true;
    }
    if (std.mem.startsWith(u8, remain, "&nbsp;")) {
        consumed.* = 6;
        out.* = ' ';
        return true;
    }
    return false;
}

fn pushNormalizedText(parent_idx: usize, style: Style, input: []const u8) void {
    var i: usize = 0;
    const start = text_pool_len;
    var wrote_any = false;
    var need_space = false;

    while (i < input.len) {
        var ch = input[i];
        var consumed: usize = 0;
        if (ch == '&') {
            var decoded: u8 = 0;
            if (decodeEntity(input, i, &consumed, &decoded)) {
                ch = decoded;
                i += consumed;
            } else {
                i += 1;
            }
        } else {
            i += 1;
        }

        if (isSpace(ch)) {
            if (wrote_any) need_space = true;
            continue;
        }

        if (need_space) {
            appendByteToPool(' ');
            need_space = false;
        }
        appendByteToPool(ch);
        wrote_any = true;
    }

    if (!wrote_any) {
        text_pool_len = start;
        return;
    }

    const idx = newNode();
    nodes_buf[idx].kind = .text;
    nodes_buf[idx].tag = .unknown;
    nodes_buf[idx].style = style;
    nodes_buf[idx].text_start = @intCast(start);
    nodes_buf[idx].text_len = @intCast(text_pool_len - start);
    appendChild(parent_idx, idx);
}

fn baseStyleForTag(tag: Tag, parent_style: Style) Style {
    var style = Style{};
    style.inheritText(parent_style);

    switch (tag) {
        .root => {
            style.display = .block;
            style.padding_top = 24;
            style.padding_right = 24;
            style.padding_bottom = 24;
            style.padding_left = 24;
        },
        .body, .div, .section, .article, .header, .footer, .main, .nav => {
            style.display = .block;
            style.gap = 12;
        },
        .p => {
            style.display = .block;
            style.gap = 0;
            style.line_height = style.font_size * 1.45;
        },
        .span => {
            style.display = .inline;
        },
        .h1 => {
            style.display = .block;
            style.font_size = 40;
            style.line_height = 48;
            style.font_weight = 700;
        },
        .h2 => {
            style.display = .block;
            style.font_size = 32;
            style.line_height = 40;
            style.font_weight = 700;
        },
        .h3 => {
            style.display = .block;
            style.font_size = 26;
            style.line_height = 34;
            style.font_weight = 700;
        },
        .h4 => {
            style.display = .block;
            style.font_size = 22;
            style.line_height = 30;
            style.font_weight = 600;
        },
        .h5 => {
            style.display = .block;
            style.font_size = 20;
            style.line_height = 28;
            style.font_weight = 600;
        },
        .h6 => {
            style.display = .block;
            style.font_size = 18;
            style.line_height = 26;
            style.font_weight = 600;
        },
        .ul, .ol => {
            style.display = .block;
            style.gap = 8;
            style.padding_left = 24;
        },
        .li => {
            style.display = .block;
            style.gap = 4;
        },
        .a => {
            style.display = .inline;
            style.color_rgba = 0x2563ebff;
        },
        .img => {
            style.display = .block;
            style.width_px = 240;
            style.height_px = 140;
        },
        .br => {
            style.display = .inline;
        },
        .unknown => {
            style.display = .block;
        },
    }

    return style;
}

fn tailwindSpacing(token: []const u8) ?f32 {
    if (eqIgnoreCase(token, "0")) return 0;
    if (eqIgnoreCase(token, "0.5")) return 2;
    if (eqIgnoreCase(token, "1")) return 4;
    if (eqIgnoreCase(token, "1.5")) return 6;
    if (eqIgnoreCase(token, "2")) return 8;
    if (eqIgnoreCase(token, "2.5")) return 10;
    if (eqIgnoreCase(token, "3")) return 12;
    if (eqIgnoreCase(token, "4")) return 16;
    if (eqIgnoreCase(token, "5")) return 20;
    if (eqIgnoreCase(token, "6")) return 24;
    if (eqIgnoreCase(token, "8")) return 32;
    if (eqIgnoreCase(token, "10")) return 40;
    if (eqIgnoreCase(token, "12")) return 48;
    return null;
}

fn applyTailwindToken(style: *Style, token: []const u8, warnings: *u32) void {
    if (token.len == 0) return;

    if (eqIgnoreCase(token, "flex")) {
        style.display = .flex;
        return;
    }
    if (eqIgnoreCase(token, "flex-row")) {
        style.display = .flex;
        style.flex_direction = .row;
        return;
    }
    if (eqIgnoreCase(token, "flex-col")) {
        style.display = .flex;
        style.flex_direction = .column;
        return;
    }
    if (eqIgnoreCase(token, "flex-wrap")) {
        style.display = .flex;
        style.flex_wrap = true;
        return;
    }
    if (eqIgnoreCase(token, "flex-nowrap")) {
        style.display = .flex;
        style.flex_wrap = false;
        return;
    }
    if (eqIgnoreCase(token, "justify-start")) {
        style.justify = .start;
        return;
    }
    if (eqIgnoreCase(token, "justify-center")) {
        style.justify = .center;
        return;
    }
    if (eqIgnoreCase(token, "justify-end")) {
        style.justify = .end;
        return;
    }
    if (eqIgnoreCase(token, "justify-between")) {
        style.justify = .between;
        return;
    }
    if (eqIgnoreCase(token, "items-start")) {
        style.align = .start;
        return;
    }
    if (eqIgnoreCase(token, "items-center")) {
        style.align = .center;
        return;
    }
    if (eqIgnoreCase(token, "items-end")) {
        style.align = .end;
        return;
    }
    if (eqIgnoreCase(token, "items-stretch")) {
        style.align = .stretch;
        return;
    }

    if (startsWithIgnoreCase(token, "gap-")) {
        const v = token[4..];
        if (tailwindSpacing(v)) |px| {
            style.gap = px;
        } else {
            warnings.* += 1;
        }
        return;
    }

    if (startsWithIgnoreCase(token, "p-")) {
        const v = token[2..];
        if (tailwindSpacing(v)) |px| {
            style.padding_top = px;
            style.padding_right = px;
            style.padding_bottom = px;
            style.padding_left = px;
        } else {
            warnings.* += 1;
        }
        return;
    }

    if (startsWithIgnoreCase(token, "px-")) {
        const v = token[3..];
        if (tailwindSpacing(v)) |px| {
            style.padding_left = px;
            style.padding_right = px;
        } else {
            warnings.* += 1;
        }
        return;
    }

    if (startsWithIgnoreCase(token, "py-")) {
        const v = token[3..];
        if (tailwindSpacing(v)) |px| {
            style.padding_top = px;
            style.padding_bottom = px;
        } else {
            warnings.* += 1;
        }
        return;
    }

    if (eqIgnoreCase(token, "text-xs")) {
        style.font_size = 12;
        style.line_height = 18;
        return;
    }
    if (eqIgnoreCase(token, "text-sm")) {
        style.font_size = 14;
        style.line_height = 20;
        return;
    }
    if (eqIgnoreCase(token, "text-base")) {
        style.font_size = 16;
        style.line_height = 22;
        return;
    }
    if (eqIgnoreCase(token, "text-lg")) {
        style.font_size = 18;
        style.line_height = 26;
        return;
    }
    if (eqIgnoreCase(token, "text-xl")) {
        style.font_size = 20;
        style.line_height = 28;
        return;
    }
    if (eqIgnoreCase(token, "text-2xl")) {
        style.font_size = 24;
        style.line_height = 32;
        return;
    }

    if (eqIgnoreCase(token, "font-normal")) {
        style.font_weight = 400;
        return;
    }
    if (eqIgnoreCase(token, "font-medium")) {
        style.font_weight = 500;
        return;
    }
    if (eqIgnoreCase(token, "font-semibold")) {
        style.font_weight = 600;
        return;
    }
    if (eqIgnoreCase(token, "font-bold")) {
        style.font_weight = 700;
        return;
    }

    if (eqIgnoreCase(token, "text-black")) {
        style.color_rgba = 0x000000ff;
        return;
    }
    if (eqIgnoreCase(token, "text-white")) {
        style.color_rgba = 0xffffffff;
        return;
    }
    if (eqIgnoreCase(token, "text-gray-500")) {
        style.color_rgba = 0x6b7280ff;
        return;
    }
    if (eqIgnoreCase(token, "text-red-500")) {
        style.color_rgba = 0xef4444ff;
        return;
    }
    if (eqIgnoreCase(token, "text-blue-600")) {
        style.color_rgba = 0x2563ebff;
        return;
    }
    if (eqIgnoreCase(token, "text-green-600")) {
        style.color_rgba = 0x16a34aff;
        return;
    }

    // Warn only on tailwind-like utilities we intentionally parse in this prototype.
    if (startsWithIgnoreCase(token, "flex-") or
        startsWithIgnoreCase(token, "justify-") or
        startsWithIgnoreCase(token, "items-") or
        startsWithIgnoreCase(token, "gap-") or
        startsWithIgnoreCase(token, "p-") or
        startsWithIgnoreCase(token, "px-") or
        startsWithIgnoreCase(token, "py-") or
        startsWithIgnoreCase(token, "text-") or
        startsWithIgnoreCase(token, "font-"))
    {
        warnings.* += 1;
    }
}

fn applyClassList(style: *Style, value: []const u8, warnings: *u32) void {
    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and isSpace(value[i])) : (i += 1) {}
        if (i >= value.len) break;
        const start = i;
        while (i < value.len and !isSpace(value[i])) : (i += 1) {}
        const token = value[start..i];
        applyTailwindToken(style, token, warnings);
    }
}

fn applyInlineStyle(style: *Style, value: []const u8) void {
    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and (isSpace(value[i]) or value[i] == ';')) : (i += 1) {}
        if (i >= value.len) break;

        const key_start = i;
        while (i < value.len and value[i] != ':' and value[i] != ';') : (i += 1) {}
        if (i >= value.len or value[i] != ':') {
            while (i < value.len and value[i] != ';') : (i += 1) {}
            continue;
        }
        const key = value[key_start..i];
        i += 1;
        const value_start = i;
        while (i < value.len and value[i] != ';') : (i += 1) {}
        const val = value[value_start..i];

        if (eqIgnoreCase(std.mem.trim(u8, key, " \t\r\n"), "display")) {
            const t = std.mem.trim(u8, val, " \t\r\n");
            if (eqIgnoreCase(t, "flex")) style.display = .flex;
            if (eqIgnoreCase(t, "block")) style.display = .block;
            if (eqIgnoreCase(t, "inline")) style.display = .inline;
        } else if (eqIgnoreCase(std.mem.trim(u8, key, " \t\r\n"), "flex-direction")) {
            const t = std.mem.trim(u8, val, " \t\r\n");
            if (eqIgnoreCase(t, "column")) style.flex_direction = .column;
            if (eqIgnoreCase(t, "row")) style.flex_direction = .row;
        } else if (eqIgnoreCase(std.mem.trim(u8, key, " \t\r\n"), "flex-wrap")) {
            const t = std.mem.trim(u8, val, " \t\r\n");
            if (eqIgnoreCase(t, "wrap")) style.flex_wrap = true;
            if (eqIgnoreCase(t, "nowrap")) style.flex_wrap = false;
        } else if (eqIgnoreCase(std.mem.trim(u8, key, " \t\r\n"), "justify-content")) {
            const t = std.mem.trim(u8, val, " \t\r\n");
            if (eqIgnoreCase(t, "center")) style.justify = .center;
            if (eqIgnoreCase(t, "flex-end")) style.justify = .end;
            if (eqIgnoreCase(t, "space-between")) style.justify = .between;
            if (eqIgnoreCase(t, "flex-start")) style.justify = .start;
        } else if (eqIgnoreCase(std.mem.trim(u8, key, " \t\r\n"), "align-items")) {
            const t = std.mem.trim(u8, val, " \t\r\n");
            if (eqIgnoreCase(t, "center")) style.align = .center;
            if (eqIgnoreCase(t, "flex-end")) style.align = .end;
            if (eqIgnoreCase(t, "stretch")) style.align = .stretch;
            if (eqIgnoreCase(t, "flex-start")) style.align = .start;
        } else if (eqIgnoreCase(std.mem.trim(u8, key, " \t\r\n"), "gap")) {
            if (parsePxValue(val)) |px| style.gap = px;
        } else if (eqIgnoreCase(std.mem.trim(u8, key, " \t\r\n"), "padding")) {
            if (parsePxValue(val)) |px| {
                style.padding_top = px;
                style.padding_right = px;
                style.padding_bottom = px;
                style.padding_left = px;
            }
        } else if (eqIgnoreCase(std.mem.trim(u8, key, " \t\r\n"), "padding-left")) {
            if (parsePxValue(val)) |px| style.padding_left = px;
        } else if (eqIgnoreCase(std.mem.trim(u8, key, " \t\r\n"), "padding-right")) {
            if (parsePxValue(val)) |px| style.padding_right = px;
        } else if (eqIgnoreCase(std.mem.trim(u8, key, " \t\r\n"), "padding-top")) {
            if (parsePxValue(val)) |px| style.padding_top = px;
        } else if (eqIgnoreCase(std.mem.trim(u8, key, " \t\r\n"), "padding-bottom")) {
            if (parsePxValue(val)) |px| style.padding_bottom = px;
        } else if (eqIgnoreCase(std.mem.trim(u8, key, " \t\r\n"), "font-size")) {
            if (parsePxValue(val)) |px| {
                style.font_size = px;
                style.line_height = px * 1.35;
            }
        } else if (eqIgnoreCase(std.mem.trim(u8, key, " \t\r\n"), "line-height")) {
            if (parsePxValue(val)) |px| style.line_height = px;
        } else if (eqIgnoreCase(std.mem.trim(u8, key, " \t\r\n"), "font-weight")) {
            const t = std.mem.trim(u8, val, " \t\r\n");
            if (parseUnsignedInt(t)) |n| {
                style.font_weight = @intCast(@min(n, 900));
            } else if (eqIgnoreCase(t, "bold")) {
                style.font_weight = 700;
            } else if (eqIgnoreCase(t, "normal")) {
                style.font_weight = 400;
            }
        } else if (eqIgnoreCase(std.mem.trim(u8, key, " \t\r\n"), "color")) {
            if (parseCssColor(val)) |c| style.color_rgba = c;
        } else if (eqIgnoreCase(std.mem.trim(u8, key, " \t\r\n"), "width")) {
            if (parsePxValue(val)) |px| style.width_px = px;
        } else if (eqIgnoreCase(std.mem.trim(u8, key, " \t\r\n"), "height")) {
            if (parsePxValue(val)) |px| style.height_px = px;
        }

        if (i < value.len and value[i] == ';') i += 1;
    }
}

fn parseHtml(input: []const u8) ParseResult {
    nodes_len = 0;
    text_pool_len = 0;

    const root_idx = newNode();
    nodes_buf[root_idx].tag = .root;
    nodes_buf[root_idx].kind = .element;
    nodes_buf[root_idx].style = baseStyleForTag(.root, Style{});

    var stack_nodes: [MAX_STACK]usize = undefined;
    var stack_tags: [MAX_STACK]Tag = undefined;
    var sp: usize = 0;
    stack_nodes[sp] = root_idx;
    stack_tags[sp] = .root;
    sp += 1;

    var warnings: u32 = 0;

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '<') {
            const text_start = i;
            while (i < input.len and input[i] != '<') : (i += 1) {}
            const parent_idx = stack_nodes[sp - 1];
            const parent_style = nodes_buf[parent_idx].style;
            pushNormalizedText(parent_idx, parent_style, input[text_start..i]);
            continue;
        }

        // Comments
        if (i + 3 < input.len and std.mem.eql(u8, input[i .. @min(i + 4, input.len)], "<!--")) {
            i += 4;
            while (i + 2 < input.len and !std.mem.eql(u8, input[i .. i + 3], "-->")) : (i += 1) {}
            if (i + 2 >= input.len) @trap();
            i += 3;
            continue;
        }

        // End tags
        if (i + 1 < input.len and input[i + 1] == '/') {
            i += 2;
            while (i < input.len and isSpace(input[i])) : (i += 1) {}
            const name_start = i;
            while (i < input.len and isNameChar(input[i])) : (i += 1) {}
            const name = input[name_start..i];
            while (i < input.len and input[i] != '>') : (i += 1) {}
            if (i >= input.len) @trap();
            i += 1;

            const closing_tag = mapTag(name);
            if (sp <= 1) @trap();
            var found = false;
            var j = sp;
            while (j > 1) {
                j -= 1;
                if (stack_tags[j] == closing_tag) {
                    sp = j;
                    found = true;
                    break;
                }
            }
            if (!found) @trap();
            continue;
        }

        // Start tag
        i += 1;
        while (i < input.len and isSpace(input[i])) : (i += 1) {}
        const name_start = i;
        while (i < input.len and isNameChar(input[i])) : (i += 1) {}
        if (name_start == i) @trap();
        const name = input[name_start..i];
        const tag = mapTag(name);

        const parent_idx = stack_nodes[sp - 1];
        const parent_style = nodes_buf[parent_idx].style;
        var style = baseStyleForTag(tag, parent_style);

        var has_href = false;
        var img_alt_start: usize = 0;
        var img_alt_len: usize = 0;

        var self_closing = false;
        while (i < input.len) {
            while (i < input.len and isSpace(input[i])) : (i += 1) {}
            if (i >= input.len) @trap();
            if (input[i] == '>') {
                i += 1;
                break;
            }
            if (input[i] == '/' and i + 1 < input.len and input[i + 1] == '>') {
                self_closing = true;
                i += 2;
                break;
            }

            const key_start = i;
            while (i < input.len and isNameChar(input[i])) : (i += 1) {}
            const key = input[key_start..i];
            while (i < input.len and isSpace(input[i])) : (i += 1) {}

            var value: []const u8 = "";
            if (i < input.len and input[i] == '=') {
                i += 1;
                while (i < input.len and isSpace(input[i])) : (i += 1) {}
                if (i >= input.len) @trap();
                if (input[i] == '"' or input[i] == '\'') {
                    const quote = input[i];
                    i += 1;
                    const v_start = i;
                    while (i < input.len and input[i] != quote) : (i += 1) {}
                    if (i >= input.len) @trap();
                    value = input[v_start..i];
                    i += 1;
                } else {
                    const v_start = i;
                    while (i < input.len and !isSpace(input[i]) and input[i] != '>') : (i += 1) {}
                    value = input[v_start..i];
                }
            }

            if (eqIgnoreCase(key, "class")) {
                applyClassList(&style, value, &warnings);
            } else if (eqIgnoreCase(key, "style")) {
                applyInlineStyle(&style, value);
            } else if (eqIgnoreCase(key, "href")) {
                has_href = value.len > 0;
            } else if (eqIgnoreCase(key, "width")) {
                if (parsePxValue(value)) |px| style.width_px = px;
            } else if (eqIgnoreCase(key, "height")) {
                if (parsePxValue(value)) |px| style.height_px = px;
            } else if (eqIgnoreCase(key, "alt")) {
                img_alt_start = writeTextToPool(value);
                img_alt_len = value.len;
            }
        }

        const idx = newNode();
        nodes_buf[idx].tag = tag;
        nodes_buf[idx].kind = if (tag == .img) .image else if (tag == .br) .br else .element;
        nodes_buf[idx].style = style;
        nodes_buf[idx].has_href = has_href;
        if (tag == .img and img_alt_len > 0) {
            nodes_buf[idx].text_start = @intCast(img_alt_start);
            nodes_buf[idx].text_len = @intCast(img_alt_len);
        }

        appendChild(parent_idx, idx);

        if (tag == .a and has_href) nodes_buf[idx].style.color_rgba = 0x2563ebff;

        if (!self_closing and !isVoidTag(tag)) {
            if (sp >= MAX_STACK) @trap();
            stack_nodes[sp] = idx;
            stack_tags[sp] = tag;
            sp += 1;
        }
    }

    if (sp != 1) @trap();

    // Assign ordered list item indices.
    var n: usize = 0;
    while (n < nodes_len) : (n += 1) {
        if (nodes_buf[n].tag == .ol) {
            var k: u16 = 1;
            var child_i = nodes_buf[n].first_child;
            while (child_i >= 0) {
                const ci: usize = @intCast(child_i);
                if (nodes_buf[ci].tag == .li) {
                    nodes_buf[ci].list_index = k;
                    if (k < std.math.maxInt(u16)) k += 1;
                }
                child_i = nodes_buf[ci].next_sibling;
            }
        }
    }

    return .{ .root_idx = root_idx, .warnings = warnings };
}

fn appendDrawOp(op: DrawOp) void {
    if (draw_ops_len >= MAX_OPS) @trap();
    draw_ops[draw_ops_len] = op;
    draw_ops_len += 1;
}

fn estimateTextWidth(text: []const u8, font_size: f32) f32 {
    if (text.len == 0) return 0;
    return @as(f32, @floatFromInt(text.len)) * font_size * 0.58;
}

fn blockGapForTag(tag: Tag) f32 {
    return switch (tag) {
        .h1, .h2, .h3, .h4, .h5, .h6 => 14,
        .p, .li => 8,
        else => 10,
    };
}

fn layoutTextNode(node_idx: usize, x: f32, y: f32, width: f32, emit: bool) LayoutSize {
    const node = nodes_buf[node_idx];
    const style = node.style;
    const raw = text_pool[node.text_start .. node.text_start + node.text_len];
    if (raw.len == 0) return .{ .width = 0, .height = 0 };

    const fs = if (style.font_size < 8) 8 else style.font_size;
    const lh = if (style.line_height < fs) fs * 1.2 else style.line_height;
    const max_w = if (width < 24) 24 else width;

    var start: usize = 0;
    var line_count: u32 = 0;

    while (start < raw.len) {
        var end = start;
        var best_end = start;
        var best_w: f32 = 0;
        while (end < raw.len) {
            if (raw[end] == ' ') {
                const part = raw[start..end];
                const w = estimateTextWidth(part, fs);
                if (w <= max_w) {
                    best_end = end;
                    best_w = w;
                }
            }
            const full = raw[start .. end + 1];
            const full_w = estimateTextWidth(full, fs);
            if (full_w > max_w) break;
            best_end = end + 1;
            best_w = full_w;
            end += 1;
        }

        if (best_end == start) {
            best_end = @min(start + 1, raw.len);
            best_w = estimateTextWidth(raw[start..best_end], fs);
        }

        var line = raw[start..best_end];
        line = std.mem.trimRight(u8, line, " ");
        if (line.len == 0 and best_end < raw.len) {
            start = best_end + 1;
            continue;
        }

        if (emit and line.len > 0) {
            appendDrawOp(.{
                .kind = .text,
                .x = x,
                .y = y + @as(f32, @floatFromInt(line_count)) * lh + fs,
                .w = best_w,
                .h = lh,
                .color_rgba = style.color_rgba,
                .font_size = fs,
                .font_weight = style.font_weight,
                .text_start = @intCast(line.ptr - &text_pool[0]),
                .text_len = @intCast(line.len),
            });
        }

        line_count += 1;
        if (best_end >= raw.len) break;
        start = best_end;
        while (start < raw.len and raw[start] == ' ') : (start += 1) {}
    }

    return .{ .width = max_w, .height = @as(f32, @floatFromInt(line_count)) * lh };
}

fn measureNode(node_idx: usize, width: f32, depth: usize) LayoutSize {
    if (depth > MAX_LAYOUT_DEPTH) @trap();
    const node = nodes_buf[node_idx];

    switch (node.kind) {
        .text => return layoutTextNode(node_idx, 0, 0, width, false),
        .br => return .{ .width = width, .height = node.style.line_height },
        .image => {
            const w = if (node.style.width_px > 0) @min(node.style.width_px, width) else @min(width, 240);
            const h = if (node.style.height_px > 0) node.style.height_px else 140;
            return .{ .width = w, .height = h };
        },
        .element => {},
    }

    const style = node.style;
    const content_w = @max(1, width - style.padding_left - style.padding_right);

    var h: f32 = style.padding_top + style.padding_bottom;

    if (node.first_child < 0) {
        if (node.tag == .p or node.tag == .li) {
            h += style.line_height;
        }
        return .{ .width = width, .height = h };
    }

    if (style.display == .flex and style.flex_direction == .row) {
        var line_width: f32 = 0;
        var line_height: f32 = 0;
        var total_cross: f32 = 0;
        var child_i = node.first_child;
        while (child_i >= 0) {
            const ci: usize = @intCast(child_i);
            var child_w = content_w;
            if (nodes_buf[ci].style.width_px > 0) child_w = @min(content_w, nodes_buf[ci].style.width_px);
            const m = measureNode(ci, child_w, depth + 1);
            const item_w = if (nodes_buf[ci].style.width_px > 0) @min(content_w, nodes_buf[ci].style.width_px) else @min(content_w, @max(60, m.width));

            const gap = if (line_width > 0) style.gap else 0;
            const next = line_width + gap + item_w;
            if (style.flex_wrap and line_width > 0 and next > content_w) {
                total_cross += line_height;
                if (total_cross > 0) total_cross += style.gap;
                line_width = item_w;
                line_height = m.height;
            } else {
                line_width = next;
                if (m.height > line_height) line_height = m.height;
            }

            child_i = nodes_buf[ci].next_sibling;
        }
        total_cross += line_height;
        h += total_cross;
        return .{ .width = width, .height = h };
    }

    if (style.display == .flex and style.flex_direction == .column) {
        var child_i = node.first_child;
        var first = true;
        while (child_i >= 0) {
            const ci: usize = @intCast(child_i);
            const m = measureNode(ci, content_w, depth + 1);
            if (!first) h += style.gap;
            h += m.height;
            first = false;
            child_i = nodes_buf[ci].next_sibling;
        }
        return .{ .width = width, .height = h };
    }

    var child_i = node.first_child;
    var first = true;
    while (child_i >= 0) {
        const ci: usize = @intCast(child_i);
        var child_w = content_w;
        if (nodes_buf[ci].style.width_px > 0) child_w = @min(child_w, nodes_buf[ci].style.width_px);
        const m = measureNode(ci, child_w, depth + 1);
        if (!first) h += if (style.gap > 0) style.gap else blockGapForTag(nodes_buf[ci].tag);
        h += m.height;
        first = false;
        child_i = nodes_buf[ci].next_sibling;
    }

    return .{ .width = width, .height = h };
}

fn layoutNode(node_idx: usize, x: f32, y: f32, width: f32, depth: usize, emit: bool) LayoutSize {
    if (depth > MAX_LAYOUT_DEPTH) @trap();
    const node = nodes_buf[node_idx];

    switch (node.kind) {
        .text => return layoutTextNode(node_idx, x, y, width, emit),
        .br => return .{ .width = width, .height = node.style.line_height },
        .image => {
            const w = if (node.style.width_px > 0) @min(node.style.width_px, width) else @min(width, 240);
            const h = if (node.style.height_px > 0) node.style.height_px else 140;
            if (emit) {
                appendDrawOp(.{
                    .kind = .rect,
                    .x = x,
                    .y = y,
                    .w = w,
                    .h = h,
                    .color_rgba = 0xe5e7ebff,
                    .font_size = 0,
                    .font_weight = 0,
                    .text_start = 0,
                    .text_len = 0,
                });

                if (node.text_len > 0) {
                    const alt_w = w - 16;
                    if (alt_w > 24) {
                        _ = layoutTextNodeFromSlice(
                            text_pool[node.text_start .. node.text_start + node.text_len],
                            node.style,
                            x + 8,
                            y + 8,
                            alt_w,
                            emit,
                        );
                    }
                }
            }
            return .{ .width = w, .height = h };
        },
        .element => {},
    }

    const style = node.style;
    const content_x = x + style.padding_left;
    const content_y = y + style.padding_top;
    const content_w = @max(1, width - style.padding_left - style.padding_right);

    var total_h = style.padding_top + style.padding_bottom;

    if (node.first_child < 0) {
        return .{ .width = width, .height = total_h };
    }

    if (style.display == .flex and style.flex_direction == .row) {
        var line_indices: [MAX_FLEX_LINE_ITEMS]usize = undefined;
        var line_widths: [MAX_FLEX_LINE_ITEMS]f32 = undefined;
        var line_heights: [MAX_FLEX_LINE_ITEMS]f32 = undefined;
        var line_count: usize = 0;

        var cursor_y: f32 = content_y;
        var child_i = node.first_child;

        while (child_i >= 0) {
            const ci: usize = @intCast(child_i);
            var child_w = content_w;
            if (nodes_buf[ci].style.width_px > 0) child_w = @min(content_w, nodes_buf[ci].style.width_px);
            const m = measureNode(ci, child_w, depth + 1);
            const item_w = if (nodes_buf[ci].style.width_px > 0) @min(content_w, nodes_buf[ci].style.width_px) else @min(content_w, @max(60, m.width));
            const item_h = m.height;

            const current_main = blk: {
                var sum: f32 = 0;
                var n: usize = 0;
                while (n < line_count) : (n += 1) {
                    if (n > 0) sum += style.gap;
                    sum += line_widths[n];
                }
                break :blk sum;
            };

            const next_main = if (line_count == 0) item_w else current_main + style.gap + item_w;
            if (style.flex_wrap and line_count > 0 and next_main > content_w) {
                const line_height = maxOf(line_heights[0..line_count]);
                layoutFlexLine(
                    line_indices[0..line_count],
                    line_widths[0..line_count],
                    line_heights[0..line_count],
                    content_x,
                    cursor_y,
                    content_w,
                    style,
                    depth,
                    emit,
                );
                cursor_y += line_height + style.gap;
                line_count = 0;
            }

            if (line_count >= MAX_FLEX_LINE_ITEMS) @trap();
            line_indices[line_count] = ci;
            line_widths[line_count] = item_w;
            line_heights[line_count] = item_h;
            line_count += 1;

            child_i = nodes_buf[ci].next_sibling;
        }

        if (line_count > 0) {
            const line_height = maxOf(line_heights[0..line_count]);
            layoutFlexLine(
                line_indices[0..line_count],
                line_widths[0..line_count],
                line_heights[0..line_count],
                content_x,
                cursor_y,
                content_w,
                style,
                depth,
                emit,
            );
            cursor_y += line_height;
        }

        total_h += cursor_y - content_y;
        return .{ .width = width, .height = total_h };
    }

    if (style.display == .flex and style.flex_direction == .column) {
        var cursor_y = content_y;
        var first = true;
        var child_i = node.first_child;
        while (child_i >= 0) {
            const ci: usize = @intCast(child_i);
            var child_w = content_w;
            if (nodes_buf[ci].style.width_px > 0) child_w = @min(child_w, nodes_buf[ci].style.width_px);
            if (!first) cursor_y += style.gap;
            const h = layoutNode(ci, content_x, cursor_y, child_w, depth + 1, emit).height;
            cursor_y += h;
            first = false;
            child_i = nodes_buf[ci].next_sibling;
        }
        total_h += cursor_y - content_y;
        return .{ .width = width, .height = total_h };
    }

    // Block flow
    var cursor_y = content_y;
    var first = true;
    var child_i = node.first_child;
    while (child_i >= 0) {
        const ci: usize = @intCast(child_i);
        if (!first) cursor_y += if (style.gap > 0) style.gap else blockGapForTag(nodes_buf[ci].tag);

        var child_x = content_x;
        var child_w = content_w;

        if (node.tag == .ul or node.tag == .ol) {
            if (nodes_buf[ci].tag == .li) {
                const marker = if (node.tag == .ul) "•" else blk: {
                    var tmp: [8]u8 = undefined;
                    const s = std.fmt.bufPrint(&tmp, "{d}.", .{nodes_buf[ci].list_index}) catch "1.";
                    const marker_start = writeTextToPool(s);
                    appendDrawOp(.{
                        .kind = .text,
                        .x = content_x - 18,
                        .y = cursor_y + nodes_buf[ci].style.font_size,
                        .w = 14,
                        .h = nodes_buf[ci].style.line_height,
                        .color_rgba = nodes_buf[ci].style.color_rgba,
                        .font_size = nodes_buf[ci].style.font_size,
                        .font_weight = nodes_buf[ci].style.font_weight,
                        .text_start = marker_start,
                        .text_len = @intCast(s.len),
                    });
                    break :blk "";
                };
                if (node.tag == .ul and emit) {
                    const marker_start = writeTextToPool(marker);
                    appendDrawOp(.{
                        .kind = .text,
                        .x = content_x - 16,
                        .y = cursor_y + nodes_buf[ci].style.font_size,
                        .w = 10,
                        .h = nodes_buf[ci].style.line_height,
                        .color_rgba = nodes_buf[ci].style.color_rgba,
                        .font_size = nodes_buf[ci].style.font_size,
                        .font_weight = nodes_buf[ci].style.font_weight,
                        .text_start = marker_start,
                        .text_len = @intCast(marker.len),
                    });
                }
            }
        }

        if (nodes_buf[ci].style.width_px > 0) child_w = @min(child_w, nodes_buf[ci].style.width_px);
        const h = layoutNode(ci, child_x, cursor_y, child_w, depth + 1, emit).height;
        cursor_y += h;

        first = false;
        child_i = nodes_buf[ci].next_sibling;
    }

    total_h += cursor_y - content_y;
    return .{ .width = width, .height = total_h };
}

fn layoutTextNodeFromSlice(slice: []const u8, style: Style, x: f32, y: f32, width: f32, emit: bool) LayoutSize {
    const start = writeTextToPool(slice);
    const idx = newNode();
    nodes_buf[idx].kind = .text;
    nodes_buf[idx].tag = .unknown;
    nodes_buf[idx].style = style;
    nodes_buf[idx].text_start = start;
    nodes_buf[idx].text_len = @intCast(slice.len);
    return layoutTextNode(idx, x, y, width, emit);
}

fn maxOf(values: []const f32) f32 {
    if (values.len == 0) return 0;
    var m = values[0];
    var i: usize = 1;
    while (i < values.len) : (i += 1) if (values[i] > m) m = values[i];
    return m;
}

fn layoutFlexLine(indices: []const usize, widths: []const f32, heights: []const f32, x: f32, y: f32, width: f32, style: Style, depth: usize, emit: bool) void {
    if (indices.len == 0) return;

    var used: f32 = 0;
    var i: usize = 0;
    while (i < widths.len) : (i += 1) {
        if (i > 0) used += style.gap;
        used += widths[i];
    }

    var start_x = x;
    var gap = style.gap;

    if (style.justify == .center) {
        start_x = x + @max(0, (width - used) / 2);
    } else if (style.justify == .end) {
        start_x = x + @max(0, width - used);
    } else if (style.justify == .between and indices.len > 1 and width > used) {
        const extra = width - used;
        gap = style.gap + extra / @as(f32, @floatFromInt(indices.len - 1));
    }

    const line_h = maxOf(heights);
    var cursor_x = start_x;
    i = 0;
    while (i < indices.len) : (i += 1) {
        const child_idx = indices[i];
        const child_h = heights[i];
        var child_y = y;
        switch (style.align) {
            .start, .stretch => {},
            .center => child_y = y + @max(0, (line_h - child_h) / 2),
            .end => child_y = y + @max(0, line_h - child_h),
        }

        var child_w = widths[i];
        if (style.align == .stretch and nodes_buf[child_idx].style.height_px <= 0) {
            _ = line_h;
        }

        _ = layoutNode(child_idx, cursor_x, child_y, child_w, depth + 1, emit);
        cursor_x += child_w + gap;
    }
}

fn writeEscapedXml(writer: *Writer, raw: []const u8) !void {
    for (raw) |c| {
        switch (c) {
            '&' => try writer.writeSlice("&amp;"),
            '<' => try writer.writeSlice("&lt;"),
            '>' => try writer.writeSlice("&gt;"),
            '"' => try writer.writeSlice("&quot;"),
            '\'' => try writer.writeSlice("&apos;"),
            else => try writer.writeByte(c),
        }
    }
}

fn emitSvg(warnings: u32) !u32 {
    var w = Writer{};

    try w.writeSlice("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"");
    try w.writeFmt("{d}", .{canvas_width});
    try w.writeSlice("\" height=\"");
    try w.writeFmt("{d}", .{canvas_height});
    try w.writeSlice("\" viewBox=\"0 0 ");
    try w.writeFmt("{d}", .{canvas_width});
    try w.writeByte(' ');
    try w.writeFmt("{d}", .{canvas_height});
    try w.writeSlice("\" data-qip-tailwind-warnings=\"");
    try w.writeFmt("{d}", .{warnings});
    try w.writeSlice("\">");

    try w.writeSlice("<metadata>qip-tailwind-warnings=");
    try w.writeFmt("{d}", .{warnings});
    try w.writeSlice("</metadata>");

    try w.writeSlice("<rect x=\"0\" y=\"0\" width=\"");
    try w.writeFmt("{d}", .{canvas_width});
    try w.writeSlice("\" height=\"");
    try w.writeFmt("{d}", .{canvas_height});
    try w.writeSlice("\" fill=\"#ffffff\"/>");

    var i: usize = 0;
    while (i < draw_ops_len) : (i += 1) {
        const op = draw_ops[i];
        const c = colorRgb(op.color_rgba);

        if (op.kind == .rect) {
            try w.writeSlice("<rect x=\"");
            try w.writeFmt("{d:.2}", .{op.x});
            try w.writeSlice("\" y=\"");
            try w.writeFmt("{d:.2}", .{op.y});
            try w.writeSlice("\" width=\"");
            try w.writeFmt("{d:.2}", .{op.w});
            try w.writeSlice("\" height=\"");
            try w.writeFmt("{d:.2}", .{op.h});
            try w.writeSlice("\" fill=\"rgba(");
            try w.writeFmt("{d},{d},{d},{d:.3}", .{ c.r, c.g, c.b, @as(f32, @floatFromInt(c.a)) / 255.0 });
            try w.writeSlice(")\"/>");
            continue;
        }

        const text = text_pool[op.text_start .. op.text_start + op.text_len];
        try w.writeSlice("<text x=\"");
        try w.writeFmt("{d:.2}", .{op.x});
        try w.writeSlice("\" y=\"");
        try w.writeFmt("{d:.2}", .{op.y});
        try w.writeSlice("\" font-size=\"");
        try w.writeFmt("{d:.2}", .{op.font_size});
        try w.writeSlice("\" font-weight=\"");
        try w.writeFmt("{d}", .{op.font_weight});
        try w.writeSlice("\" font-family=\"Inter, system-ui, -apple-system, Segoe UI, sans-serif\" fill=\"rgba(");
        try w.writeFmt("{d},{d},{d},{d:.3}", .{ c.r, c.g, c.b, @as(f32, @floatFromInt(c.a)) / 255.0 });
        try w.writeSlice(")\">");
        try writeEscapedXml(&w, text);
        try w.writeSlice("</text>");
    }

    try w.writeSlice("</svg>");
    return @intCast(w.idx);
}

export fn run(input_size_in: u32) u32 {
    draw_ops_len = 0;

    const input_size: usize = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    const input = input_buf[0..input_size];

    const parsed = parseHtml(input);

    const root_width = @as(f32, @floatFromInt(canvas_width));
    _ = layoutNode(parsed.root_idx, 0, 0, root_width, 0, true);

    return emitSvg(parsed.warnings) catch @trap();
}

fn runFixture(html: []const u8) []const u8 {
    @memcpy(input_buf[0..html.len], html);
    const out_len = run(@intCast(html.len));
    return output_buf[0..out_len];
}

test "tailwind unsupported utility increments warning metadata" {
    const html = "<div class='flex items-center gap-4 text-3xl'>hello</div>";
    const out = runFixture(html);
    try std.testing.expect(std.mem.indexOf(u8, out, "qip-tailwind-warnings=1") != null);
}

test "fixture snapshot cards layout" {
    const html = @embedFile("../../../test/fixtures/html-to-svg/cards.html");
    const out = runFixture(html);
    try std.testing.expect(std.mem.startsWith(u8, out, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, out, "qip-tailwind-warnings=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Cards") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Card A") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Card B") != null);
}

test "fixture snapshot navbar layout" {
    const html = @embedFile("../../../test/fixtures/html-to-svg/navbar.html");
    const out = runFixture(html);
    try std.testing.expect(std.mem.indexOf(u8, out, "qip-tailwind-warnings=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "qip") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Home") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Docs") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "GitHub") != null);
}

test "fixture dashboard resolves conflicting text-sm and text-3xl deterministically" {
    const html = @embedFile("../../../test/fixtures/html-to-svg/dashboard.html");
    const out = runFixture(html);
    try std.testing.expect(std.mem.indexOf(u8, out, "qip-tailwind-warnings=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Dashboard") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Users 128") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Build 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Healthy") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "font-size=\"14.00\" font-weight=\"400\" font-family=\"Inter, system-ui, -apple-system, Segoe UI, sans-serif\" fill=\"rgba(31,41,55,1.000)\">Conflicting Text Sizes</text>") != null);
}
