const std = @import("std");

const INPUT_CAP: usize = 64 * 1024;
const OUTPUT_CAP: usize = 16;

const no_render: i64 = 1;
const invalid_input: i64 = -0x4000000000000000;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var pending_commit_result: i64 = no_render;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_ptr() u32 {
    return @intCast(@intFromPtr(&output_buf));
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

fn lower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
}

fn equalTag(input: []const u8, comptime expected: []const u8) bool {
    if (input.len != expected.len) return false;
    inline for (expected, 0..) |byte, i| {
        if (lower(input[i]) != byte) return false;
    }
    return true;
}

fn isBuiltin(input: []const u8) bool {
    const names = .{
        "a", "abbr", "address", "area", "article", "aside", "audio", "b", "base", "bdi", "bdo", "blockquote", "body", "br", "button", "canvas", "caption", "cite", "code", "col", "colgroup", "data", "datalist", "dd", "del", "details", "dfn", "dialog", "div", "dl", "dt", "em", "embed", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hgroup", "hr", "html", "i", "iframe", "img", "input", "ins", "kbd", "label", "legend", "li", "link", "main", "map", "mark", "menu", "meta", "meter", "nav", "noscript", "object", "ol", "optgroup", "option", "output", "p", "picture", "pre", "progress", "q", "rp", "rt", "ruby", "s", "samp", "script", "search", "section", "select", "selectedcontent", "slot", "small", "source", "span", "strong", "style", "sub", "summary", "sup", "table", "tbody", "td", "template", "textarea", "tfoot", "th", "thead", "time", "title", "tr", "track", "u", "ul", "var", "video", "wbr",
    };
    inline for (names) |name| {
        if (equalTag(input, name)) return true;
    }
    return false;
}

fn decodeCodepoint(input: []const u8, index: *usize) ?u21 {
    const i = index.*;
    const a = input[i];
    if (a <= 0x7f) {
        index.* += 1;
        return a;
    }
    const needed: usize = if (a >= 0xc2 and a <= 0xdf) 2 else if (a >= 0xe0 and a <= 0xef) 3 else if (a >= 0xf0 and a <= 0xf4) 4 else return null;
    if (i + needed > input.len) return null;
    var cp: u32 = a & (if (needed == 2) @as(u8, 0x1f) else if (needed == 3) @as(u8, 0x0f) else @as(u8, 0x07));
    var j: usize = 1;
    while (j < needed) : (j += 1) {
        const b = input[i + j];
        if (b & 0xc0 != 0x80) return null;
        cp = (cp << 6) | (b & 0x3f);
    }
    if ((needed == 2 and cp < 0x80) or (needed == 3 and cp < 0x800) or (needed == 4 and cp < 0x10000) or cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) return null;
    index.* += needed;
    return @intCast(cp);
}

fn isPcenChar(cp: u21) bool {
    return cp == '-' or cp == '.' or cp == '_' or (cp >= '0' and cp <= '9') or (cp >= 'a' and cp <= 'z') or
        cp == 0x00b7 or (cp >= 0x00c0 and cp <= 0x00d6) or (cp >= 0x00d8 and cp <= 0x00f6) or
        (cp >= 0x00f8 and cp <= 0x037d) or (cp >= 0x037f and cp <= 0x1fff) or
        (cp >= 0x200c and cp <= 0x200d) or (cp >= 0x203f and cp <= 0x2040) or
        (cp >= 0x2070 and cp <= 0x218f) or (cp >= 0x2c00 and cp <= 0x2fef) or
        (cp >= 0x3001 and cp <= 0xd7ff) or (cp >= 0xf900 and cp <= 0xfdcf) or
        (cp >= 0xfdf0 and cp <= 0xfffd) or (cp >= 0x10000 and cp <= 0xeffff);
}

fn isReserved(input: []const u8) bool {
    const names = .{ "annotation-xml", "color-profile", "font-face", "font-face-src", "font-face-uri", "font-face-format", "font-face-name", "missing-glyph" };
    inline for (names) |name| {
        if (equalTag(input, name)) return true;
    }
    return false;
}

fn isCustom(input: []const u8) bool {
    if (input.len < 2 or input[0] < 'a' or input[0] > 'z' or isReserved(input)) return false;
    var has_hyphen = false;
    var i: usize = 0;
    var steps: usize = 0;
    while (i < input.len and steps < INPUT_CAP) : (steps += 1) {
        const cp = decodeCodepoint(input, &i) orelse return false;
        if (!isPcenChar(cp)) return false;
        if (cp == '-') has_hyphen = true;
    }
    return i == input.len and has_hyphen;
}

fn validUtf8(input: []const u8) bool {
    var i: usize = 0;
    var steps: usize = 0;
    while (i < input.len and steps < INPUT_CAP) : (steps += 1) {
        _ = decodeCodepoint(input, &i) orelse return false;
    }
    return i == input.len;
}

fn emit(value: []const u8) u32 {
    @memcpy(output_buf[0..value.len], value);
    return @intCast(value.len);
}

export fn render(input_size: u32) u32 {
    const size: usize = @intCast(input_size);
    if (pending_commit_result != no_render) @trap();
    if (size > INPUT_CAP) @trap();
    const input = input_buf[0..size];

    // The input_utf8_cap export makes valid UTF-8 a caller precondition.
    if (!validUtf8(input)) @trap();

    pending_commit_result = invalid_input;
    if (size == 0) return 0;
    if (isBuiltin(input)) {
        pending_commit_result = 0;
        return emit("builtin");
    }
    if (isCustom(input)) {
        pending_commit_result = 0;
        return emit("custom");
    }

    // TODO: Report the first byte which rules out a built-in or custom name.
    return 0;
}

/// Close the render transaction. This function does not trap.
export fn commit() i64 {
    const result = if (pending_commit_result == no_render)
        invalid_input
    else
        pending_commit_result;
    pending_commit_result = no_render;
    return result;
}

test "classifies accepted names and recovers after rejection" {
    const builtin = "section";
    @memcpy(input_buf[0..builtin.len], builtin);
    try std.testing.expectEqual(@as(u32, 7), render(builtin.len));
    try std.testing.expectEqualStrings("builtin", output_buf[0..7]);
    try std.testing.expectEqual(@as(i64, 0), commit());

    const invalid = "frobnicate";
    @memcpy(input_buf[0..invalid.len], invalid);
    try std.testing.expectEqual(@as(u32, 0), render(invalid.len));
    try std.testing.expectEqual(invalid_input, commit());

    const custom = "qip-widget";
    @memcpy(input_buf[0..custom.len], custom);
    try std.testing.expectEqual(@as(u32, 6), render(custom.len));
    try std.testing.expectEqualStrings("custom", output_buf[0..6]);
    try std.testing.expectEqual(@as(i64, 0), commit());
}
