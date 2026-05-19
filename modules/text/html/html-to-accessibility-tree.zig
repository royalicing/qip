const std = @import("std");

const INPUT_CAP: usize = 256 * 1024;
const OUTPUT_CAP: usize = 1024 * 1024;
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "text/markdown";

const MAX_NODES: usize = 1024;
const MAX_STACK: usize = 2048;
const MAX_NAME_LEN: usize = 192;
const MAX_ROLE_LEN: usize = 31;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var nodes_buf: [MAX_NODES]Node = undefined;
var frames_buf: [MAX_STACK]Frame = undefined;

const RoleKind = enum(u8) {
    custom,
    link,
    button,
    heading,
    image,
    textbox,
    checkbox,
    radio,
    slider,
    combobox,
    option,
    list,
    listitem,
    main,
    navigation,
    banner,
    contentinfo,
    region,
    article,
    complementary,
    form,
    table,
    row,
    columnheader,
    cell,
    dialog,
    paragraph,
};

const Node = struct {
    parent: i32 = -1,
    depth: u16 = 0,
    role: RoleKind = .custom,
    custom_role: [MAX_ROLE_LEN]u8 = undefined,
    custom_role_len: u8 = 0,
    name: [MAX_NAME_LEN]u8 = undefined,
    name_len: u16 = 0,
    name_locked: bool = false,
    needs_space: bool = false,
};

const Frame = struct {
    tag_start: u32,
    tag_len: u16,
    node_index: i32,
    hidden: bool,
    suppress_text: bool,
};

const RoleSpec = struct {
    role: ?RoleKind = null,
    custom: [MAX_ROLE_LEN]u8 = undefined,
    custom_len: u8 = 0,
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

fn asciiLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (asciiLower(x) != asciiLower(y)) return false;
    }
    return true;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == 0x0C;
}

fn isNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == ':';
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn hexValue(c: u8) u32 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    return c - 'A' + 10;
}

fn isSpaceCodepoint(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\r' or cp == '\n' or cp == 0x0C or cp == 0xA0;
}

fn roleLabel(node: *const Node) []const u8 {
    return switch (node.role) {
        .custom => node.custom_role[0..node.custom_role_len],
        .link => "link",
        .button => "button",
        .heading => "heading",
        .image => "image",
        .textbox => "textbox",
        .checkbox => "checkbox",
        .radio => "radio",
        .slider => "slider",
        .combobox => "combobox",
        .option => "option",
        .list => "list",
        .listitem => "listitem",
        .main => "main",
        .navigation => "navigation",
        .banner => "banner",
        .contentinfo => "contentinfo",
        .region => "region",
        .article => "article",
        .complementary => "complementary",
        .form => "form",
        .table => "table",
        .row => "row",
        .columnheader => "columnheader",
        .cell => "cell",
        .dialog => "dialog",
        .paragraph => "paragraph",
    };
}

fn appendNodeByte(node: *Node, b: u8) void {
    if (node.name_len >= MAX_NAME_LEN) return;
    node.name[node.name_len] = b;
    node.name_len += 1;
}

fn appendNodeCodepoint(node: *Node, cp: u21) void {
    if (isSpaceCodepoint(cp)) {
        if (node.name_len > 0) node.needs_space = true;
        return;
    }
    if (node.needs_space and node.name_len > 0) {
        appendNodeByte(node, ' ');
        node.needs_space = false;
    }

    var utf8: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &utf8) catch return;
    var i: usize = 0;
    while (i < n) : (i += 1) appendNodeByte(node, utf8[i]);
}

fn appendNodeByteNormalized(node: *Node, b: u8) void {
    if (isSpace(b)) {
        if (node.name_len > 0) node.needs_space = true;
        return;
    }
    if (node.needs_space and node.name_len > 0) {
        appendNodeByte(node, ' ');
        node.needs_space = false;
    }
    appendNodeByte(node, b);
}

