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

            self.writeByte(s[i]);
            i += 1;
        }
    }
};

const HtmlBlockType = enum {
    none,
    type1,
    type2,
    type3,
    type4,
    type7,
};

fn trimIndent(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and i < 3 and line[i] == ' ') : (i += 1) {}
    return line[i..];
}

fn hasPipe(line: []const u8) bool {
    return std.mem.indexOfScalar(u8, line, '|') != null;
}

fn countCells(line: []const u8) usize {
    const s = trimIndent(line);
    if (s.len == 0) return 0;
    if (!hasPipe(s)) return 0;
    const leading_pipe = s[0] == '|';
    const trailing_pipe = s[s.len - 1] == '|';
    var count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        if (i == s.len or s[i] == '|') {
            const raw = s[start..i];
            const trimmed = std.mem.trim(u8, raw, " \t");
            if (!(trimmed.len == 0 and ((leading_pipe and count == 0) or (i == s.len and trailing_pipe)))) {
                count += 1;
            }
            start = i + 1;
        }
    }
    return count;
}

fn separatorCellValid(cell: []const u8) bool {
    if (cell.len < 3) return false;
    var i: usize = 0;
    if (cell[i] == ':') i += 1;
    var dashes: usize = 0;
    while (i < cell.len and cell[i] == '-') : (i += 1) {
        dashes += 1;
    }
    if (dashes < 3) return false;
    if (i < cell.len and cell[i] == ':') i += 1;
    return i == cell.len;
}

fn countSeparatorCells(line: []const u8) usize {
    const s = trimIndent(line);
    if (!hasPipe(s)) return 0;
    const leading_pipe = s[0] == '|';
    const trailing_pipe = s[s.len - 1] == '|';
    var count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        if (i == s.len or s[i] == '|') {
            const raw = s[start..i];
            const trimmed = std.mem.trim(u8, raw, " \t");
            if (!(trimmed.len == 0 and ((leading_pipe and count == 0) or (i == s.len and trailing_pipe)))) {
                if (!separatorCellValid(trimmed)) return 0;
                count += 1;
            }
            start = i + 1;
        }
    }
    return count;
}

fn isAsciiLetter(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
}

