// markdown-basic.zig
const std = @import("std");

const INPUT_CAP: u32 = 0x20000;
const OUTPUT_CAP: u32 = 0x40000;

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

    fn writeInline(self: *Writer, s: []const u8) void {
        var i: usize = 0;
        while (i < s.len and !self.overflow) {
            if (s[i] == '`') {
                if (std.mem.indexOfScalarPos(u8, s, i + 1, '`')) |end| {
                    self.writeSlice("<code>");
                    self.writeEscaped(s[i + 1 .. end]);
                    self.writeSlice("</code>");
                    i = end + 1;
                    continue;
                }
            }

            if (s[i] == '[') {
                if (std.mem.indexOfScalarPos(u8, s, i + 1, ']')) |close| {
                    if (close + 1 < s.len and s[close + 1] == '(') {
                        if (std.mem.indexOfScalarPos(u8, s, close + 2, ')')) |end| {
                            self.writeSlice("<a href=\"");
                            self.writeEscaped(s[close + 2 .. end]);
                            self.writeSlice("\">");
                            self.writeInline(s[i + 1 .. close]);
                            self.writeSlice("</a>");
                            i = end + 1;
                            continue;
                        }
                    }
                }
            }

            if (s[i] == '*' and i + 1 < s.len and s[i + 1] == '*') {
                if (findDouble(s, i + 2, '*')) |end| {
                    self.writeSlice("<strong>");
                    self.writeInline(s[i + 2 .. end]);
                    self.writeSlice("</strong>");
                    i = end + 2;
                    continue;
                }
            }

            if (s[i] == '_' and i + 1 < s.len and s[i + 1] == '_') {
                if (findDouble(s, i + 2, '_')) |end| {
                    self.writeSlice("<strong>");
                    self.writeInline(s[i + 2 .. end]);
                    self.writeSlice("</strong>");
                    i = end + 2;
                    continue;
                }
            }

            if (s[i] == '*' or s[i] == '_') {
                const ch = s[i];
                if (std.mem.indexOfScalarPos(u8, s, i + 1, ch)) |end| {
                    self.writeSlice("<em>");
                    self.writeInline(s[i + 1 .. end]);
                    self.writeSlice("</em>");
                    i = end + 1;
                    continue;
                }
            }

            self.writeEscaped(s[i .. i + 1]);
            i += 1;
        }
    }
};

fn findDouble(s: []const u8, start: usize, ch: u8) ?usize {
    var i = start;
    while (i + 1 < s.len) : (i += 1) {
        if (s[i] == ch and s[i + 1] == ch) return i;
    }
    return null;
}

fn isBlank(line: []const u8) bool {
    for (line) |ch| {
        if (ch != ' ' and ch != '\t' and ch != '\r') return false;
    }
    return true;
}

fn fenceLang(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "```")) return null;
    const rest = std.mem.trim(u8, trimmed[3..], " \t\r");
    return rest;
}

