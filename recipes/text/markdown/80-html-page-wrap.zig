const std = @import("std");

const INPUT_CAP: u32 = 0x40000;
const OUTPUT_CAP: u32 = 0x80000;
const TITLE_CAP: usize = 1024;
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "text/html";
const EMBEDDED_STYLES = std.mem.trimRight(u8, @embedFile("styles.css"), "\r\n");
const EMBEDDED_HEADER = std.mem.trimRight(u8, @embedFile("header.html"), "\r\n");
const EMBEDDED_FOOTER = std.mem.trimRight(u8, @embedFile("footer.html"), "\r\n");

comptime {
    @setEvalBranchQuota(1_000_000);
    if (containsClosingStyleTag(EMBEDDED_STYLES)) {
        @compileError("styles.css contains closing </style sequence; remove it or split as <\\/style");
    }
}

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
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

const Writer = struct {
    buf: []u8,
    idx: usize,
    overflow: bool,

    fn init(buf: []u8) Writer {
        return .{ .buf = buf, .idx = 0, .overflow = false };
    }

    fn writeByte(self: *Writer, b: u8) void {
        if (self.overflow) return;
        if (self.idx >= self.buf.len) {
            self.overflow = true;
            return;
        }
        self.buf[self.idx] = b;
        self.idx += 1;
    }

    fn writeSlice(self: *Writer, s: []const u8) void {
        if (self.overflow) return;
        if (self.idx + s.len > self.buf.len) {
            const remaining = self.buf.len - self.idx;
            if (remaining > 0) {
                @memcpy(self.buf[self.idx..][0..remaining], s[0..remaining]);
                self.idx += remaining;
            }
            self.overflow = true;
            return;
        }
        @memcpy(self.buf[self.idx..][0..s.len], s);
        self.idx += s.len;
    }

    fn writeEscaped(self: *Writer, s: []const u8) void {
        for (s) |ch| {
            switch (ch) {
                '&' => self.writeSlice("&amp;"),
                '<' => self.writeSlice("&lt;"),
                '>' => self.writeSlice("&gt;"),
                '"' => self.writeSlice("&quot;"),
                else => self.writeByte(ch),
            }
        }
    }
};

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and isSpace(s[start])) : (start += 1) {}
    while (end > start and isSpace(s[end - 1])) : (end -= 1) {}
    return s[start..end];
}

fn findH1Content(input: []const u8) ?struct { start: usize, end: usize } {
    var i: usize = 0;
    while (i + 3 < input.len) : (i += 1) {
        if (input[i] == '<' and input[i + 1] == 'h' and input[i + 2] == '1') {
            const next = input[i + 3];
            if (next != '>' and next != ' ' and next != '\t' and next != '\r' and next != '\n') {
                continue;
            }
            var j: usize = i + 3;
            while (j < input.len and input[j] != '>') : (j += 1) {}
            if (j >= input.len) return null;
            const start = j + 1;
            if (std.mem.indexOf(u8, input[start..], "</h1>")) |rel| {
                return .{ .start = start, .end = start + rel };
            }
            return null;
        }
    }
    return null;
}

fn extractTitle(input: []const u8, buf: []u8) []const u8 {
    const fallback = "Document";
    const range = findH1Content(input) orelse return fallback;

    var w = Writer.init(buf);
    var i = range.start;
    while (i < range.end and !w.overflow) : (i += 1) {
        if (input[i] == '<') {
            i += 1;
            while (i < range.end and input[i] != '>') : (i += 1) {}
            continue;
        }
        w.writeByte(input[i]);
    }

    const trimmed = trimWhitespace(buf[0..w.idx]);
    if (trimmed.len == 0) return fallback;
    return trimmed;
}

fn containsClosingStyleTag(css: []const u8) bool {
    return std.mem.indexOf(u8, css, "</style") != null;
}

fn asciiLower(ch: u8) u8 {
    if (ch >= 'A' and ch <= 'Z') return ch + ('a' - 'A');
    return ch;
}

fn hasPrefixIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (needle, 0..) |ch, i| {
        if (asciiLower(haystack[i]) != asciiLower(ch)) return false;
    }
    return true;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8, start: usize) ?usize {
    if (needle.len == 0) return start;
    if (start >= haystack.len or haystack.len - start < needle.len) return null;

    var i = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (hasPrefixIgnoreCase(haystack[i..], needle)) return i;
    }
    return null;
}

fn isTitleTagBoundary(ch: u8) bool {
    return ch == '>' or isSpace(ch);
}

const ExistingTitle = struct {
    open_start: usize,
    close_end: usize,
    content_start: usize,
    content_end: usize,
};

