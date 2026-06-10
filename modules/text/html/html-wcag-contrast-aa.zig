const std = @import("std");

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = 1024 * 1024;
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "text/html";

const MAX_RULES: usize = 512;
const MAX_STACK: usize = 128;
const MAX_NAME: usize = 64;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var rules_buf: [MAX_RULES]Rule = undefined;

const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

const Style = struct {
    color: ?Color = null,
    background: ?Color = null,
};

const SelectorKind = enum(u8) {
    any,
    tag,
    class,
    id,
};

const Selector = struct {
    kind: SelectorKind = .any,
    name: [MAX_NAME]u8 = undefined,
    name_len: u8 = 0,
};

const Rule = struct {
    selector: Selector,
    style: Style,
};

const Element = struct {
    tag: [MAX_NAME]u8 = undefined,
    tag_len: u8 = 0,
    id: [MAX_NAME]u8 = undefined,
    id_len: u8 = 0,
    class_attr: []const u8 = "",
    color: Color = Color{ .r = 0, .g = 0, .b = 0 },
    background: Color = Color{ .r = 255, .g = 255, .b = 255 },
    suppress_text: bool = false,
};

const Attr = struct {
    name: []const u8,
    value: []const u8,
};

const Attrs = struct {
    id: []const u8 = "",
    class: []const u8 = "",
    style: []const u8 = "",
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

fn startsWithIgnoreCase(a: []const u8, b: []const u8) bool {
    return a.len >= b.len and eqlIgnoreCase(a[0..b.len], b);
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

fn isNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == ':';
}

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    var end = s.len;
    while (start < end and isSpace(s[start])) start += 1;
    while (end > start and isSpace(s[end - 1])) end -= 1;
    return s[start..end];
}

fn hasVisibleText(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (!isSpace(s[i])) return true;
    }
    return false;
}