fn stripCR(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

fn blockquoteContent(line: []const u8) []const u8 {
    var content = line[1..];
    if (content.len > 0 and content[0] == ' ') {
        content = content[1..];
    }
    return content;
}

fn headingLevel(line: []const u8) ?struct { level: u8, text: []const u8 } {
    var i: usize = 0;
    while (i < line.len and line[i] == '#') : (i += 1) {}
    if (i == 0 or i > 3) return null;
    if (i < line.len and line[i] == ' ') {
        return .{ .level = @as(u8, @intCast(i)), .text = line[i + 1 ..] };
    }
    return null;
}

fn unorderedItem(line: []const u8) ?[]const u8 {
    if (line.len >= 2 and (line[0] == '-' or line[0] == '*') and line[1] == ' ') {
        return line[2..];
    }
    return null;
}

fn orderedItem(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    if (i == 0 or i + 1 >= line.len) return null;
    if (line[i] == '.' and line[i + 1] == ' ') {
        return line[i + 2 ..];
    }
    return null;
}

fn renderMarkdown(input: []const u8, output: []u8) usize {
    var w = Writer.init(output);

    var in_code = false;
    var in_ul = false;
    var in_ol = false;
    var in_blockquote = false;

    var i: usize = 0;
    while (i <= input.len and !w.overflow) {
        var line_end = i;
        while (line_end < input.len and input[line_end] != '\n') : (line_end += 1) {}
        const line = stripCR(input[i..line_end]);
        i = line_end + 1;

        if (in_code) {
            if (fenceLang(line) != null) {
                w.writeSlice("</code></pre>\n");
                in_code = false;
                continue;
            }
            w.writeEscaped(line);
            w.writeByte('\n');
            continue;
        }

        if (fenceLang(line)) |lang| {
            if (in_ul) {
                w.writeSlice("</ul>\n");
                in_ul = false;
            }
            if (in_ol) {
                w.writeSlice("</ol>\n");
                in_ol = false;
            }
            if (in_blockquote) {
                w.writeSlice("</blockquote>\n");
                in_blockquote = false;
            }
            w.writeSlice("<pre><code");
            if (lang.len > 0) {
                w.writeSlice(" class=\"language-");
                w.writeEscaped(lang);
                w.writeSlice("\">");
            } else {
                w.writeSlice(">");
            }
            in_code = true;
            continue;
        }

        if (isBlank(line)) {
            if (in_ul) {
                w.writeSlice("</ul>\n");
                in_ul = false;
            }
            if (in_ol) {
                w.writeSlice("</ol>\n");
                in_ol = false;
            }
            if (in_blockquote) {
                w.writeSlice("</blockquote>\n");
                in_blockquote = false;
            }
            continue;
        }

        if (line.len > 0 and line[0] == '>') {
            if (!in_blockquote) {
                if (in_ul) {
                    w.writeSlice("</ul>\n");
                    in_ul = false;
                }
                if (in_ol) {
                    w.writeSlice("</ol>\n");
                    in_ol = false;
                }
                w.writeSlice("<blockquote>\n");
                in_blockquote = true;
            }
            w.writeSlice("<p>");
            w.writeInline(blockquoteContent(line));
            w.writeSlice("</p>\n");
            continue;
        } else if (in_blockquote) {
            w.writeSlice("</blockquote>\n");
            in_blockquote = false;
        }

        if (headingLevel(line)) |h| {
            if (in_ul) {
                w.writeSlice("</ul>\n");
                in_ul = false;
            }
            if (in_ol) {
                w.writeSlice("</ol>\n");
                in_ol = false;
            }
            w.writeSlice("<h");
            w.writeByte(@as(u8, '0') + h.level);
            w.writeSlice(">");
            w.writeInline(h.text);
            w.writeSlice("</h");
            w.writeByte(@as(u8, '0') + h.level);
            w.writeSlice(">\n");
            continue;
        }

        if (unorderedItem(line)) |item| {
            if (in_ol) {
                w.writeSlice("</ol>\n");
                in_ol = false;
            }
            if (!in_ul) {
                w.writeSlice("<ul>\n");
                in_ul = true;
            }
            w.writeSlice("<li>");
            w.writeInline(item);
            w.writeSlice("</li>\n");
            continue;
        }

        if (orderedItem(line)) |item| {
            if (in_ul) {
                w.writeSlice("</ul>\n");
                in_ul = false;
            }
            if (!in_ol) {
                w.writeSlice("<ol>\n");
                in_ol = true;
            }
            w.writeSlice("<li>");
            w.writeInline(item);
            w.writeSlice("</li>\n");
            continue;
        }

        if (in_ul) {
            w.writeSlice("</ul>\n");
            in_ul = false;
        }
        if (in_ol) {
            w.writeSlice("</ol>\n");
            in_ol = false;
        }

        w.writeSlice("<p>");
        w.writeInline(line);
        w.writeSlice("</p>\n");
    }

    if (in_code) {
        w.writeSlice("</code></pre>\n");
    }
    if (in_ul) {
        w.writeSlice("</ul>\n");
    }
    if (in_ol) {
        w.writeSlice("</ol>\n");
    }
    if (in_blockquote) {
        w.writeSlice("</blockquote>\n");
    }

    return w.idx;
}

export fn run(input_size: u32) u32 {
    const input = input_buf[0..@as(usize, @intCast(input_size))];
    const output = output_buf[0..];
    const written = renderMarkdown(input, output);
    return @as(u32, @intCast(written));
}

test "heading and paragraph" {
    var out: [1024]u8 = undefined;
    const input = "# Title\nHello **World**\n";
    const written = renderMarkdown(input, out[0..]);
    try std.testing.expectEqualStrings(
        "<h1>Title</h1>\n<p>Hello <strong>World</strong></p>\n",
        out[0..written],
    );
}

test "lists" {
    var out: [1024]u8 = undefined;
    const input = "- a\n- b\n1. One\n2. Two\n";
    const written = renderMarkdown(input, out[0..]);
    try std.testing.expectEqualStrings(
        "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n<ol>\n<li>One</li>\n<li>Two</li>\n</ol>\n",
        out[0..written],
    );
}

test "blockquote and code block" {
    var out: [2048]u8 = undefined;
    const input = "> hi\n> there\n```js\nlet x = 1;\n```\n";
    const written = renderMarkdown(input, out[0..]);
    try std.testing.expectEqualStrings(
        "<blockquote>\n<p>hi</p>\n<p>there</p>\n</blockquote>\n<pre><code class=\"language-js\">let x = 1;\n</code></pre>\n",
        out[0..written],
    );
}

test "inline code and link" {
    var out: [1024]u8 = undefined;
    const input = "Use `code` and [link](http://a).\n";
    const written = renderMarkdown(input, out[0..]);
    try std.testing.expectEqualStrings(
        "<p>Use <code>code</code> and <a href=\"http://a\">link</a>.</p>\n",
        out[0..written],
    );
}

test "escaping" {
    var out: [1024]u8 = undefined;
    const input = "<tag> & \"quote\"\n";
    const written = renderMarkdown(input, out[0..]);
    try std.testing.expectEqualStrings(
        "<p>&lt;tag&gt; &amp; &quot;quote&quot;</p>\n",
        out[0..written],
    );
}