fn findExistingTitle(input: []const u8) ?ExistingTitle {
    var i: usize = 0;
    while (i + 6 <= input.len) : (i += 1) {
        if (input[i] != '<') continue;
        if (!hasPrefixIgnoreCase(input[i + 1 ..], "title")) continue;

        const boundary_idx = i + 1 + "title".len;
        if (boundary_idx >= input.len or !isTitleTagBoundary(input[boundary_idx])) continue;

        var open_end = boundary_idx;
        while (open_end < input.len and input[open_end] != '>') : (open_end += 1) {}
        if (open_end >= input.len) return null;

        const content_start = open_end + 1;
        const close_start = indexOfIgnoreCase(input, "</title>", content_start) orelse return null;
        return .{
            .open_start = i,
            .close_end = close_start + "</title>".len,
            .content_start = content_start,
            .content_end = close_start,
        };
    }
    return null;
}

fn wrapHtml(input: []const u8, output: []u8, title_buf: []u8) usize {
    var w = Writer.init(output);
    const existing_title = findExistingTitle(input);
    var title = extractTitle(input, title_buf);
    if (existing_title) |t| {
        const existing_text = trimWhitespace(input[t.content_start..t.content_end]);
        if (existing_text.len > 0) title = existing_text;
    }

    w.writeSlice("<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>");
    w.writeEscaped(title);
    w.writeSlice("</title><style>");
    w.writeSlice(EMBEDDED_STYLES);
    w.writeSlice("</style>");
    w.writeSlice(EMBEDDED_HEADER);
    w.writeSlice("<main>");
    if (existing_title) |t| {
        w.writeSlice(input[0..t.open_start]);
        w.writeSlice(input[t.close_end..]);
    } else {
        w.writeSlice(input);
    }
    w.writeSlice("</main>");
    w.writeSlice(EMBEDDED_FOOTER);
    w.writeByte('\n');

    return w.idx;
}

fn renderImpl(input_size: u32) u32 {
    const input = input_buf[0..@as(usize, @intCast(input_size))];
    const output = output_buf[0..];
    var title_buf: [TITLE_CAP]u8 = undefined;
    const written = wrapHtml(input, output, title_buf[0..]);
    return @as(u32, @intCast(written));
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

test "wraps with title from h1" {
    const input = "<h1>Hello <em>World</em></h1><p>Hi</p>";
    const expected = std.fmt.comptimePrint(
        "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>Hello World</title><style>{s}</style>{s}<main><h1>Hello <em>World</em></h1><p>Hi</p></main>{s}\n",
        .{ EMBEDDED_STYLES, EMBEDDED_HEADER, EMBEDDED_FOOTER },
    );
    var out: [expected.len]u8 = undefined;
    var title_buf: [TITLE_CAP]u8 = undefined;
    const written = wrapHtml(input, out[0..], title_buf[0..]);
    try std.testing.expectEqualStrings(
        expected,
        out[0..written],
    );
}

test "defaults title when no h1" {
    const input = "<p>No heading</p>";
    const expected = std.fmt.comptimePrint(
        "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>Document</title><style>{s}</style>{s}<main><p>No heading</p></main>{s}\n",
        .{ EMBEDDED_STYLES, EMBEDDED_HEADER, EMBEDDED_FOOTER },
    );
    var out: [expected.len]u8 = undefined;
    var title_buf: [TITLE_CAP]u8 = undefined;
    const written = wrapHtml(input, out[0..], title_buf[0..]);
    try std.testing.expectEqualStrings(
        expected,
        out[0..written],
    );
}

test "uses existing title and moves it to head" {
    const input = "<p>Intro</p><title>Custom Page</title><h1>Fallback</h1><p>Body</p>";
    const expected = std.fmt.comptimePrint(
        "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>Custom Page</title><style>{s}</style>{s}<main><p>Intro</p><h1>Fallback</h1><p>Body</p></main>{s}\n",
        .{ EMBEDDED_STYLES, EMBEDDED_HEADER, EMBEDDED_FOOTER },
    );
    var out: [expected.len]u8 = undefined;
    var title_buf: [TITLE_CAP]u8 = undefined;
    const written = wrapHtml(input, out[0..], title_buf[0..]);
    try std.testing.expectEqualStrings(
        expected,
        out[0..written],
    );
}

test "matches existing title case-insensitively" {
    const input = "<TITLE>  Mixed Case Title  </TITLE><p>Body</p>";
    const expected = std.fmt.comptimePrint(
        "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>Mixed Case Title</title><style>{s}</style>{s}<main><p>Body</p></main>{s}\n",
        .{ EMBEDDED_STYLES, EMBEDDED_HEADER, EMBEDDED_FOOTER },
    );
    var out: [expected.len]u8 = undefined;
    var title_buf: [TITLE_CAP]u8 = undefined;
    const written = wrapHtml(input, out[0..], title_buf[0..]);
    try std.testing.expectEqualStrings(
        expected,
        out[0..written],
    );
}