fn isTagNameChar(ch: u8) bool {
    return isAsciiLetter(ch) or (ch >= '0' and ch <= '9') or ch == '-' or ch == ':';
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    var i: usize = 0;
    while (i < prefix.len) : (i += 1) {
        if (std.ascii.toLower(s[i]) != std.ascii.toLower(prefix[i])) return false;
    }
    return true;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

fn isSpaceOrTab(ch: u8) bool {
    return ch == ' ' or ch == '\t';
}

fn writeTableRow(line: []const u8, w: *Writer, cell_tag: []const u8) void {
    const s = trimIndent(line);
    const leading_pipe = s.len > 0 and s[0] == '|';
    const trailing_pipe = s.len > 0 and s[s.len - 1] == '|';
    var start: usize = 0;
    var count: usize = 0;
    var i: usize = 0;
    while (i <= s.len and !w.overflow) : (i += 1) {
        if (i == s.len or s[i] == '|') {
            const raw = s[start..i];
            const trimmed = std.mem.trim(u8, raw, " \t");
            if (!(trimmed.len == 0 and ((leading_pipe and count == 0) or (i == s.len and trailing_pipe)))) {
                w.writeByte('<');
                w.writeSlice(cell_tag);
                w.writeByte('>');
                w.writeInline(trimmed);
                w.writeSlice("</");
                w.writeSlice(cell_tag);
                w.writeByte('>');
                count += 1;
            }
            start = i + 1;
        }
    }
}

fn matchesType1Start(s: []const u8) bool {
    const prefixes = [_][]const u8{ "<pre", "<script", "<style", "<textarea" };
    for (prefixes) |p| {
        if (startsWithIgnoreCase(s, p)) {
            if (s.len == p.len) return true;
            const next = s[p.len];
            return next == '>' or isSpaceOrTab(next);
        }
    }
    return false;
}

fn matchesType7Start(s: []const u8) bool {
    if (s.len < 3 or s[0] != '<') return false;
    if (startsWithIgnoreCase(s, "<!") or startsWithIgnoreCase(s, "<?")) return false;
    var end = s.len;
    while (end > 0 and isSpaceOrTab(s[end - 1])) : (end -= 1) {}
    if (end == 0 or s[end - 1] != '>') return false;
    var idx: usize = 1;
    if (s[idx] == '/') idx += 1;
    if (idx >= end or !isAsciiLetter(s[idx])) return false;
    idx += 1;
    while (idx < end and isTagNameChar(s[idx])) : (idx += 1) {}
    return true;
}

fn detectHtmlBlockStart(line: []const u8, prevBlank: bool) HtmlBlockType {
    const s = trimIndent(line);
    if (matchesType1Start(s)) return .type1;
    if (std.mem.startsWith(u8, s, "<!--")) return .type2;
    if (std.mem.startsWith(u8, s, "<?")) return .type3;
    if (std.mem.startsWith(u8, s, "<!") and s.len >= 3 and isAsciiLetter(s[2])) return .type4;
    if (prevBlank and matchesType7Start(s)) return .type7;
    return .none;
}

fn htmlBlockEnded(block: HtmlBlockType, line: []const u8) bool {
    return switch (block) {
        .type1 => containsIgnoreCase(line, "</pre>") or containsIgnoreCase(line, "</script>") or containsIgnoreCase(line, "</style>") or containsIgnoreCase(line, "</textarea>"),
        .type2 => std.mem.indexOf(u8, line, "-->") != null,
        .type3 => std.mem.indexOf(u8, line, "?>") != null,
        .type4 => std.mem.indexOfScalar(u8, line, '>') != null,
        .type7 => isBlank(line),
        else => false,
    };
}

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

fn stripFrontMatter(input: []const u8) []const u8 {
    var line_end: usize = 0;
    while (line_end < input.len and input[line_end] != '\n') : (line_end += 1) {}
    const first = stripCR(input[0..line_end]);
    const first_trimmed = std.mem.trim(u8, first, " \t\r");
    if (!std.mem.eql(u8, first_trimmed, "---")) {
        return input;
    }

    var i: usize = if (line_end < input.len) line_end + 1 else input.len;
    while (i <= input.len) {
        var le = i;
        while (le < input.len and input[le] != '\n') : (le += 1) {}
        const line = stripCR(input[i..le]);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, trimmed, "---") or std.mem.eql(u8, trimmed, "...")) {
            if (le < input.len) {
                return input[le + 1 ..];
            }
            return input[input.len..];
        }
        if (le >= input.len) break;
        i = le + 1;
    }
    return input;
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

    const body = stripFrontMatter(input);
    var in_code = false;
    var in_html: HtmlBlockType = .none;
    var in_ul = false;
    var in_ol = false;
    var in_blockquote = false;
    var prev_blank = true;

    var i: usize = 0;
    while (i <= body.len and !w.overflow) {
        var line_end = i;
        while (line_end < body.len and body[line_end] != '\n') : (line_end += 1) {}
        const line = stripCR(body[i..line_end]);
        i = line_end + 1;

        if (in_html != .none) {
            if (htmlBlockEnded(in_html, line)) {
                if (!isBlank(line)) {
                    w.writeSlice(line);
                    w.writeByte('\n');
                }
                in_html = .none;
                prev_blank = true;
                continue;
            }
            w.writeSlice(line);
            w.writeByte('\n');
            prev_blank = false;
            continue;
        }

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

        const html_block = detectHtmlBlockStart(line, prev_blank);
        if (html_block != .none) {
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
            if (htmlBlockEnded(html_block, line)) {
                if (!isBlank(line)) {
                    w.writeSlice(line);
                    w.writeByte('\n');
                }
                prev_blank = true;
                continue;
            }
            w.writeSlice(line);
            w.writeByte('\n');
            in_html = html_block;
            prev_blank = false;
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
            prev_blank = true;
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
            prev_blank = false;
            continue;
        } else if (in_blockquote) {
            w.writeSlice("</blockquote>\n");
            in_blockquote = false;
        }

        const header_cells = countCells(line);
        if (header_cells > 0) {
            const next_start = i;
            var next_end = next_start;
            var next_line: []const u8 = &[_]u8{};
            if (next_start < body.len) {
                while (next_end < body.len and body[next_end] != '\n') : (next_end += 1) {}
                next_line = stripCR(body[next_start..next_end]);
            }
            const sep_cells = countSeparatorCells(next_line);
            if (sep_cells == header_cells and sep_cells > 0) {
                if (in_ul) {
                    w.writeSlice("</ul>\n");
                    in_ul = false;
                }
                if (in_ol) {
                    w.writeSlice("</ol>\n");
                    in_ol = false;
                }
                w.writeSlice("<table>\n<thead>\n<tr>");
                writeTableRow(line, &w, "th");
                w.writeSlice("</tr>\n</thead>\n<tbody>\n");

                const row_i: usize = if (next_end < body.len) next_end + 1 else body.len;
                i = row_i;
                while (i < body.len and !w.overflow) {
                    var row_end = i;
                    while (row_end < body.len and body[row_end] != '\n') : (row_end += 1) {}
                    const row = stripCR(body[i..row_end]);
                    if (isBlank(row)) {
                        i = row_end + 1;
                        break;
                    }
                    if (countCells(row) == 0) {
                        break;
                    }
                    w.writeSlice("<tr>");
                    writeTableRow(row, &w, "td");
                    w.writeSlice("</tr>\n");
                    i = row_end + 1;
                }

                w.writeSlice("</tbody>\n</table>\n");
                prev_blank = true;
                continue;
            }
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
            prev_blank = false;
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
            prev_blank = false;
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
            prev_blank = false;
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
        prev_blank = false;
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

test "html passthrough" {
    var out: [1024]u8 = undefined;
    const input = "<tag> & \"quote\"\n";
    const written = renderMarkdown(input, out[0..]);
    try std.testing.expectEqualStrings(
        "<p><tag> & \"quote\"</p>\n",
        out[0..written],
    );
}

test "html block passthrough" {
    var out: [2048]u8 = undefined;
    const input = "<div>\n*hi*\n</div>\n\nafter\n";
    const written = renderMarkdown(input, out[0..]);
    try std.testing.expectEqualStrings(
        "<div>\n*hi*\n</div>\n<p>after</p>\n",
        out[0..written],
    );
}

test "table with inline code" {
    var out: [4096]u8 = undefined;
    const input = "| A | B |\n| --- | --- |\n| `x` | **y** |\n";
    const written = renderMarkdown(input, out[0..]);
    try std.testing.expectEqualStrings(
        "<table>\n<thead>\n<tr><th>A</th><th>B</th></tr>\n</thead>\n<tbody>\n<tr><td><code>x</code></td><td><strong>y</strong></td></tr>\n</tbody>\n</table>\n",
        out[0..written],
    );
}

test "code escapes html" {
    var out: [1024]u8 = undefined;
    const input = "`<b>`\n";
    const written = renderMarkdown(input, out[0..]);
    try std.testing.expectEqualStrings(
        "<p><code>&lt;b&gt;</code></p>\n",
        out[0..written],
    );
}

test "front matter stripped" {
    var out: [1024]u8 = undefined;
    const input = "---\ntitle: Test\n---\n# Hi\n";
    const written = renderMarkdown(input, out[0..]);
    try std.testing.expectEqualStrings(
        "<h1>Hi</h1>\n",
        out[0..written],
    );
}