fn decodeEntity(input: []const u8, pos: usize, consumed: *usize, cp: *u21) bool {
    if (pos >= input.len or input[pos] != '&') return false;
    var i = pos + 1;
    if (i >= input.len) return false;

    if (input[i] == '#') {
        i += 1;
        var base: u32 = 10;
        if (i < input.len and (input[i] == 'x' or input[i] == 'X')) {
            base = 16;
            i += 1;
        }
        const start_digits = i;
        var value: u32 = 0;
        while (i < input.len and input[i] != ';') : (i += 1) {
            const c = input[i];
            var digit: u32 = 0;
            if (base == 16) {
                if (!isHexDigit(c)) return false;
                digit = hexValue(c);
            } else {
                if (c < '0' or c > '9') return false;
                digit = c - '0';
            }
            if (value > (0x10FFFF - digit) / base) return false;
            value = value * base + digit;
        }
        if (i >= input.len or input[i] != ';' or i == start_digits) return false;
        if (value == 0 or (value >= 0xD800 and value <= 0xDFFF) or value > 0x10FFFF) return false;
        consumed.* = (i - pos) + 1;
        cp.* = @as(u21, @intCast(value));
        return true;
    }

    const named = input[i..];
    if (std.mem.startsWith(u8, named, "amp;")) {
        consumed.* = 5;
        cp.* = '&';
        return true;
    }
    if (std.mem.startsWith(u8, named, "lt;")) {
        consumed.* = 4;
        cp.* = '<';
        return true;
    }
    if (std.mem.startsWith(u8, named, "gt;")) {
        consumed.* = 4;
        cp.* = '>';
        return true;
    }
    if (std.mem.startsWith(u8, named, "quot;")) {
        consumed.* = 6;
        cp.* = '"';
        return true;
    }
    if (std.mem.startsWith(u8, named, "apos;")) {
        consumed.* = 6;
        cp.* = '\'';
        return true;
    }
    if (std.mem.startsWith(u8, named, "nbsp;")) {
        consumed.* = 6;
        cp.* = 0xA0;
        return true;
    }
    return false;
}

fn appendDecodedNormalized(node: *Node, input: []const u8) void {
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '&') {
            var consumed: usize = 0;
            var cp: u21 = 0;
            if (decodeEntity(input, i, &consumed, &cp)) {
                appendNodeCodepoint(node, cp);
                i += consumed;
                continue;
            }
        }
        appendNodeByteNormalized(node, input[i]);
        i += 1;
    }
}

fn firstToken(value: []const u8) []const u8 {
    var i: usize = 0;
    while (i < value.len and isSpace(value[i])) : (i += 1) {}
    const start = i;
    while (i < value.len and !isSpace(value[i])) : (i += 1) {}
    return value[start..i];
}

fn roleFromToken(token: []const u8) RoleSpec {
    var out = RoleSpec{};
    if (token.len == 0) return out;

    if (eqlIgnoreCase(token, "none") or eqlIgnoreCase(token, "presentation")) {
        out.role = null;
        return out;
    }

    const known = struct {
        fn map(tok: []const u8) ?RoleKind {
            if (eqlIgnoreCase(tok, "link")) return .link;
            if (eqlIgnoreCase(tok, "button")) return .button;
            if (eqlIgnoreCase(tok, "heading")) return .heading;
            if (eqlIgnoreCase(tok, "img") or eqlIgnoreCase(tok, "image")) return .image;
            if (eqlIgnoreCase(tok, "textbox")) return .textbox;
            if (eqlIgnoreCase(tok, "checkbox")) return .checkbox;
            if (eqlIgnoreCase(tok, "radio")) return .radio;
            if (eqlIgnoreCase(tok, "slider")) return .slider;
            if (eqlIgnoreCase(tok, "combobox")) return .combobox;
            if (eqlIgnoreCase(tok, "option")) return .option;
            if (eqlIgnoreCase(tok, "list")) return .list;
            if (eqlIgnoreCase(tok, "listitem")) return .listitem;
            if (eqlIgnoreCase(tok, "main")) return .main;
            if (eqlIgnoreCase(tok, "navigation")) return .navigation;
            if (eqlIgnoreCase(tok, "banner")) return .banner;
            if (eqlIgnoreCase(tok, "contentinfo")) return .contentinfo;
            if (eqlIgnoreCase(tok, "region")) return .region;
            if (eqlIgnoreCase(tok, "article")) return .article;
            if (eqlIgnoreCase(tok, "complementary")) return .complementary;
            if (eqlIgnoreCase(tok, "form")) return .form;
            if (eqlIgnoreCase(tok, "table")) return .table;
            if (eqlIgnoreCase(tok, "row")) return .row;
            if (eqlIgnoreCase(tok, "columnheader")) return .columnheader;
            if (eqlIgnoreCase(tok, "cell")) return .cell;
            if (eqlIgnoreCase(tok, "dialog")) return .dialog;
            if (eqlIgnoreCase(tok, "paragraph")) return .paragraph;
            return null;
        }
    };

    if (known.map(token)) |k| {
        out.role = k;
        return out;
    }

    out.role = .custom;
    var n: usize = 0;
    while (n < token.len and n < MAX_ROLE_LEN) : (n += 1) {
        out.custom[n] = asciiLower(token[n]);
    }
    out.custom_len = @as(u8, @intCast(n));
    return out;
}