fn hexValue(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn parseHexColor(s_in: []const u8) ?Color {
    const s = trim(s_in);
    if (s.len == 4 and s[0] == '#') {
        const r = hexValue(s[1]) orelse return null;
        const g = hexValue(s[2]) orelse return null;
        const b = hexValue(s[3]) orelse return null;
        return .{ .r = r * 17, .g = g * 17, .b = b * 17 };
    }
    if (s.len == 7 and s[0] == '#') {
        const r1 = hexValue(s[1]) orelse return null;
        const r2 = hexValue(s[2]) orelse return null;
        const g1 = hexValue(s[3]) orelse return null;
        const g2 = hexValue(s[4]) orelse return null;
        const b1 = hexValue(s[5]) orelse return null;
        const b2 = hexValue(s[6]) orelse return null;
        return .{ .r = r1 * 16 + r2, .g = g1 * 16 + g2, .b = b1 * 16 + b2 };
    }
    return null;
}

fn parseU8Token(s: []const u8, index: *usize) ?u8 {
    while (index.* < s.len and isSpace(s[index.*])) index.* += 1;
    var value: u32 = 0;
    const start = index.*;
    while (index.* < s.len and s[index.*] >= '0' and s[index.*] <= '9') : (index.* += 1) {
        value = value * 10 + (s[index.*] - '0');
        if (value > 255) return null;
    }
    if (index.* == start) return null;
    while (index.* < s.len and isSpace(s[index.*])) index.* += 1;
    if (index.* < s.len and s[index.*] == '%') return null;
    return @as(u8, @intCast(value));
}

fn parseRgbColor(s_in: []const u8) ?Color {
    const s = trim(s_in);
    if (!startsWithIgnoreCase(s, "rgb(") or s.len < 6 or s[s.len - 1] != ')') return null;
    const inner = s[4 .. s.len - 1];
    var i: usize = 0;
    const r = parseU8Token(inner, &i) orelse return null;
    if (i >= inner.len or inner[i] != ',') return null;
    i += 1;
    const g = parseU8Token(inner, &i) orelse return null;
    if (i >= inner.len or inner[i] != ',') return null;
    i += 1;
    const b = parseU8Token(inner, &i) orelse return null;
    while (i < inner.len and isSpace(inner[i])) i += 1;
    if (i != inner.len) return null;
    return .{ .r = r, .g = g, .b = b };
}

fn namedColor(s: []const u8) ?Color {
    if (eqlIgnoreCase(s, "black")) return .{ .r = 0, .g = 0, .b = 0 };
    if (eqlIgnoreCase(s, "white")) return .{ .r = 255, .g = 255, .b = 255 };
    if (eqlIgnoreCase(s, "red")) return .{ .r = 255, .g = 0, .b = 0 };
    if (eqlIgnoreCase(s, "green")) return .{ .r = 0, .g = 128, .b = 0 };
    if (eqlIgnoreCase(s, "blue")) return .{ .r = 0, .g = 0, .b = 255 };
    if (eqlIgnoreCase(s, "gray") or eqlIgnoreCase(s, "grey")) return .{ .r = 128, .g = 128, .b = 128 };
    if (eqlIgnoreCase(s, "darkgray") or eqlIgnoreCase(s, "darkgrey")) return .{ .r = 169, .g = 169, .b = 169 };
    if (eqlIgnoreCase(s, "lightgray") or eqlIgnoreCase(s, "lightgrey")) return .{ .r = 211, .g = 211, .b = 211 };
    if (eqlIgnoreCase(s, "yellow")) return .{ .r = 255, .g = 255, .b = 0 };
    if (eqlIgnoreCase(s, "orange")) return .{ .r = 255, .g = 165, .b = 0 };
    if (eqlIgnoreCase(s, "purple")) return .{ .r = 128, .g = 0, .b = 128 };
    return null;
}

fn parseColorValue(value_in: []const u8) ?Color {
    var value = trim(value_in);
    if (std.mem.indexOfScalar(u8, value, '!')) |bang| value = trim(value[0..bang]);
    if (eqlIgnoreCase(value, "transparent") or eqlIgnoreCase(value, "currentcolor")) return null;
    if (parseHexColor(value)) |c| return c;
    if (parseRgbColor(value)) |c| return c;
    return namedColor(value);
}

fn parseStyleDecls(css: []const u8) Style {
    var style = Style{};
    var start: usize = 0;
    while (start < css.len) {
        var end = start;
        while (end < css.len and css[end] != ';') end += 1;
        const decl = trim(css[start..end]);
        if (std.mem.indexOfScalar(u8, decl, ':')) |colon| {
            const prop = trim(decl[0..colon]);
            const value = trim(decl[colon + 1 ..]);
            if (eqlIgnoreCase(prop, "color")) {
                if (parseColorValue(value)) |c| style.color = c;
            } else if (eqlIgnoreCase(prop, "background-color") or eqlIgnoreCase(prop, "background")) {
                if (parseColorValue(value)) |c| style.background = c;
            }
        }
        start = if (end < css.len) end + 1 else css.len;
    }
    return style;
}

fn copyName(dst: *[MAX_NAME]u8, len: *u8, src_in: []const u8) void {
    const src = trim(src_in);
    var n: usize = 0;
    while (n < src.len and n < MAX_NAME) : (n += 1) dst[n] = asciiLower(src[n]);
    len.* = @as(u8, @intCast(n));
}

fn parseSimpleSelector(selector_in: []const u8) Selector {
    var selector = Selector{};
    var s = trim(selector_in);
    if (s.len == 0) return selector;

    var last_start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (isSpace(s[i]) or s[i] == '>' or s[i] == '+' or s[i] == '~') {
            while (i < s.len and (isSpace(s[i]) or s[i] == '>' or s[i] == '+' or s[i] == '~')) i += 1;
            if (i < s.len) last_start = i;
        }
    }
    s = trim(s[last_start..]);
    if (s.len == 0) return selector;

    if (s[0] == '#') {
        selector.kind = .id;
        copyName(&selector.name, &selector.name_len, s[1..]);
        return selector;
    }
    if (s[0] == '.') {
        selector.kind = .class;
        copyName(&selector.name, &selector.name_len, s[1..]);
        return selector;
    }

    const name_start: usize = 0;
    var name_end: usize = 0;
    while (name_end < s.len and isNameChar(s[name_end])) name_end += 1;
    if (name_end > name_start) {
        selector.kind = .tag;
        copyName(&selector.name, &selector.name_len, s[name_start..name_end]);
    }
    if (std.mem.indexOfScalar(u8, s, '#')) |hash| {
        selector.kind = .id;
        copyName(&selector.name, &selector.name_len, s[hash + 1 ..]);
    } else if (std.mem.indexOfScalar(u8, s, '.')) |dot| {
        selector.kind = .class;
        copyName(&selector.name, &selector.name_len, s[dot + 1 ..]);
    }
    return selector;
}

fn addRule(rules: []Rule, count: *usize, selector: []const u8, style: Style) void {
    if (style.color == null and style.background == null) return;
    if (count.* >= rules.len) @trap();
    rules[count.*] = .{ .selector = parseSimpleSelector(selector), .style = style };
    count.* += 1;
}

