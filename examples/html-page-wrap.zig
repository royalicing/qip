// html-page-wrap.zig
const std = @import("std");

const INPUT_CAP: u32 = 0x40000;
const OUTPUT_CAP: u32 = 0x80000;
const TITLE_CAP: usize = 1024;

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

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
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

    var start: usize = 0;
    var end: usize = w.idx;
    while (start < end and isSpace(buf[start])) : (start += 1) {}
    while (end > start and isSpace(buf[end - 1])) : (end -= 1) {}
    if (end <= start) return fallback;
    return buf[start..end];
}

fn wrapHtml(input: []const u8, output: []u8, title_buf: []u8) usize {
    var w = Writer.init(output);
    const title = extractTitle(input, title_buf);

    w.writeSlice("<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>");
    w.writeEscaped(title);
    w.writeSlice("</title><style>body{font-family:system-ui,sans-serif;line-height:1.5;}main{max-width:44em;margin:0 auto}code,pre{font-family:ui-monospace,monospace}pre{overflow:auto}img{max-width:100%;height:auto}@media (prefers-color-scheme: dark){body{background:#0f1115;color:#e6e6e6}a{color:#8ab4ff}}</style></head><body><main>");
    w.writeSlice(input);
    w.writeSlice("</main></body></html>");
    w.writeByte('\n');

    return w.idx;
}

export fn run(input_size: u32) u32 {
    const input = input_buf[0..@as(usize, @intCast(input_size))];
    const output = output_buf[0..];
    var title_buf: [TITLE_CAP]u8 = undefined;
    const written = wrapHtml(input, output, title_buf[0..]);
    return @as(u32, @intCast(written));
}

test "wraps with title from h1" {
    var out: [2048]u8 = undefined;
    var title_buf: [TITLE_CAP]u8 = undefined;
    const input = "<h1>Hello <em>World</em></h1><p>Hi</p>";
    const written = wrapHtml(input, out[0..], title_buf[0..]);
    try std.testing.expectEqualStrings(
        "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>Hello World</title><style>body{font-family:system-ui,sans-serif;line-height:1.5;}main{max-width:44em;margin:0 auto}code,pre{font-family:ui-monospace,monospace}pre{overflow:auto}img{max-width:100%;height:auto}@media (prefers-color-scheme: dark){body{background:#0f1115;color:#e6e6e6}a{color:#8ab4ff}}</style></head><body><main><h1>Hello <em>World</em></h1><p>Hi</p></main></body></html>\n",
        out[0..written],
    );
}

test "defaults title when no h1" {
    var out: [1024]u8 = undefined;
    var title_buf: [TITLE_CAP]u8 = undefined;
    const input = "<p>No heading</p>";
    const written = wrapHtml(input, out[0..], title_buf[0..]);
    try std.testing.expectEqualStrings(
        "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>Document</title><style>body{font-family:system-ui,sans-serif;line-height:1.5;}main{max-width:44em;margin:0 auto}code,pre{font-family:ui-monospace,monospace}pre{overflow:auto}img{max-width:100%;height:auto}@media (prefers-color-scheme: dark){body{background:#0f1115;color:#e6e6e6}a{color:#8ab4ff}}</style></head><body><main><p>No heading</p></main></body></html>\n",
        out[0..written],
    );
}