fn parseBoolTrue(value: []const u8) bool {
    if (value.len == 0) return true;
    if (eqlIgnoreCase(value, "true")) return true;
    if (eqlIgnoreCase(value, "1")) return true;
    return false;
}

fn isTag(name: []const u8, tag: []const u8) bool {
    return eqlIgnoreCase(name, tag);
}

fn implicitRole(tag_name: []const u8, has_href: bool, input_type: []const u8, has_alt: bool, alt_value: []const u8) ?RoleKind {
    if (isTag(tag_name, "a")) {
        if (has_href) return .link;
        return null;
    }
    if (isTag(tag_name, "button")) return .button;
    if (isTag(tag_name, "textarea")) return .textbox;
    if (isTag(tag_name, "select")) return .combobox;
    if (isTag(tag_name, "option")) return .option;
    if (isTag(tag_name, "ul") or isTag(tag_name, "ol")) return .list;
    if (isTag(tag_name, "li")) return .listitem;
    if (isTag(tag_name, "main")) return .main;
    if (isTag(tag_name, "nav")) return .navigation;
    if (isTag(tag_name, "header")) return .banner;
    if (isTag(tag_name, "footer")) return .contentinfo;
    if (isTag(tag_name, "section")) return .region;
    if (isTag(tag_name, "article")) return .article;
    if (isTag(tag_name, "aside")) return .complementary;
    if (isTag(tag_name, "form")) return .form;
    if (isTag(tag_name, "table")) return .table;
    if (isTag(tag_name, "tr")) return .row;
    if (isTag(tag_name, "th")) return .columnheader;
    if (isTag(tag_name, "td")) return .cell;
    if (isTag(tag_name, "dialog")) return .dialog;
    if (isTag(tag_name, "p")) return .paragraph;

    if (isTag(tag_name, "h1") or isTag(tag_name, "h2") or isTag(tag_name, "h3") or isTag(tag_name, "h4") or isTag(tag_name, "h5") or isTag(tag_name, "h6")) {
        return .heading;
    }

    if (isTag(tag_name, "img")) {
        if (has_alt and firstToken(alt_value).len == 0) return null;
        return .image;
    }

    if (isTag(tag_name, "input")) {
        if (input_type.len == 0) return .textbox;
        if (eqlIgnoreCase(input_type, "hidden")) return null;
        if (eqlIgnoreCase(input_type, "checkbox")) return .checkbox;
        if (eqlIgnoreCase(input_type, "radio")) return .radio;
        if (eqlIgnoreCase(input_type, "range")) return .slider;
        if (eqlIgnoreCase(input_type, "button") or eqlIgnoreCase(input_type, "submit") or eqlIgnoreCase(input_type, "reset") or eqlIgnoreCase(input_type, "image")) return .button;
        return .textbox;
    }

    return null;
}

fn findNearestParentNode(frames: []const Frame, frame_len: usize) ?usize {
    var i: usize = frame_len;
    while (i > 0) {
        i -= 1;
        const node_index = frames[i].node_index;
        if (node_index >= 0) return @as(usize, @intCast(node_index));
    }
    return null;
}

fn findTextTarget(frames: []const Frame, frame_len: usize, nodes: []Node) ?usize {
    var i: usize = frame_len;
    while (i > 0) {
        i -= 1;
        const node_index = frames[i].node_index;
        if (node_index < 0) continue;
        const idx: usize = @intCast(node_index);
        if (nodes[idx].name_locked) continue;
        return idx;
    }
    return null;
}

fn processTextSegment(frames: []const Frame, frame_len: usize, nodes: []Node, bytes: []const u8) void {
    if (findTextTarget(frames, frame_len, nodes)) |idx| {
        appendDecodedNormalized(&nodes[idx], bytes);
    }
}