fn parseStylesheet(css: []const u8, rules: []Rule, count: *usize) void {
    var i: usize = 0;
    while (i < css.len) {
        while (i < css.len and isSpace(css[i])) i += 1;
        const selector_start = i;
        while (i < css.len and css[i] != '{') i += 1;
        if (i >= css.len) break;
        const selectors = css[selector_start..i];
        i += 1;
        const body_start = i;
        while (i < css.len and css[i] != '}') i += 1;
        const body = css[body_start..@min(i, css.len)];
        const style = parseStyleDecls(body);
        var sel_start: usize = 0;
        while (sel_start < selectors.len) {
            var sel_end = sel_start;
            while (sel_end < selectors.len and selectors[sel_end] != ',') sel_end += 1;
            addRule(rules, count, selectors[sel_start..sel_end], style);
            sel_start = if (sel_end < selectors.len) sel_end + 1 else selectors.len;
        }
        if (i < css.len) i += 1;
    }
}

fn hasClass(class_attr: []const u8, name: []const u8) bool {
    var i: usize = 0;
    while (i < class_attr.len) {
        while (i < class_attr.len and isSpace(class_attr[i])) i += 1;
        const start = i;
        while (i < class_attr.len and !isSpace(class_attr[i])) i += 1;
        if (i > start and eqlIgnoreCase(class_attr[start..i], name)) return true;
    }
    return false;
}

fn selectorMatches(sel: *const Selector, el: *const Element) bool {
    const name = sel.name[0..sel.name_len];
    return switch (sel.kind) {
        .any => true,
        .tag => eqlIgnoreCase(el.tag[0..el.tag_len], name),
        .id => eqlIgnoreCase(el.id[0..el.id_len], name),
        .class => hasClass(el.class_attr, name),
    };
}

fn applyStyle(el: *Element, style: Style) void {
    if (style.color) |c| el.color = c;
    if (style.background) |c| el.background = c;
}

fn luminanceChannel(v: u8) f64 {
    const s = @as(f64, @floatFromInt(v)) / 255.0;
    if (s <= 0.03928) return s / 12.92;
    return std.math.pow(f64, (s + 0.055) / 1.055, 2.4);
}

fn luminance(c: Color) f64 {
    return 0.2126 * luminanceChannel(c.r) + 0.7152 * luminanceChannel(c.g) + 0.0722 * luminanceChannel(c.b);
}

fn contrastRatio(a: Color, b: Color) f64 {
    const la = luminance(a);
    const lb = luminance(b);
    const lighter = @max(la, lb);
    const darker = @min(la, lb);
    return (lighter + 0.05) / (darker + 0.05);
}

fn passesAA(fg: Color, bg: Color) bool {
    return contrastRatio(fg, bg) >= 4.5;
}

fn findTagEnd(input: []const u8, start: usize) usize {
    var i = start;
    var quote: u8 = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '>') {
            return i;
        }
    }
    return input.len;
}

fn parseAttrs(tag_src: []const u8) Attrs {
    var attrs = Attrs{};
    var i: usize = 0;
    while (i < tag_src.len and !isSpace(tag_src[i]) and tag_src[i] != '/') i += 1;
    while (i < tag_src.len) {
        while (i < tag_src.len and (isSpace(tag_src[i]) or tag_src[i] == '/')) i += 1;
        const name_start = i;
        while (i < tag_src.len and isNameChar(tag_src[i])) i += 1;
        if (i == name_start) break;
        const name = tag_src[name_start..i];
        while (i < tag_src.len and isSpace(tag_src[i])) i += 1;
        var value: []const u8 = "";
        if (i < tag_src.len and tag_src[i] == '=') {
            i += 1;
            while (i < tag_src.len and isSpace(tag_src[i])) i += 1;
            if (i < tag_src.len and (tag_src[i] == '"' or tag_src[i] == '\'')) {
                const q = tag_src[i];
                i += 1;
                const value_start = i;
                while (i < tag_src.len and tag_src[i] != q) i += 1;
                value = tag_src[value_start..@min(i, tag_src.len)];
                if (i < tag_src.len) i += 1;
            } else {
                const value_start = i;
                while (i < tag_src.len and !isSpace(tag_src[i]) and tag_src[i] != '/') i += 1;
                value = tag_src[value_start..i];
            }
        }
        if (eqlIgnoreCase(name, "id")) attrs.id = value;
        if (eqlIgnoreCase(name, "class")) attrs.class = value;
        if (eqlIgnoreCase(name, "style")) attrs.style = value;
    }
    return attrs;
}

fn parseOpenElement(tag_src: []const u8, parent: Element, rules: []Rule) Element {
    var el = parent;
    el.class_attr = "";
    el.id_len = 0;
    const attrs = parseAttrs(tag_src);
    var tag_end: usize = 0;
    while (tag_end < tag_src.len and !isSpace(tag_src[tag_end]) and tag_src[tag_end] != '/') tag_end += 1;
    copyName(&el.tag, &el.tag_len, tag_src[0..tag_end]);
    copyName(&el.id, &el.id_len, attrs.id);
    el.class_attr = attrs.class;
    el.suppress_text = eqlIgnoreCase(el.tag[0..el.tag_len], "script") or eqlIgnoreCase(el.tag[0..el.tag_len], "style");

    for (rules) |*rule| {
        if (selectorMatches(&rule.selector, &el)) applyStyle(&el, rule.style);
    }
    applyStyle(&el, parseStyleDecls(attrs.style));
    return el;
}

fn isSelfClosing(tag_src: []const u8) bool {
    const s = trim(tag_src);
    return s.len > 0 and s[s.len - 1] == '/';
}

fn validateContrast(input: []const u8, rules: []Rule) void {
    var rule_count: usize = 0;
    var stack: [MAX_STACK]Element = undefined;
    var depth: usize = 1;
    stack[0] = .{};

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '<') {
            const start = i;
            while (i < input.len and input[i] != '<') i += 1;
            const current = stack[depth - 1];
            if (!current.suppress_text and hasVisibleText(input[start..i]) and !passesAA(current.color, current.background)) @trap();
            continue;
        }

        if (std.mem.startsWith(u8, input[i..], "<!--")) {
            if (std.mem.indexOf(u8, input[i + 4 ..], "-->")) |off| {
                i = i + 4 + off + 3;
            } else {
                break;
            }
            continue;
        }

        const tag_end = findTagEnd(input, i + 1);
        if (tag_end >= input.len) break;
        const tag_src = trim(input[i + 1 .. tag_end]);
        i = tag_end + 1;
        if (tag_src.len == 0 or tag_src[0] == '!' or tag_src[0] == '?') continue;

        if (tag_src[0] == '/') {
            if (depth > 1) depth -= 1;
            continue;
        }

        const parent = stack[depth - 1];
        const el = parseOpenElement(tag_src, parent, rules[0..rule_count]);

        if (eqlIgnoreCase(el.tag[0..el.tag_len], "style")) {
            if (std.mem.indexOf(u8, input[i..], "</style>")) |off| {
                parseStylesheet(input[i .. i + off], rules, &rule_count);
                i = i + off + "</style>".len;
            } else if (std.mem.indexOf(u8, input[i..], "</STYLE>")) |off| {
                parseStylesheet(input[i .. i + off], rules, &rule_count);
                i = i + off + "</STYLE>".len;
            }
            continue;
        }

        if (!isSelfClosing(tag_src)) {
            if (depth >= stack.len) @trap();
            stack[depth] = el;
            depth += 1;
        }
    }
}

fn renderChecked(input: []const u8, out: []u8) usize {
    if (input.len > out.len) @trap();
    validateContrast(input, rules_buf[0..]);
    @memcpy(out[0..input.len], input);
    return input.len;
}

export fn render(input_size_in: u32) u32 {
    const input_size = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    return @as(u32, @intCast(renderChecked(input_buf[0..input_size], output_buf[0..])));
}

test "passes inline AA contrast and returns input unchanged" {
    const html = "<p style=\"color:#111;background:#fff\">Readable</p>";
    var out: [128]u8 = undefined;
    const len = renderChecked(html, out[0..]);
    try std.testing.expectEqualStrings(html, out[0..len]);
}

test "passes stylesheet rule before content" {
    const html = "<style>.ok{color:#111;background:white}</style><p class=\"ok\">Readable</p>";
    var out: [128]u8 = undefined;
    const len = renderChecked(html, out[0..]);
    try std.testing.expectEqualStrings(html, out[0..len]);
}

test "bottom stylesheet does not affect earlier content" {
    const html = "<p>Readable</p><style>p{color:#aaa;background:#fff}</style>";
    var out: [128]u8 = undefined;
    const len = renderChecked(html, out[0..]);
    try std.testing.expectEqualStrings(html, out[0..len]);
}