const Writer = struct {
    idx: usize = 0,
    overflow: bool = false,

    fn writeByte(self: *Writer, b: u8) void {
        if (self.overflow) return;
        if (self.idx >= output_buf.len) {
            self.overflow = true;
            return;
        }
        output_buf[self.idx] = b;
        self.idx += 1;
    }

    fn writeSlice(self: *Writer, s: []const u8) void {
        if (self.overflow) return;
        if (self.idx + s.len > output_buf.len) {
            self.overflow = true;
            return;
        }
        @memcpy(output_buf[self.idx .. self.idx + s.len], s);
        self.idx += s.len;
    }
};

fn renderNodes(nodes: []const Node, count: usize) u32 {
    var w = Writer{};
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const node = nodes[i];
        var d: usize = 0;
        while (d < node.depth) : (d += 1) {
            w.writeSlice("  ");
        }
        w.writeSlice("- ");
        w.writeSlice(roleLabel(&node));
        if (node.name_len > 0) {
            w.writeSlice(", ");
            w.writeSlice(node.name[0..node.name_len]);
        }
        w.writeByte('\n');
    }
    if (w.overflow) return 0;
    return @as(u32, @intCast(w.idx));
}

export fn render(input_size: u32) u32 {
    const n = @as(usize, @intCast(input_size));
    if (n > INPUT_CAP) return 0;

    const input = input_buf[0..n];

    var node_count: usize = 0;
    var frame_len: usize = 0;
    var hidden_depth: usize = 0;
    var suppress_text_depth: usize = 0;

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '<') {
            const start = i;
            while (i < input.len and input[i] != '<') : (i += 1) {}
            if (hidden_depth == 0 and suppress_text_depth == 0 and i > start) {
                processTextSegment(frames_buf[0..], frame_len, nodes_buf[0..], input[start..i]);
            }
            continue;
        }

        if (i + 3 < input.len and input[i + 1] == '!' and input[i + 2] == '-' and input[i + 3] == '-') {
            var j = i + 4;
            while (j + 2 < input.len and !(input[j] == '-' and input[j + 1] == '-' and input[j + 2] == '>')) : (j += 1) {}
            if (j + 2 < input.len) {
                i = j + 3;
            } else {
                i = input.len;
            }
            continue;
        }

        if (i + 1 < input.len and (input[i + 1] == '!' or input[i + 1] == '?')) {
            var j = i + 2;
            while (j < input.len and input[j] != '>') : (j += 1) {}
            i = if (j < input.len) j + 1 else input.len;
            continue;
        }

        var j = i + 1;
        var is_close = false;
        if (j < input.len and input[j] == '/') {
            is_close = true;
            j += 1;
        }

        while (j < input.len and isSpace(input[j])) : (j += 1) {}
        const tag_start = j;
        while (j < input.len and isNameChar(input[j])) : (j += 1) {}
        if (j == tag_start) {
            i += 1;
            continue;
        }
        const tag_end = j;
        const tag_name = input[tag_start..tag_end];

        if (is_close) {
            while (j < input.len and input[j] != '>') : (j += 1) {}
            i = if (j < input.len) j + 1 else input.len;

            var k = frame_len;
            var matched = false;
            while (k > 0) {
                k -= 1;
                const fr = frames_buf[k];
                const fr_name = input[fr.tag_start .. fr.tag_start + fr.tag_len];
                if (!eqlIgnoreCase(fr_name, tag_name)) continue;
                matched = true;
                const remove_from = k;
                while (frame_len > remove_from) {
                    frame_len -= 1;
                    const pop = frames_buf[frame_len];
                    if (pop.hidden and hidden_depth > 0) hidden_depth -= 1;
                    if (pop.suppress_text and suppress_text_depth > 0) suppress_text_depth -= 1;
                }
                break;
            }
            if (!matched and frame_len > 0) {
                frame_len -= 1;
            }
            continue;
        }

        var role_attr: ?[]const u8 = null;
        var aria_label_attr: ?[]const u8 = null;
        var aria_hidden_attr: ?[]const u8 = null;
        var type_attr: ?[]const u8 = null;
        var alt_attr: ?[]const u8 = null;
        var has_href = false;
        var self_closing = false;

        while (j < input.len) {
            while (j < input.len and isSpace(input[j])) : (j += 1) {}
            if (j >= input.len) break;

            if (input[j] == '>') {
                j += 1;
                break;
            }
            if (input[j] == '/') {
                self_closing = true;
                j += 1;
                continue;
            }

            const attr_name_start = j;
            while (j < input.len and isNameChar(input[j])) : (j += 1) {}
            if (j == attr_name_start) {
                j += 1;
                continue;
            }
            const attr_name = input[attr_name_start..j];

            while (j < input.len and isSpace(input[j])) : (j += 1) {}
            var attr_value: []const u8 = "";
            if (j < input.len and input[j] == '=') {
                j += 1;
                while (j < input.len and isSpace(input[j])) : (j += 1) {}
                if (j < input.len and (input[j] == '"' or input[j] == '\'')) {
                    const quote = input[j];
                    j += 1;
                    const vstart = j;
                    while (j < input.len and input[j] != quote) : (j += 1) {}
                    attr_value = input[vstart..@min(j, input.len)];
                    if (j < input.len and input[j] == quote) j += 1;
                } else {
                    const vstart = j;
                    while (j < input.len and !isSpace(input[j]) and input[j] != '>') : (j += 1) {}
                    attr_value = input[vstart..j];
                }
            }

            if (eqlIgnoreCase(attr_name, "role")) {
                role_attr = attr_value;
            } else if (eqlIgnoreCase(attr_name, "aria-label")) {
                aria_label_attr = attr_value;
            } else if (eqlIgnoreCase(attr_name, "aria-hidden")) {
                aria_hidden_attr = attr_value;
            } else if (eqlIgnoreCase(attr_name, "type")) {
                type_attr = attr_value;
            } else if (eqlIgnoreCase(attr_name, "alt")) {
                alt_attr = attr_value;
            } else if (eqlIgnoreCase(attr_name, "href")) {
                has_href = true;
            }
        }

        const inherited_hidden = hidden_depth > 0;
        const is_hidden = inherited_hidden or (aria_hidden_attr != null and parseBoolTrue(aria_hidden_attr.?));
        const suppress = isTag(tag_name, "script") or isTag(tag_name, "style");

        var new_node_index: i32 = -1;
        if (!is_hidden and !suppress and node_count < MAX_NODES) {
            var spec = RoleSpec{};
            if (role_attr) |raw_role| {
                spec = roleFromToken(firstToken(raw_role));
            } else {
                const inferred = implicitRole(
                    tag_name,
                    has_href,
                    if (type_attr) |t| t else "",
                    alt_attr != null,
                    if (alt_attr) |a| a else "",
                );
                spec.role = inferred;
            }

            if (spec.role) |r| {
                const idx = node_count;
                node_count += 1;

                nodes_buf[idx] = Node{};
                nodes_buf[idx].role = r;
                if (r == .custom and spec.custom_len > 0) {
                    nodes_buf[idx].custom_role_len = spec.custom_len;
                    @memcpy(nodes_buf[idx].custom_role[0..spec.custom_len], spec.custom[0..spec.custom_len]);
                }

                if (findNearestParentNode(frames_buf[0..], frame_len)) |pidx| {
                    nodes_buf[idx].parent = @as(i32, @intCast(pidx));
                    nodes_buf[idx].depth = nodes_buf[pidx].depth + 1;
                }

                if (aria_label_attr) |label| {
                    appendDecodedNormalized(&nodes_buf[idx], label);
                    if (nodes_buf[idx].name_len > 0) nodes_buf[idx].name_locked = true;
                } else if (alt_attr) |alt| {
                    appendDecodedNormalized(&nodes_buf[idx], alt);
                    if (nodes_buf[idx].name_len > 0) nodes_buf[idx].name_locked = true;
                }

                new_node_index = @as(i32, @intCast(idx));
            }
        }

        if (!self_closing and frame_len < MAX_STACK) {
            frames_buf[frame_len] = Frame{
                .tag_start = @as(u32, @intCast(tag_start)),
                .tag_len = @as(u16, @intCast(tag_end - tag_start)),
                .node_index = new_node_index,
                .hidden = is_hidden,
                .suppress_text = suppress,
            };
            frame_len += 1;
            if (is_hidden) hidden_depth += 1;
            if (suppress) suppress_text_depth += 1;
        }

        i = j;
    }

    return renderNodes(nodes_buf[0..], node_count);
}
