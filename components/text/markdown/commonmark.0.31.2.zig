const std = @import("std");

const INPUT_CAP: u32 = 0x200000;
const OUTPUT_CAP: u32 = 0x200000;

const INPUT_CONTENT_TYPE = "text/markdown";
const OUTPUT_CONTENT_TYPE = "text/html";

const MAX_LINES: usize = 131072;
const MAX_TMP: usize = @as(usize, INPUT_CAP);
const MAX_REF_DEFS: usize = 8192;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

var line_start: [MAX_LINES]u32 = undefined;
var line_end: [MAX_LINES]u32 = undefined;
var line_next: [MAX_LINES]u32 = undefined;
var lines_count: u32 = 0;

var tmp_buf: [MAX_TMP]u8 = undefined;
var tmp2_buf: [MAX_TMP]u8 = undefined;
var tmp3_buf: [MAX_TMP]u8 = undefined;
var ref_storage_buf: [MAX_TMP]u8 = undefined;
var ref_storage_len: usize = 0;

const RefDef = struct {
    label_hash: u64,
    href: []const u8,
    title: []const u8,
};

var ref_defs: [MAX_REF_DEFS]RefDef = undefined;
var ref_defs_count: u32 = 0;

const Writer = struct {
    buf: []u8,
    idx: usize,
    overflow: bool,

    fn init(buf: []u8) Writer {
        return .{ .buf = buf, .idx = 0, .overflow = false };
    }

    fn len(self: *const Writer) u32 {
        return @as(u32, @intCast(self.idx));
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
            const room = self.buf.len - self.idx;
            if (room > 0) {
                @memcpy(self.buf[self.idx..][0..room], s[0..room]);
                self.idx += room;
            }
            self.overflow = true;
            return;
        }
        @memcpy(self.buf[self.idx..][0..s.len], s);
        self.idx += s.len;
    }

    fn writeEscapedByte(self: *Writer, b: u8) void {
        switch (b) {
            '&' => self.writeSlice("&amp;"),
            '<' => self.writeSlice("&lt;"),
            '>' => self.writeSlice("&gt;"),
            '"' => self.writeSlice("&quot;"),
            else => self.writeByte(b),
        }
    }

    fn writeEscaped(self: *Writer, s: []const u8) void {
        for (s) |b| self.writeEscapedByte(b);
    }
};

const Indent = struct {
    cols: usize,
    idx: usize,
};

const Fence = struct {
    indent: usize,
    marker: u8,
    count: usize,
    info: []const u8,
};

const ListKind = enum {
    unordered,
    ordered,
};

const ListMarker = struct {
    kind: ListKind,
    marker: u8,
    indent_cols: usize,
    marker_end: usize,
    content_start: usize,
    ordered_start: usize,
    prefix_spaces: usize,
};

const HtmlBlockType = enum {
    none,
    type1,
    type2,
    type3,
    type4,
    type5,
    type6,
    type7,
};

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

fn isAsciiAlpha(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z');
}

fn isAsciiDigit(b: u8) bool {
    return b >= '0' and b <= '9';
}

fn isAsciiAlnum(b: u8) bool {
    return isAsciiAlpha(b) or isAsciiDigit(b);
}

fn isWhitespace(b: u8) bool {
    return b == ' ' or b == '\t';
}

fn isSpaceOrTab(b: u8) bool {
    return b == ' ' or b == '\t';
}

fn isTagNameChar(b: u8) bool {
    return isAsciiAlnum(b) or b == '-';
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

fn trimRightCR(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '\r') return s[0 .. s.len - 1];
    return s;
}

fn trimRightSpacesTabs(s0: []const u8) []const u8 {
    var s = trimRightCR(s0);
    while (s.len > 0 and (s[s.len - 1] == ' ' or s[s.len - 1] == '\t')) {
        s = s[0 .. s.len - 1];
    }
    return s;
}

fn trimAscii(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and (s[a] == ' ' or s[a] == '\t' or s[a] == '\n' or s[a] == '\r')) : (a += 1) {}
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t' or s[b - 1] == '\n' or s[b - 1] == '\r')) : (b -= 1) {}
    return s[a..b];
}

fn lowerAscii(b: u8) u8 {
    if (b >= 'A' and b <= 'Z') return b + 32;
    return b;
}

fn foldReferenceCodepoint(cp: u21) u21 {
    if (cp >= 'A' and cp <= 'Z') return cp + 32;
    if (cp >= 0x00C0 and cp <= 0x00D6) return cp + 32;
    if (cp >= 0x00D8 and cp <= 0x00DE) return cp + 32;
    if (cp >= 0x0391 and cp <= 0x03A1) return cp + 32;
    if (cp >= 0x03A3 and cp <= 0x03AB) return cp + 32;
    if (cp >= 0x0410 and cp <= 0x042F) return cp + 32;
    return cp;
}

fn normalizeLabelHash(label_raw: []const u8) u64 {
    const s = trimAscii(label_raw);
    var h: u64 = 14695981039346656037;
    var i: usize = 0;
    var in_ws = false;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len and (s[i + 1] == '[' or s[i + 1] == ']')) {
            const b = s[i + 1];
            i += 2;
            if (b == ' ' or b == '\t' or b == '\n' or b == '\r') {
                in_ws = true;
                continue;
            }
            if (in_ws) {
                h = (h ^ @as(u64, ' ')) *% 1099511628211;
                in_ws = false;
            }
            h = (h ^ @as(u64, lowerAscii(b))) *% 1099511628211;
            continue;
        }

        if (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r') {
            i += 1;
            in_ws = true;
            continue;
        }

        if (in_ws) {
            h = (h ^ @as(u64, ' ')) *% 1099511628211;
            in_ws = false;
        }

        if (s[i] < 0x80) {
            h = (h ^ @as(u64, lowerAscii(s[i]))) *% 1099511628211;
            i += 1;
            continue;
        }

        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            h = (h ^ @as(u64, s[i])) *% 1099511628211;
            i += 1;
            continue;
        };
        if (i + n > s.len) {
            h = (h ^ @as(u64, s[i])) *% 1099511628211;
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + n]) catch {
            h = (h ^ @as(u64, s[i])) *% 1099511628211;
            i += 1;
            continue;
        };
        if (cp == 0x00DF or cp == 0x1E9E) {
            if (in_ws) {
                h = (h ^ @as(u64, ' ')) *% 1099511628211;
                in_ws = false;
            }
            h = (h ^ @as(u64, 's')) *% 1099511628211;
            h = (h ^ @as(u64, 's')) *% 1099511628211;
            i += n;
            continue;
        }
        const folded = foldReferenceCodepoint(cp);
        var enc: [4]u8 = undefined;
        const m = std.unicode.utf8Encode(folded, &enc) catch {
            h = (h ^ @as(u64, s[i])) *% 1099511628211;
            i += 1;
            continue;
        };
        var k: usize = 0;
        while (k < m) : (k += 1) {
            h = (h ^ @as(u64, enc[k])) *% 1099511628211;
        }
        i += n;
    }
    return h;
}

fn isBlankLine(s0: []const u8) bool {
    const s = trimRightCR(s0);
    for (s) |b| {
        if (!isWhitespace(b)) return false;
    }
    return true;
}

fn leadingIndent(s0: []const u8) Indent {
    const s = trimRightCR(s0);
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == ' ') {
            cols += 1;
            i += 1;
            continue;
        }
        if (s[i] == '\t') {
            cols = ((cols / 4) + 1) * 4;
            i += 1;
            continue;
        }
        break;
    }
    return .{ .cols = cols, .idx = i };
}

fn stripIndentCols(s0: []const u8, want_cols: usize) []const u8 {
    const s = trimRightCR(s0);
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len and cols < want_cols) {
        if (s[i] == ' ') {
            cols += 1;
            i += 1;
            continue;
        }
        if (s[i] == '\t') {
            cols = ((cols / 4) + 1) * 4;
            i += 1;
            continue;
        }
        break;
    }
    return s[i..];
}

fn stripBlockIndentUpTo3(s0: []const u8) []const u8 {
    const s = trimRightCR(s0);
    const ind = leadingIndent(s);
    if (ind.cols <= 3) return s[ind.idx..];
    return s;
}

fn stripAllLeadingSpacesTabs(s0: []const u8) []const u8 {
    const s = trimRightCR(s0);
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    return s[i..];
}

fn appendStrippedIndent(dst: *Writer, s0: []const u8, want_cols: usize) void {
    const s = trimRightCR(s0);
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len and cols < want_cols) {
        if (s[i] == ' ') {
            cols += 1;
            i += 1;
            continue;
        }
        if (s[i] == '\t') {
            const next_cols = ((cols / 4) + 1) * 4;
            i += 1;
            if (next_cols <= want_cols) {
                cols = next_cols;
                continue;
            }
            const keep_spaces = next_cols - want_cols;
            var k: usize = 0;
            while (k < keep_spaces) : (k += 1) dst.writeByte(' ');
            cols = want_cols;
            break;
        }
        break;
    }
    dst.writeSlice(s[i..]);
}

fn appendListContinuation(dst: *Writer, s0: []const u8, base_cols: usize) void {
    const s = trimRightCR(s0);
    const ind = leadingIndent(s);
    const rel_cols = if (ind.cols > base_cols) ind.cols - base_cols else 0;
    var i: usize = 0;
    while (i < rel_cols) : (i += 1) dst.writeByte(' ');
    dst.writeSlice(s[ind.idx..]);
}

fn appendBlockquoteStripped(dst: *Writer, s0: []const u8) bool {
    const s = trimRightCR(s0);
    const ind = leadingIndent(s);
    if (ind.cols > 3 or ind.idx >= s.len or s[ind.idx] != '>') return false;

    var p = ind.idx + 1;
    var keep_cols: usize = 0;
    if (p < s.len and s[p] == ' ') {
        p += 1;
    } else if (p < s.len and s[p] == '\t') {
        const col_after_marker = ind.cols + 1;
        const tab_to = ((col_after_marker / 4) + 1) * 4;
        const tab_width = tab_to - col_after_marker;
        p += 1;
        if (tab_width > 0) keep_cols = tab_width - 1;
    }

    const rem = s[p..];
    const rem_ind = leadingIndent(rem);
    var k: usize = 0;
    while (k < keep_cols + rem_ind.cols) : (k += 1) dst.writeByte(' ');
    dst.writeSlice(rem[rem_ind.idx..]);
    return true;
}

fn splitLines(input: []const u8) bool {
    lines_count = 0;
    var cursor: usize = 0;
    while (cursor < input.len) {
        if (lines_count >= MAX_LINES) return false;
        const start = cursor;
        var end = cursor;
        while (end < input.len and input[end] != '\n') : (end += 1) {}
        var logical_end = end;
        if (logical_end > start and input[logical_end - 1] == '\r') {
            logical_end -= 1;
        }
        if (end < input.len and input[end] == '\n') end += 1;

        const i = @as(usize, @intCast(lines_count));
        line_start[i] = @as(u32, @intCast(start));
        line_end[i] = @as(u32, @intCast(logical_end));
        line_next[i] = @as(u32, @intCast(end));
        lines_count += 1;
        cursor = end;
    }

    if (input.len == 0) {
        lines_count = 0;
    }
    return true;
}

fn lineSlice(input: []const u8, idx_u32: u32) []const u8 {
    const idx = @as(usize, @intCast(idx_u32));
    const a = @as(usize, @intCast(line_start[idx]));
    const b = @as(usize, @intCast(line_end[idx]));
    return input[a..b];
}

fn lineRawSlice(input: []const u8, idx_u32: u32) []const u8 {
    const idx = @as(usize, @intCast(idx_u32));
    const a = @as(usize, @intCast(line_start[idx]));
    const b = @as(usize, @intCast(line_next[idx]));
    return input[a..b];
}

fn parseATXHeading(line0: []const u8) ?struct { level: u8, text: []const u8 } {
    const line = trimRightCR(line0);
    const ind = leadingIndent(line);
    if (ind.cols > 3) return null;
    var i = ind.idx;
    var level: u8 = 0;
    var total_hashes: usize = 0;
    while (i < line.len and line[i] == '#') : (i += 1) {
        total_hashes += 1;
        if (level < 6) level += 1;
    }
    if (level == 0) return null;
    if (total_hashes > 6) return null;
    if (i < line.len and !isWhitespace(line[i])) return null;

    while (i < line.len and isWhitespace(line[i])) : (i += 1) {}
    var text = line[i..];

    // Trim optional closing sequence of #.
    var end = text.len;
    while (end > 0 and isWhitespace(text[end - 1])) : (end -= 1) {}
    var k = end;
    while (k > 0 and text[k - 1] == '#') : (k -= 1) {}
    if (k < end and (k == 0 or isWhitespace(text[k - 1]))) {
        while (k > 0 and isWhitespace(text[k - 1])) : (k -= 1) {}
        text = text[0..k];
    } else {
        text = text[0..end];
    }

    return .{ .level = level, .text = text };
}

fn parseThematicBreak(line0: []const u8) bool {
    const line = trimRightCR(line0);
    const ind = leadingIndent(line);
    if (ind.cols > 3) return false;
    var i = ind.idx;
    if (i >= line.len) return false;
    const marker = line[i];
    if (!(marker == '*' or marker == '-' or marker == '_')) return false;

    var count: usize = 0;
    while (i < line.len) : (i += 1) {
        const b = line[i];
        if (b == marker) {
            count += 1;
            continue;
        }
        if (isWhitespace(b)) continue;
        return false;
    }
    return count >= 3;
}

fn parseSetextUnderline(line0: []const u8) ?u8 {
    const line = trimRightCR(line0);
    const ind = leadingIndent(line);
    if (ind.cols > 3) return null;
    var i = ind.idx;
    if (i >= line.len) return null;
    const marker = line[i];
    if (!(marker == '=' or marker == '-')) return null;
    var count: usize = 0;
    while (i < line.len and line[i] == marker) : (i += 1) count += 1;
    if (count == 0) return null;
    while (i < line.len and isWhitespace(line[i])) : (i += 1) {}
    if (i != line.len) return null;
    return if (marker == '=') 1 else 2;
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

fn isType6TagName(name: []const u8) bool {
    const tags = [_][]const u8{
        "address", "article", "aside", "base", "basefont", "blockquote", "body",
        "caption", "center", "col", "colgroup", "dd", "details", "dialog", "dir",
        "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form",
        "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header",
        "hr", "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem",
        "nav", "noframes", "ol", "optgroup", "option", "p", "param", "search",
        "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead",
        "title", "tr", "track", "ul",
    };
    for (tags) |tag| {
        if (std.ascii.eqlIgnoreCase(name, tag)) return true;
    }
    return false;
}

fn matchesType6Start(s: []const u8) bool {
    if (s.len < 3 or s[0] != '<') return false;
    var i: usize = 1;
    if (s[i] == '/') i += 1;
    if (i >= s.len or !isAsciiAlpha(s[i])) return false;
    const start = i;
    i += 1;
    while (i < s.len and isTagNameChar(s[i])) : (i += 1) {}
    const name = s[start..i];
    if (!isType6TagName(name)) return false;
    if (i >= s.len) return true;
    const c = s[i];
    return c == '>' or c == '/' or isSpaceOrTab(c);
}

fn matchesType7Start(s0: []const u8) bool {
    var s = s0;
    while (s.len > 0 and isSpaceOrTab(s[s.len - 1])) {
        s = s[0 .. s.len - 1];
    }
    if (s.len < 3 or s[0] != '<' or s[s.len - 1] != '>') return false;
    if (startsWithIgnoreCase(s, "<!") or startsWithIgnoreCase(s, "<?")) return false;
    return isPlausibleInlineTag(s[1 .. s.len - 1]);
}

fn detectHtmlBlockStart(line0: []const u8, prev_blank: bool) HtmlBlockType {
    const line = trimRightCR(line0);
    const ind = leadingIndent(line);
    if (ind.cols > 3) return .none;
    const s = line[ind.idx..];
    if (s.len == 0) return .none;

    if (matchesType1Start(s)) return .type1;
    if (std.mem.startsWith(u8, s, "<!--")) return .type2;
    if (std.mem.startsWith(u8, s, "<?")) return .type3;
    if (std.mem.startsWith(u8, s, "<!") and s.len >= 3 and isAsciiAlpha(s[2])) return .type4;
    if (std.mem.startsWith(u8, s, "<![CDATA[")) return .type5;
    if (matchesType6Start(s)) return .type6;
    if (prev_blank and matchesType7Start(s)) return .type7;
    return .none;
}

fn htmlBlockEnds(block: HtmlBlockType, line: []const u8, next_is_blank: bool) bool {
    return switch (block) {
        .type1 => containsIgnoreCase(line, "</pre>") or containsIgnoreCase(line, "</script>") or containsIgnoreCase(line, "</style>") or containsIgnoreCase(line, "</textarea>"),
        .type2 => std.mem.indexOf(u8, line, "-->") != null,
        .type3 => std.mem.indexOf(u8, line, "?>") != null,
        .type4 => std.mem.indexOfScalar(u8, line, '>') != null,
        .type5 => std.mem.indexOf(u8, line, "]]>") != null,
        .type6, .type7 => next_is_blank,
        else => false,
    };
}

fn parseFenceOpen(line0: []const u8) ?Fence {
    const line = trimRightCR(line0);
    const ind = leadingIndent(line);
    if (ind.cols > 3) return null;
    var i = ind.idx;
    if (i >= line.len) return null;
    const marker = line[i];
    if (!(marker == '`' or marker == '~')) return null;

    var count: usize = 0;
    while (i < line.len and line[i] == marker) : (i += 1) count += 1;
    if (count < 3) return null;

    if (marker == '`') {
        var j = i;
        while (j < line.len) : (j += 1) {
            if (line[j] == '`') return null;
        }
    }

    while (i < line.len and isWhitespace(line[i])) : (i += 1) {}
    return .{
        .indent = ind.cols,
        .marker = marker,
        .count = count,
        .info = trimAscii(line[i..]),
    };
}

fn isFenceClose(line0: []const u8, fence: Fence) bool {
    const line = trimRightCR(line0);
    const ind = leadingIndent(line);
    if (ind.cols > 3) return false;
    var i = ind.idx;
    var count: usize = 0;
    while (i < line.len and line[i] == fence.marker) : (i += 1) count += 1;
    if (count < fence.count) return false;
    while (i < line.len) : (i += 1) {
        if (!isWhitespace(line[i])) return false;
    }
    return true;
}

fn parseListMarker(line0: []const u8) ?ListMarker {
    const line = trimRightCR(line0);
    const ind = leadingIndent(line);
    const i = ind.idx;
    if (i >= line.len) return null;

    if (line[i] == '-' or line[i] == '+' or line[i] == '*') {
        if (i + 1 < line.len and !isWhitespace(line[i + 1])) return null;
        var content = i + 1;
        var prefix_spaces: usize = 0;
        if (content < line.len and isWhitespace(line[content])) {
            if (line[content] == '\t') {
                const col_after_marker = ind.cols + (content - ind.idx);
                const tab_to = ((col_after_marker / 4) + 1) * 4;
                const tab_width = tab_to - col_after_marker;
                if (tab_width > 0) prefix_spaces = tab_width - 1;
                content += 1;
            } else {
                var p = content;
                while (p < line.len and line[p] == ' ') : (p += 1) {}
                const space_count = p - content;
                if (space_count <= 4) {
                    content = p;
                } else {
                    content += 1;
                }
            }
        }
        return .{
            .kind = .unordered,
            .marker = line[i],
            .indent_cols = ind.cols,
            .marker_end = i + 1,
            .content_start = content,
            .ordered_start = 1,
            .prefix_spaces = prefix_spaces,
        };
    }

    var j = i;
    var num: usize = 0;
    var digits: usize = 0;
    while (j < line.len and isAsciiDigit(line[j]) and digits < 9) : (j += 1) {
        num = num * 10 + @as(usize, line[j] - '0');
        digits += 1;
    }
    if (digits == 0 or j >= line.len) return null;
    const delim = line[j];
    if (!(delim == '.' or delim == ')')) return null;
    if (j + 1 < line.len and !isWhitespace(line[j + 1])) return null;
    var content = j + 1;
    var prefix_spaces: usize = 0;
    if (content < line.len and isWhitespace(line[content])) {
        if (line[content] == '\t') {
            const col_after_marker = ind.cols + (content - ind.idx);
            const tab_to = ((col_after_marker / 4) + 1) * 4;
            const tab_width = tab_to - col_after_marker;
            if (tab_width > 0) prefix_spaces = tab_width - 1;
            content += 1;
        } else {
            var p = content;
            while (p < line.len and line[p] == ' ') : (p += 1) {}
            const space_count = p - content;
            if (space_count <= 4) {
                content = p;
            } else {
                content += 1;
            }
        }
    }

    return .{
        .kind = .ordered,
        .marker = delim,
        .indent_cols = ind.cols,
        .marker_end = j + 1,
        .content_start = content,
        .ordered_start = num,
        .prefix_spaces = prefix_spaces,
    };
}

fn canInterruptParagraphWithList(line0: []const u8) bool {
    const ind = leadingIndent(line0);
    if (ind.cols > 3) return false;
    const mark = parseListMarker(line0) orelse return false;
    const line = trimRightCR(line0);
    if (mark.content_start >= line.len) return false;
    if (trimAscii(line[mark.content_start..]).len == 0) return false;
    if (mark.kind == .ordered and mark.ordered_start != 1) return false;
    return true;
}

fn isPunctuation(b: u8) bool {
    return (b >= 33 and b <= 47) or
        (b >= 58 and b <= 64) or
        (b >= 91 and b <= 96) or
        (b >= 123 and b <= 126);
}

fn isDelimiterPunctuation(b: u8) bool {
    return isPunctuation(b) or b >= 128;
}

fn isLikelyURIScheme(s: []const u8) bool {
    if (s.len < 2 or s.len > 32) return false;
    if (!isAsciiAlpha(s[0])) return false;
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        const b = s[i];
        if (isAsciiAlnum(b) or b == '+' or b == '-' or b == '.') continue;
        return false;
    }
    return true;
}

fn isEntity(s: []const u8) bool {
    if (s.len < 3) return false;
    if (s[0] != '&' or s[s.len - 1] != ';') return false;
    if (s[1] == '#') {
        if (s.len >= 4 and (s[2] == 'x' or s[2] == 'X')) {
            if (s.len <= 4) return false;
            var hex_digits: usize = 0;
            var i: usize = 3;
            while (i + 1 < s.len) : (i += 1) {
                const b = s[i];
                if (!((b >= '0' and b <= '9') or (b >= 'a' and b <= 'f') or (b >= 'A' and b <= 'F'))) return false;
                hex_digits += 1;
            }
            return hex_digits >= 1 and hex_digits <= 6;
        }
        var dec_digits: usize = 0;
        var j: usize = 2;
        if (j >= s.len - 1) return false;
        while (j < s.len - 1) : (j += 1) {
            if (!isAsciiDigit(s[j])) return false;
            dec_digits += 1;
        }
        return dec_digits >= 1 and dec_digits <= 7;
    }

    var k: usize = 1;
    while (k < s.len - 1) : (k += 1) {
        if (!isAsciiAlnum(s[k])) return false;
    }
    return true;
}

fn decodeNamedEntity(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "amp")) return "&";
    if (std.mem.eql(u8, name, "lt")) return "<";
    if (std.mem.eql(u8, name, "gt")) return ">";
    if (std.mem.eql(u8, name, "quot")) return "\"";
    if (std.mem.eql(u8, name, "apos")) return "'";
    if (std.mem.eql(u8, name, "nbsp")) return "\xC2\xA0";
    if (std.mem.eql(u8, name, "copy")) return "\xC2\xA9";
    if (std.mem.eql(u8, name, "AElig")) return "\xC3\x86";
    if (std.mem.eql(u8, name, "Auml")) return "\xC3\x84";
    if (std.mem.eql(u8, name, "auml")) return "\xC3\xA4";
    if (std.mem.eql(u8, name, "Dcaron")) return "\xC4\x8E";
    if (std.mem.eql(u8, name, "ouml")) return "\xC3\xB6";
    if (std.mem.eql(u8, name, "frac34")) return "\xC2\xBE";
    if (std.mem.eql(u8, name, "HilbertSpace")) return "\xE2\x84\x8B";
    if (std.mem.eql(u8, name, "DifferentialD")) return "\xE2\x85\x86";
    if (std.mem.eql(u8, name, "ClockwiseContourIntegral")) return "\xE2\x88\xB2";
    if (std.mem.eql(u8, name, "ngE")) return "\xE2\x89\xA7\xCC\xB8";
    return null;
}

fn decodeEntityToBuf(ent: []const u8, out_buf: *[8]u8) ?[]const u8 {
    if (ent.len < 3 or ent[0] != '&' or ent[ent.len - 1] != ';') return null;
    const body = ent[1 .. ent.len - 1];
    if (body.len == 0) return null;

    if (body[0] == '#') {
        var cp: u32 = 0;
        if (body.len >= 2 and (body[1] == 'x' or body[1] == 'X')) {
            if (body.len == 2) return null;
            var i: usize = 2;
            while (i < body.len) : (i += 1) {
                const b = body[i];
                var d: u32 = 0;
                if (b >= '0' and b <= '9') d = b - '0' else if (b >= 'a' and b <= 'f') d = 10 + (b - 'a') else if (b >= 'A' and b <= 'F') d = 10 + (b - 'A') else return null;
                cp = cp * 16 + d;
            }
        } else {
            if (body.len == 1) return null;
            var i: usize = 1;
            while (i < body.len) : (i += 1) {
                const b = body[i];
                if (b < '0' or b > '9') return null;
                cp = cp * 10 + (b - '0');
            }
        }

        if (cp == 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) cp = 0xFFFD;
        const n = std.unicode.utf8Encode(@as(u21, @intCast(cp)), out_buf) catch return null;
        return out_buf[0..n];
    }

    return decodeNamedEntity(body);
}

fn parseInlineLinkDestination(s: []const u8, start: usize) ?struct { href: []const u8, title: []const u8, next: usize } {
    var i = start;
    while (i < s.len and isWhitespace(s[i])) : (i += 1) {}
    if (i >= s.len) return null;

    var href: []const u8 = "";
    if (s[i] == '<') {
        const href_start = i + 1;
        var close: usize = href_start;
        while (close < s.len and s[close] != '>') : (close += 1) {
            if (s[close] == '\n' or s[close] == '<' or s[close] == '\\') return null;
        }
        if (close >= s.len) return null;
        href = normalizeLinkDestination(s[href_start..close], tmp3_buf[0..]);
        i = close + 1;
    } else {
        const href_start = i;
        var paren_depth: usize = 0;
        while (i < s.len) {
            const ch = s[i];
            if (ch == '\n' or ch == '\r') break;
            if (ch == '\\' and i + 1 < s.len and isPunctuation(s[i + 1])) {
                i += 2;
                continue;
            }
            if (isWhitespace(ch)) break;
            if (ch == '(') {
                paren_depth += 1;
                i += 1;
                continue;
            }
            if (ch == ')') {
                if (paren_depth == 0) break;
                paren_depth -= 1;
                i += 1;
                continue;
            }
            i += 1;
        }
        href = normalizeLinkDestination(s[href_start..i], tmp3_buf[0..]);
    }

    var had_sep = false;
    while (i < s.len and (isWhitespace(s[i]) or s[i] == '\n' or s[i] == '\r')) : (i += 1) had_sep = true;
    var title: []const u8 = "";
    if (i < s.len and s[i] != ')') {
        if (!had_sep) return null;
        const open = s[i];
        var close_ch: u8 = 0;
        if (open == '"' or open == '\'') {
            close_ch = open;
        } else if (open == '(') {
            close_ch = ')';
        } else {
            return null;
        }

        i += 1;
        const title_start = i;
        while (i < s.len and s[i] != close_ch) {
            if (s[i] == '\\' and i + 1 < s.len and isPunctuation(s[i + 1])) {
                i += 2;
                continue;
            }
            if (s[i] == '\n') return null;
            i += 1;
        }
        if (i >= s.len) return null;
        title = s[title_start..i];
        i += 1;
        while (i < s.len and isWhitespace(s[i])) : (i += 1) {}
    }

    if (i >= s.len or s[i] != ')') return null;
    return .{ .href = href, .title = title, .next = i + 1 };
}

fn normalizeLinkDestination(raw: []const u8, out_buf: []u8) []const u8 {
    var w = Writer.init(out_buf);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len and isPunctuation(raw[i + 1])) {
            w.writeByte(raw[i + 1]);
            i += 2;
            continue;
        }
        if (raw[i] == '&') {
            var semi = i + 1;
            while (semi < raw.len and semi - i <= 32 and raw[semi] != ';' and raw[semi] != '\n') : (semi += 1) {}
            if (semi < raw.len and raw[semi] == ';') {
                const ent = raw[i .. semi + 1];
                var dec_buf: [8]u8 = undefined;
                if (isEntity(ent)) {
                    if (decodeEntityToBuf(ent, &dec_buf)) |decoded| {
                        w.writeSlice(decoded);
                        i = semi + 1;
                        continue;
                    }
                }
            }
        }
        w.writeByte(raw[i]);
        i += 1;
    }
    return w.buf[0..w.idx];
}

const ParsedReferenceTail = struct {
    href: []const u8,
    title: []const u8,
};

fn parseReferenceDefTail(tail_raw: []const u8) ?ParsedReferenceTail {
    const s = trimAscii(tail_raw);
    if (s.len == 0) return null;

    var p: usize = 0;
    var href: []const u8 = "";
    if (s[p] == '<') {
        p += 1;
        const hs = p;
        while (p < s.len and s[p] != '>') : (p += 1) {
            if (s[p] == '\n' or s[p] == '<') return null;
        }
        if (p >= s.len) return null;
        href = s[hs..p];
        p += 1;
    } else {
        const hs = p;
        while (p < s.len and !isWhitespace(s[p]) and s[p] != '\n') : (p += 1) {}
        if (p == hs) return null;
        href = s[hs..p];
    }

    var had_sep = false;
    while (p < s.len and (isWhitespace(s[p]) or s[p] == '\n' or s[p] == '\r')) : (p += 1) had_sep = true;
    var title: []const u8 = "";
    if (p < s.len) {
        if (!had_sep) return null;
        const open = s[p];
        var close_ch: u8 = 0;
        if (open == '"' or open == '\'') {
            close_ch = open;
        } else if (open == '(') {
            close_ch = ')';
        } else {
            return null;
        }
        p += 1;
        const ts = p;
        while (p < s.len and s[p] != close_ch) {
            if (s[p] == '\\' and p + 1 < s.len and isPunctuation(s[p + 1])) {
                p += 2;
                continue;
            }
            p += 1;
        }
        if (p >= s.len) return null;
        title = s[ts..p];
        p += 1;
        while (p < s.len and (isWhitespace(s[p]) or s[p] == '\n' or s[p] == '\r')) : (p += 1) {}
        if (p != s.len) return null;
    }

    return .{ .href = href, .title = title };
}

fn parseReferenceDefLine(line0: []const u8) ?struct { label_hash: u64, href: []const u8, title: []const u8 } {
    const line = trimRightCR(line0);
    const ind = leadingIndent(line);
    if (ind.cols > 3) return null;
    var i = ind.idx;
    if (i >= line.len or line[i] != '[') return null;
    i += 1;
    const label_start = i;
    const label_end = findUnescapedRightBracket(line, i) orelse return null;
    if (label_end == label_start) return null;
    const label = line[label_start..label_end];
    if (!isValidReferenceLabel(label)) return null;
    i = label_end + 1;
    if (i >= line.len or line[i] != ':') return null;
    i += 1;
    if (parseReferenceDefTail(line[i..])) |tail| {
        return .{
            .label_hash = normalizeLabelHash(label),
            .href = tail.href,
            .title = tail.title,
        };
    }
    return null;
}

const ParsedReferenceDef = struct {
    label_hash: u64,
    href: []const u8,
    title: []const u8,
    next_idx: u32,
};

fn parseReferenceDefAt(input: []const u8, idx: u32) ?ParsedReferenceDef {
    const first = lineSlice(input, idx);
    const first_raw = trimRightCR(first);
    const ind = leadingIndent(first_raw);
    if (ind.cols > 3) return null;

    var line_idx = idx;
    var line = first_raw;
    var p = ind.idx;
    if (p >= line.len or line[p] != '[') return null;
    p += 1;

    var label_writer = Writer.init(tmp_buf[0..]);
    while (true) {
        while (p < line.len) : (p += 1) {
            if (line[p] == ']' and !isEscapedAt(line, p)) {
                if (label_writer.idx == 0) return null;
                p += 1;
                if (p >= line.len or line[p] != ':') return null;
                p += 1;

                const label = label_writer.buf[0..label_writer.idx];
                if (!isValidReferenceLabel(label)) return null;
                var combined = Writer.init(tmp3_buf[0..]);
                combined.writeSlice(line[p..]);
                if (combined.overflow) return null;

                var best: ?ParsedReferenceDef = null;
                if (parseReferenceDefTail(combined.buf[0..combined.idx])) |tail| {
                    best = .{
                        .label_hash = normalizeLabelHash(label),
                        .href = tail.href,
                        .title = tail.title,
                        .next_idx = line_idx + 1,
                    };
                }

                var j = line_idx + 1;
                while (j < lines_count) : (j += 1) {
                    const ln = lineSlice(input, j);
                    if (isBlankLine(ln)) break;

                    combined.writeByte('\n');
                    const li = leadingIndent(ln);
                    if (li.cols >= 4) {
                        combined.writeSlice(stripIndentCols(ln, 4));
                    } else {
                        combined.writeSlice(stripBlockIndentUpTo3(ln));
                    }
                    if (combined.overflow) break;

                    if (parseReferenceDefTail(combined.buf[0..combined.idx])) |tail| {
                        best = .{
                            .label_hash = normalizeLabelHash(label),
                            .href = tail.href,
                            .title = tail.title,
                            .next_idx = j + 1,
                        };
                    }
                }

                return best;
            }
            if (line[p] == '[' and !isEscapedAt(line, p)) return null;
            label_writer.writeByte(line[p]);
            if (label_writer.overflow) return null;
        }

        line_idx += 1;
        if (line_idx >= lines_count) return null;
        const next_line = lineSlice(input, line_idx);
        if (isBlankLine(next_line)) return null;
        label_writer.writeByte('\n');
        if (label_writer.overflow) return null;
        line = trimRightCR(next_line);
        p = 0;
    }
}

fn isValidReferenceLabel(label: []const u8) bool {
    if (label.len == 0 or label.len > 999) return false;
    var has_non_ws = false;
    var i: usize = 0;
    while (i < label.len) : (i += 1) {
        if ((label[i] == '[' or label[i] == ']') and !isEscapedAt(label, i)) return false;
        if (!(label[i] == ' ' or label[i] == '\t' or label[i] == '\n' or label[i] == '\r')) has_non_ws = true;
    }
    return has_non_ws;
}

fn collectReferenceDefs(input: []const u8) void {
    ref_defs_count = 0;
    ref_storage_len = 0;
    var i: u32 = 0;
    while (i < lines_count and ref_defs_count < MAX_REF_DEFS) {
        const line = lineSlice(input, i);
        if (isBlankLine(line)) {
            i += 1;
            continue;
        }

        const ind = leadingIndent(line);
        if (ind.cols >= 4) {
            i += 1;
            while (i < lines_count) {
                const ln = lineSlice(input, i);
                if (isBlankLine(ln)) {
                    i += 1;
                    continue;
                }
                if (leadingIndent(ln).cols >= 4) {
                    i += 1;
                    continue;
                }
                break;
            }
            continue;
        }

        if (parseFenceOpen(line)) |fence| {
            i += 1;
            while (i < lines_count) : (i += 1) {
                if (isFenceClose(lineSlice(input, i), fence)) {
                    i += 1;
                    break;
                }
            }
            continue;
        }

        const prev_blank = if (i == 0) true else isBlankLine(lineSlice(input, i - 1));
        const html_block = detectHtmlBlockStart(line, prev_blank);
        if (html_block != .none) {
            while (i < lines_count) : (i += 1) {
                const next_is_blank = i + 1 >= lines_count or isBlankLine(lineSlice(input, i + 1));
                if (htmlBlockEnds(html_block, trimRightCR(lineSlice(input, i)), next_is_blank)) {
                    if ((html_block == .type6 or html_block == .type7) and i + 1 < lines_count and isBlankLine(lineSlice(input, i + 1))) {
                        i += 1;
                    }
                    i += 1;
                    break;
                }
            }
            continue;
        }

        if (parseReferenceDefAt(input, i)) |def| {
            if (!pushReferenceDef(def.label_hash, def.href, def.title)) break;
            i = def.next_idx;
            continue;
        }

        if (parseATXHeading(line) != null) {
            i += 1;
            continue;
        }
        if (parseThematicBreak(line)) {
            i += 1;
            continue;
        }
        if (parseListMarker(line) != null) {
            i += 1;
            continue;
        }
        if (ind.cols <= 3 and ind.idx < line.len and line[ind.idx] == '>') {
            var stripped = Writer.init(tmp2_buf[0..]);
            if (appendBlockquoteStripped(&stripped, line)) {
                if (parseReferenceDefLine(stripped.buf[0..stripped.idx])) |p| {
                    if (!pushReferenceDef(p.label_hash, p.href, p.title)) break;
                }
            }
            i += 1;
            continue;
        }

        var j = i + 1;
        while (j < lines_count) : (j += 1) {
            const l = lineSlice(input, j);
            if (isBlankLine(l)) break;
            if (parseATXHeading(l) != null) break;
            if (parseThematicBreak(l)) break;
            if (parseFenceOpen(l) != null) break;
            if (canInterruptParagraphWithList(l)) break;
            const l_prev_blank = if (j == 0) true else isBlankLine(lineSlice(input, j - 1));
            const l_html_block = detectHtmlBlockStart(l, l_prev_blank);
            if (l_html_block != .none and l_html_block != .type7) break;
            const li = leadingIndent(l);
            if (li.cols <= 3 and li.idx < l.len and l[li.idx] == '>') break;
        }
        i = j;
    }
}

fn pushReferenceDef(label_hash: u64, href_src: []const u8, title_src: []const u8) bool {
    var k: u32 = 0;
    while (k < ref_defs_count) : (k += 1) {
        if (ref_defs[@as(usize, @intCast(k))].label_hash == label_hash) return true;
    }
    if (ref_defs_count >= MAX_REF_DEFS) return false;
    if (ref_storage_len + href_src.len + title_src.len > ref_storage_buf.len) return false;

    const href_start = ref_storage_len;
    @memcpy(ref_storage_buf[href_start..][0..href_src.len], href_src);
    ref_storage_len += href_src.len;
    const href = ref_storage_buf[href_start..ref_storage_len];

    const title_start = ref_storage_len;
    @memcpy(ref_storage_buf[title_start..][0..title_src.len], title_src);
    ref_storage_len += title_src.len;
    const title = ref_storage_buf[title_start..ref_storage_len];

    ref_defs[@as(usize, @intCast(ref_defs_count))] = .{
        .label_hash = label_hash,
        .href = href,
        .title = title,
    };
    ref_defs_count += 1;
    return true;
}

fn lookupRefDef(label: []const u8) ?RefDef {
    const h = normalizeLabelHash(label);
    var i: u32 = 0;
    while (i < ref_defs_count) : (i += 1) {
        const def = ref_defs[@as(usize, @intCast(i))];
        if (def.label_hash == h) return def;
    }
    return null;
}

fn writeLinkAttrEscaped(out: *Writer, src: []const u8) void {
    var decoded = Writer.init(tmp3_buf[0..]);
    var i: usize = 0;
    while (i < src.len and !decoded.overflow) {
        if (src[i] == '\\' and i + 1 < src.len and isPunctuation(src[i + 1])) {
            decoded.writeByte(src[i + 1]);
            i += 2;
            continue;
        }
        if (src[i] == '&') {
            var semi = i + 1;
            while (semi < src.len and semi - i <= 32 and src[semi] != ';' and src[semi] != '\n') : (semi += 1) {}
            if (semi < src.len and src[semi] == ';') {
                const ent = src[i .. semi + 1];
                var dec_buf: [8]u8 = undefined;
                if (isEntity(ent)) {
                    if (decodeEntityToBuf(ent, &dec_buf)) |decoded_ent| {
                        decoded.writeSlice(decoded_ent);
                        i = semi + 1;
                        continue;
                    }
                }
            }
        }
        decoded.writeByte(src[i]);
        i += 1;
    }
    if (decoded.overflow) return;

    var j: usize = 0;
    while (j < decoded.idx) : (j += 1) {
        out.writeEscapedByte(decoded.buf[j]);
    }
}

fn isURISafeByte(b: u8) bool {
    if ((b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9')) return true;
    return b == '-' or b == '_' or b == '.' or b == '~' or
        b == ':' or b == '/' or b == '?' or b == '#' or
        b == '[' or b == ']' or b == '@' or
        b == '!' or b == '$' or b == '&' or b == '\'' or
        b == '(' or b == ')' or b == '*' or b == '+' or
        b == ',' or b == ';' or b == '=' or b == '%';
}

fn writeURIAttrEscaped(out: *Writer, src: []const u8) void {
    var decoded = Writer.init(tmp3_buf[0..]);
    var i: usize = 0;
    while (i < src.len and !decoded.overflow) {
        if (src[i] == '\\' and i + 1 < src.len and isPunctuation(src[i + 1])) {
            decoded.writeByte(src[i + 1]);
            i += 2;
            continue;
        }
        if (src[i] == '&') {
            var semi = i + 1;
            while (semi < src.len and semi - i <= 32 and src[semi] != ';' and src[semi] != '\n') : (semi += 1) {}
            if (semi < src.len and src[semi] == ';') {
                const ent = src[i .. semi + 1];
                var dec_buf: [8]u8 = undefined;
                if (isEntity(ent)) {
                    if (decodeEntityToBuf(ent, &dec_buf)) |decoded_ent| {
                        decoded.writeSlice(decoded_ent);
                        i = semi + 1;
                        continue;
                    }
                }
            }
        }
        decoded.writeByte(src[i]);
        i += 1;
    }
    if (decoded.overflow) return;

    const hex = "0123456789ABCDEF";
    var j: usize = 0;
    while (j < decoded.idx) : (j += 1) {
        const b = decoded.buf[j];
        if (isURISafeByte(b)) {
            switch (b) {
                '&' => out.writeSlice("&amp;"),
                '"' => out.writeSlice("&quot;"),
                else => out.writeByte(b),
            }
        } else {
            out.writeByte('%');
            out.writeByte(hex[(b >> 4) & 0x0F]);
            out.writeByte(hex[b & 0x0F]);
        }
    }
}

fn writeRawURIAttrEscaped(out: *Writer, src: []const u8) void {
    const hex = "0123456789ABCDEF";
    for (src) |b| {
        if (isURISafeByte(b) and b != '[' and b != ']') {
            switch (b) {
                '&' => out.writeSlice("&amp;"),
                '"' => out.writeSlice("&quot;"),
                else => out.writeByte(b),
            }
        } else {
            out.writeByte('%');
            out.writeByte(hex[(b >> 4) & 0x0F]);
            out.writeByte(hex[b & 0x0F]);
        }
    }
}

fn writeCodeSpan(out: *Writer, src: []const u8) void {
    var norm = Writer.init(tmp3_buf[0..]);
    for (src) |b| {
        if (b == '\n') {
            norm.writeByte(' ');
        } else {
            norm.writeByte(b);
        }
    }
    if (norm.overflow) return;

    var start: usize = 0;
    var end: usize = norm.idx;
    if (end >= 2 and norm.buf[0] == ' ' and norm.buf[end - 1] == ' ') {
        var all_spaces = true;
        var i: usize = 0;
        while (i < end) : (i += 1) {
            if (norm.buf[i] != ' ') {
                all_spaces = false;
                break;
            }
        }
        if (!all_spaces) {
            start += 1;
            end -= 1;
        }
    }

    var i: usize = start;
    while (i < end) : (i += 1) {
        out.writeEscapedByte(norm.buf[i]);
    }
}

fn writeAutolink(out: *Writer, inner: []const u8) bool {
    if (inner.len == 0) return false;
    for (inner) |b| {
        if (b == '<' or b == '>' or b == ' ' or b == '\t' or b == '\n') return false;
    }

    if (std.mem.indexOfScalar(u8, inner, ':')) |colon| {
        if (!isLikelyURIScheme(inner[0..colon])) return false;
        out.writeSlice("<a href=\"");
        writeRawURIAttrEscaped(out, inner);
        out.writeSlice("\">");
        out.writeEscaped(inner);
        out.writeSlice("</a>");
        return true;
    }

    if (std.mem.indexOfScalar(u8, inner, '@') != null and std.mem.indexOfScalar(u8, inner, '\\') == null) {
        out.writeSlice("<a href=\"mailto:");
        writeRawURIAttrEscaped(out, inner);
        out.writeSlice("\">");
        out.writeEscaped(inner);
        out.writeSlice("</a>");
        return true;
    }

    return false;
}

fn findMatchingRun(s: []const u8, from: usize, marker: u8, count: usize) ?usize {
    var i = from;
    while (i < s.len) {
        if (s[i] != marker) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < s.len and s[j] == marker) : (j += 1) {}
        const n = j - i;
        if (n == count) return i;
        i = j;
    }
    return null;
}

fn isEscapedAt(s: []const u8, idx: usize) bool {
    if (idx == 0) return false;
    var bs: usize = 0;
    var i = idx;
    while (i > 0) {
        i -= 1;
        if (s[i] == '\\') {
            bs += 1;
            continue;
        }
        break;
    }
    return (bs & 1) == 1;
}

fn findUnescapedRightBracket(s: []const u8, from: usize) ?usize {
    var depth: usize = 0;
    var i = from;
    while (i < s.len) : (i += 1) {
        if (isEscapedAt(s, i) or isInsideCodeSpan(s, from, i) or isInsideInlineTag(s, from, i)) continue;
        if (s[i] == '[') {
            depth += 1;
            continue;
        }
        if (s[i] == ']') {
            if (depth == 0) return i;
            depth -= 1;
            continue;
        }
    }
    return null;
}

fn isInlineSpace(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == '\r';
}

fn isInlineSpaceAt(s: []const u8, idx: usize) bool {
    const b = s[idx];
    if (isInlineSpace(b)) return true;
    if (b == 0xC2 and idx + 1 < s.len and s[idx + 1] == 0xA0) return true;
    if (b == 0xA0 and idx > 0 and s[idx - 1] == 0xC2) return true;
    return false;
}

fn canOpenDelimiter(s: []const u8, pos: usize, run_len: usize, marker: u8) bool {
    const prev_opt: ?u8 = if (pos == 0) null else s[pos - 1];
    const next_idx = pos + run_len;
    const next_opt: ?u8 = if (next_idx >= s.len) null else s[next_idx];

    const prev_ws = prev_opt == null or isInlineSpaceAt(s, pos - 1);
    const next_ws = next_opt == null or isInlineSpaceAt(s, next_idx);
    const prev_punct = prev_opt != null and isDelimiterPunctuation(prev_opt.?);
    const next_punct = next_opt != null and isDelimiterPunctuation(next_opt.?);

    if (marker == '_' and prev_opt != null and next_opt != null and prev_opt.? >= 128 and next_opt.? >= 128) {
        return false;
    }

    const left_flanking = !next_ws and (!next_punct or prev_ws or prev_punct);
    const right_flanking = !prev_ws and (!prev_punct or next_ws or next_punct);

    if (marker == '_') {
        return left_flanking and (!right_flanking or prev_punct);
    }
    return left_flanking;
}

fn canCloseDelimiter(s: []const u8, pos: usize, run_len: usize, marker: u8) bool {
    const prev_opt: ?u8 = if (pos == 0) null else s[pos - 1];
    const next_idx = pos + run_len;
    const next_opt: ?u8 = if (next_idx >= s.len) null else s[next_idx];

    const prev_ws = prev_opt == null or isInlineSpaceAt(s, pos - 1);
    const next_ws = next_opt == null or isInlineSpaceAt(s, next_idx);
    const prev_punct = prev_opt != null and isDelimiterPunctuation(prev_opt.?);
    const next_punct = next_opt != null and isDelimiterPunctuation(next_opt.?);

    if (marker == '_' and prev_opt != null and next_opt != null and prev_opt.? >= 128 and next_opt.? >= 128) {
        return false;
    }

    const left_flanking = !next_ws and (!next_punct or prev_ws or prev_punct);
    const right_flanking = !prev_ws and (!prev_punct or next_ws or next_punct);

    if (marker == '_') {
        return right_flanking and (!left_flanking or next_punct);
    }
    return right_flanking;
}

fn findMatchingEmphasisRun(s: []const u8, from: usize, marker: u8, count: usize) ?usize {
    var i = from;
    while (i < s.len) : (i += 1) {
        if (s[i] != marker) continue;
        if (isEscapedAt(s, i)) continue;
        if (isInsideCodeSpan(s, from, i)) continue;
        if (isInsideInlineTag(s, from, i)) continue;
        var j = i;
        while (j < s.len and s[j] == marker) : (j += 1) {}
        const run_len = j - i;
        if (run_len < count) {
            i = j - 1;
            continue;
        }
        if (!canCloseDelimiter(s, i, run_len, marker)) {
            i = j - 1;
            continue;
        }
        if (i + 1 < s.len and s[i + 1] == ']') {
            if (findMatchingOpenBracketForClose(s, from, i + 1)) |open_idx| {
                const link_label = s[open_idx + 1 .. i + 1];
                var closes_valid_link = false;
                if (i + 2 < s.len and s[i + 2] == '(') {
                    if (parseInlineLinkDestination(s, i + 3) != null) {
                        if (!containsNestedInlineLink(link_label)) closes_valid_link = true;
                    }
                } else if (i + 2 < s.len and s[i + 2] == '[') {
                    if (findUnescapedRightBracket(s, i + 3)) |ref_close| {
                        var ref_label = s[i + 3 .. ref_close];
                        if (ref_close == i + 3) ref_label = link_label;
                        if (lookupRefDef(ref_label) != null and !containsNestedInlineLink(link_label)) {
                            closes_valid_link = true;
                        }
                    }
                } else if (lookupRefDef(link_label) != null and !containsNestedInlineLink(link_label)) {
                    closes_valid_link = true;
                }
                if (closes_valid_link) {
                    i = j - 1;
                    continue;
                }
            }
        }
        if (count == 1 and run_len > 1 and canOpenDelimiter(s, i, run_len, marker) and hasCloseDelimiterRun(s, j, marker, count)) {
            i = j - 1;
            continue;
        }
        const has_inner_open = hasOpenDelimiterRun(s, from, i, marker, count);

        // Prefer nesting when an earlier closer would consume text that contains
        // an opener which can pair internally and there is another closer later.
        if (has_inner_open and hasCloseDelimiterRun(s, j, marker, count)) {
            i = j - 1;
            continue;
        }
        // If this closer run has no spare markers and there is an inner opener
        // with no later closer available, let the inner opener claim it.
        if (count > 1 and has_inner_open and run_len == count and !hasCloseDelimiterRunInRange(s, from, i, marker, count) and !hasCloseDelimiterRun(s, j, marker, count)) {
            i = j - 1;
            continue;
        }
        const other_marker: u8 = if (marker == '*') '_' else '*';
        const has_other_marker_between = if (from < i) std.mem.indexOfScalar(u8, s[from..i], other_marker) != null else false;
        if (count == 1 and run_len == 1 and !has_other_marker_between and has_inner_open and !hasCloseDelimiterRunInRange(s, from, i, marker, count) and !hasCloseDelimiterRun(s, j, marker, count)) {
            i = j - 1;
            continue;
        }
        // If this closer run has spare markers and we saw inner openers, shift
        // consumption right by the amount needed for inner pairs first.
        if (run_len > count) {
            const inner_open_chars = countOpenDelimiterChars(s, from, i, marker, 1);
            if (inner_open_chars > 0) {
                const max_shift = run_len - count;
                const shift = @min(inner_open_chars, max_shift);
                if (shift > 0) return i + shift;
            }
        }
        return i;
    }
    return null;
}

fn hasOpenDelimiterRun(s: []const u8, from: usize, to: usize, marker: u8, count: usize) bool {
    var i = from;
    while (i < to and i < s.len) : (i += 1) {
        if (s[i] != marker) continue;
        if (isEscapedAt(s, i)) continue;
        if (isInsideCodeSpan(s, from, i)) continue;
        if (isInsideInlineTag(s, from, i)) continue;
        var j = i;
        while (j < to and j < s.len and s[j] == marker) : (j += 1) {}
        const run_len = j - i;
        if (run_len >= count and canOpenDelimiter(s, i, run_len, marker)) return true;
        i = j - 1;
    }
    return false;
}

fn countOpenDelimiterChars(s: []const u8, from: usize, to: usize, marker: u8, count: usize) usize {
    var total: usize = 0;
    var i = from;
    while (i < to and i < s.len) : (i += 1) {
        if (s[i] != marker) continue;
        if (isEscapedAt(s, i)) continue;
        if (isInsideCodeSpan(s, from, i)) continue;
        if (isInsideInlineTag(s, from, i)) continue;
        var j = i;
        while (j < to and j < s.len and s[j] == marker) : (j += 1) {}
        const run_len = j - i;
        if (run_len >= count and canOpenDelimiter(s, i, run_len, marker)) {
            total += (run_len / count) * count;
        }
        i = j - 1;
    }
    return total;
}

fn hasCloseDelimiterRun(s: []const u8, from: usize, marker: u8, count: usize) bool {
    var i = from;
    while (i < s.len) : (i += 1) {
        if (s[i] != marker) continue;
        if (isEscapedAt(s, i)) continue;
        if (isInsideCodeSpan(s, from, i)) continue;
        if (isInsideInlineTag(s, from, i)) continue;
        var j = i;
        while (j < s.len and s[j] == marker) : (j += 1) {}
        const run_len = j - i;
        if (run_len >= count and canCloseDelimiter(s, i, run_len, marker)) return true;
        i = j - 1;
    }
    return false;
}

fn hasCloseDelimiterRunInRange(s: []const u8, from: usize, to: usize, marker: u8, count: usize) bool {
    var i = from;
    while (i < to and i < s.len) : (i += 1) {
        if (s[i] != marker) continue;
        if (isEscapedAt(s, i)) continue;
        if (isInsideCodeSpan(s, from, i)) continue;
        if (isInsideInlineTag(s, from, i)) continue;
        var j = i;
        while (j < to and j < s.len and s[j] == marker) : (j += 1) {}
        const run_len = j - i;
        if (run_len >= count and canCloseDelimiter(s, i, run_len, marker)) return true;
        i = j - 1;
    }
    return false;
}

fn hasUnescapedOpenBracketInRange(s: []const u8, from: usize, to: usize) bool {
    var i = from;
    while (i < to and i < s.len) : (i += 1) {
        if (s[i] != '[') continue;
        if (isEscapedAt(s, i)) continue;
        if (isInsideCodeSpan(s, from, i)) continue;
        return true;
    }
    return false;
}

fn findMatchingOpenBracketForClose(s: []const u8, from: usize, close_idx: usize) ?usize {
    var depth: usize = 0;
    var k = close_idx;
    while (k > from) {
        k -= 1;
        if (isEscapedAt(s, k) or isInsideCodeSpan(s, from, k)) continue;
        if (s[k] == ']') {
            depth += 1;
            continue;
        }
        if (s[k] == '[') {
            if (depth == 0) return k;
            depth -= 1;
        }
    }
    return null;
}

fn countCloseDelimiterChars(s: []const u8, from: usize, marker: u8, count: usize) usize {
    var total: usize = 0;
    var i = from;
    while (i < s.len) : (i += 1) {
        if (s[i] != marker) continue;
        if (isEscapedAt(s, i)) continue;
        if (isInsideCodeSpan(s, from, i)) continue;
        if (isInsideInlineTag(s, from, i)) continue;
        var j = i;
        while (j < s.len and s[j] == marker) : (j += 1) {}
        const run_len = j - i;
        if (run_len >= count and canCloseDelimiter(s, i, run_len, marker)) {
            total += (run_len / count) * count;
        }
        i = j - 1;
    }
    return total;
}

fn isInsideCodeSpan(s: []const u8, from: usize, pos: usize) bool {
    var i = from;
    while (i < pos and i < s.len) {
        if (s[i] != '`') {
            i += 1;
            continue;
        }
        var ticks: usize = 1;
        while (i + ticks < s.len and s[i + ticks] == '`') : (ticks += 1) {}
        if (findMatchingRun(s, i + ticks, '`', ticks)) |end_idx| {
            if (end_idx >= pos) return true;
            i = end_idx + ticks;
            continue;
        }
        i += ticks;
    }
    return false;
}

fn isInsideInlineTag(s: []const u8, from: usize, pos: usize) bool {
    var i = from;
    while (i < pos and i < s.len) {
        if (s[i] != '<') {
            i += 1;
            continue;
        }
        if (std.mem.indexOfScalarPos(u8, s, i + 1, '>')) |gt| {
            if (gt >= pos) return true;
            i = gt + 1;
            continue;
        }
        i += 1;
    }
    return false;
}

fn appendImageAltPlain(out: *Writer, s: []const u8) void {
    var i: usize = 0;
    while (i < s.len and !out.overflow) {
        if (s[i] == '\\' and i + 1 < s.len and isPunctuation(s[i + 1])) {
            out.writeByte(s[i + 1]);
            i += 2;
            continue;
        }
        if (s[i] == '&') {
            var semi = i + 1;
            while (semi < s.len and semi - i <= 32 and s[semi] != ';' and s[semi] != '\n') : (semi += 1) {}
            if (semi < s.len and s[semi] == ';') {
                const ent = s[i .. semi + 1];
                var dec_buf: [8]u8 = undefined;
                if (isEntity(ent)) {
                    if (decodeEntityToBuf(ent, &dec_buf)) |decoded_ent| {
                        out.writeSlice(decoded_ent);
                        i = semi + 1;
                        continue;
                    }
                }
            }
        }
        if (s[i] == '!' and i + 1 < s.len and s[i + 1] == '[') {
            if (findUnescapedRightBracket(s, i + 2)) |close| {
                if (close + 1 < s.len and s[close + 1] == '(') {
                    if (parseInlineLinkDestination(s, close + 2)) |dest| {
                        appendImageAltPlain(out, s[i + 2 .. close]);
                        i = dest.next;
                        continue;
                    }
                }
            }
        }
        if (s[i] == '[') {
            if (findUnescapedRightBracket(s, i + 1)) |close| {
                if (close + 1 < s.len and s[close + 1] == '(') {
                    if (parseInlineLinkDestination(s, close + 2)) |dest| {
                        const label = s[i + 1 .. close];
                        if (!containsNestedInlineLink(label)) {
                            appendImageAltPlain(out, label);
                            i = dest.next;
                            continue;
                        }
                    }
                }
            }
        }
        if (s[i] == '*' or s[i] == '_') {
            const marker = s[i];
            var run_len: usize = 1;
            while (i + run_len < s.len and s[i + run_len] == marker) : (run_len += 1) {}
            const can_open = canOpenDelimiter(s, i, run_len, marker);
            if (can_open and run_len >= 2) {
                if (findMatchingEmphasisRun(s, i + 2, marker, 2)) |end2| {
                    if (end2 > i + 2) {
                        appendImageAltPlain(out, s[i + 2 .. end2]);
                        i = end2 + 2;
                        continue;
                    }
                }
            }
            if (can_open) {
                if (findMatchingEmphasisRun(s, i + 1, marker, 1)) |end1| {
                    if (end1 > i + 1) {
                        appendImageAltPlain(out, s[i + 1 .. end1]);
                        i = end1 + 1;
                        continue;
                    }
                }
            }
        }
        if (s[i] == '<') {
            var p = i + 1;
            while (p < s.len and s[p] != '>') : (p += 1) {}
            if (p < s.len and s[p] == '>') {
                i = p + 1;
                continue;
            }
        }
        out.writeByte(s[i]);
        i += 1;
    }
}

fn buildImageAltText(label_raw: []const u8, out_buf: []u8) []const u8 {
    var w = Writer.init(out_buf);
    appendImageAltPlain(&w, label_raw);
    return w.buf[0..w.idx];
}

fn canContinueTagAfterNewline(prefix: []const u8) bool {
    if (prefix.len == 0) return false;
    var i: usize = 0;
    const is_close = prefix[0] == '/';
    if (is_close) {
        i = 1;
        if (i >= prefix.len or !isAsciiAlpha(prefix[i])) return false;
    } else if (!isAsciiAlpha(prefix[0])) {
        return false;
    }
    i += 1;
    while (i < prefix.len and isTagNameChar(prefix[i])) : (i += 1) {}

    if (is_close) {
        while (i < prefix.len and isSpaceOrTab(prefix[i])) : (i += 1) {}
        return i == prefix.len;
    }

    var quote: u8 = 0;
    while (i < prefix.len) : (i += 1) {
        const ch = prefix[i];
        if (quote != 0) {
            if (ch == quote) quote = 0;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        if (ch == '<') return false;
        if (isSpaceOrTab(ch) or isAsciiAlnum(ch) or ch == '_' or ch == ':' or ch == '-' or ch == '.' or ch == '=' or ch == '/') continue;
        return false;
    }
    return true;
}

fn isPlausibleInlineTag(inner: []const u8) bool {
    if (inner.len == 0) return false;
    var i: usize = 0;
    const is_close = inner[0] == '/';
    if (is_close) {
        i = 1;
        if (i >= inner.len or !isAsciiAlpha(inner[i])) return false;
    } else if (!isAsciiAlpha(inner[i])) {
        return false;
    }
    i += 1;
    while (i < inner.len and isTagNameChar(inner[i])) : (i += 1) {}

    if (is_close) {
        while (i < inner.len and (isSpaceOrTab(inner[i]) or inner[i] == '\n')) : (i += 1) {}
        return i == inner.len;
    }
    if (i < inner.len and !(isSpaceOrTab(inner[i]) or inner[i] == '\n' or inner[i] == '/')) return false;

    while (true) {
        while (i < inner.len and (isSpaceOrTab(inner[i]) or inner[i] == '\n')) : (i += 1) {}
        if (i >= inner.len) return true;
        if (inner[i] == '/') {
            i += 1;
            return i == inner.len;
        }

        if (!isAttrNameChar(inner[i])) return false;
        i += 1;
        while (i < inner.len and isAttrNameChar(inner[i])) : (i += 1) {}

        while (i < inner.len and (isSpaceOrTab(inner[i]) or inner[i] == '\n')) : (i += 1) {}
        if (i >= inner.len) return true;
        if (inner[i] != '=') continue;

        i += 1;
        while (i < inner.len and (isSpaceOrTab(inner[i]) or inner[i] == '\n')) : (i += 1) {}
        if (i >= inner.len) return false;

        if (inner[i] == '"' or inner[i] == '\'') {
            const quote = inner[i];
            i += 1;
            while (i < inner.len and inner[i] != quote) : (i += 1) {}
            if (i >= inner.len) return false;
            i += 1;
            if (i < inner.len and !(isSpaceOrTab(inner[i]) or inner[i] == '\n' or inner[i] == '/')) return false;
            continue;
        }

        if (!isUnquotedAttrValueChar(inner[i])) return false;
        i += 1;
        while (i < inner.len and isUnquotedAttrValueChar(inner[i])) : (i += 1) {}
        if (i < inner.len and !(isSpaceOrTab(inner[i]) or inner[i] == '\n' or inner[i] == '/')) return false;
    }
}

fn isAttrNameChar(b: u8) bool {
    return isAsciiAlnum(b) or b == '_' or b == ':' or b == '-' or b == '.';
}

fn isUnquotedAttrValueChar(b: u8) bool {
    if (isSpaceOrTab(b) or b == '\n') return false;
    if (b == '"' or b == '\'' or b == '=' or b == '<' or b == '>' or b == '`') return false;
    return true;
}

fn containsNestedInlineLink(label: []const u8) bool {
    var i: usize = 0;
    while (i < label.len) : (i += 1) {
        if (label[i] != '[') continue;
        if (isEscapedAt(label, i)) continue;
        if (i > 0 and label[i - 1] == '!' and !isEscapedAt(label, i - 1)) continue;
        if (findUnescapedRightBracket(label, i + 1)) |close| {
            if (close + 1 < label.len and label[close + 1] == '(') {
                if (parseInlineLinkDestination(label, close + 2) != null) return true;
            }
            if (close + 1 < label.len and label[close + 1] == '[') {
                if (findUnescapedRightBracket(label, close + 2)) |ref_close| {
                    var ref_label = label[close + 2 .. ref_close];
                    if (ref_close == close + 2) ref_label = label[i + 1 .. close];
                    if (lookupRefDef(ref_label) != null) return true;
                }
            } else if (lookupRefDef(label[i + 1 .. close]) != null) {
                return true;
            }
        }
    }
    return false;
}

fn writeInline(out: *Writer, s: []const u8) void {
    var i: usize = 0;
    while (i < s.len and !out.overflow) {
        const b = s[i];

        if (b == ' ') {
            var j = i;
            while (j < s.len and s[j] == ' ') : (j += 1) {}
            if (j < s.len and s[j] == '\n') {
                if (j - i >= 2) {
                    out.writeSlice("<br />\n");
                    i = j + 1;
                    continue;
                }
                i = j;
                continue;
            }
            while (i < j) : (i += 1) out.writeByte(' ');
            continue;
        }

        if (b == '\\') {
            if (i + 1 < s.len and s[i + 1] == '\n') {
                out.writeSlice("<br />\n");
                i += 2;
                continue;
            }
            if (i + 1 < s.len and isPunctuation(s[i + 1])) {
                out.writeEscapedByte(s[i + 1]);
                i += 2;
                continue;
            }
            out.writeByte('\\');
            i += 1;
            continue;
        }

        if (b == '\n') {
            out.writeByte('\n');
            i += 1;
            continue;
        }

        if (b == '`') {
            var ticks: usize = 1;
            while (i + ticks < s.len and s[i + ticks] == '`') : (ticks += 1) {}
            if (findMatchingRun(s, i + ticks, '`', ticks)) |end_idx| {
                out.writeSlice("<code>");
                writeCodeSpan(out, s[i + ticks .. end_idx]);
                out.writeSlice("</code>");
                i = end_idx + ticks;
                continue;
            }
            var t: usize = 0;
            while (t < ticks) : (t += 1) out.writeByte('`');
            i += ticks;
            continue;
        }

        if (b == '[') {
            if (findUnescapedRightBracket(s, i + 1)) |close| {
                if (close + 1 < s.len and s[close + 1] == '(') {
                    if (parseInlineLinkDestination(s, close + 2)) |dest| {
                        const label = s[i + 1 .. close];
                        if (!containsNestedInlineLink(label)) {
                            out.writeSlice("<a href=\"");
                            writeURIAttrEscaped(out, dest.href);
                            out.writeByte('"');
                            if (dest.title.len > 0) {
                                out.writeSlice(" title=\"");
                                writeLinkAttrEscaped(out, dest.title);
                                out.writeByte('"');
                            }
                            out.writeByte('>');
                            writeInline(out, label);
                            out.writeSlice("</a>");
                            i = dest.next;
                            continue;
                        }
                    }
                }

                var ref_label = s[i + 1 .. close];
                var ref_next = close + 1;
                if (close + 1 < s.len and s[close + 1] == '[') {
                    if (findUnescapedRightBracket(s, close + 2)) |ref_close| {
                        if (ref_close == close + 2) {
                            ref_label = s[i + 1 .. close];
                        } else {
                            ref_label = s[close + 2 .. ref_close];
                        }
                        ref_next = ref_close + 1;
                    }
                }

                if (lookupRefDef(ref_label)) |ref_def| {
                    const label = s[i + 1 .. close];
                    if (!containsNestedInlineLink(label)) {
                        out.writeSlice("<a href=\"");
                        writeURIAttrEscaped(out, ref_def.href);
                        out.writeByte('"');
                        if (ref_def.title.len > 0) {
                            out.writeSlice(" title=\"");
                            writeLinkAttrEscaped(out, ref_def.title);
                            out.writeByte('"');
                        }
                        out.writeByte('>');
                        writeInline(out, label);
                        out.writeSlice("</a>");
                        i = ref_next;
                        continue;
                    }
                }
            }
        }

        if (b == '!' and i + 1 < s.len and s[i + 1] == '[') {
            if (findUnescapedRightBracket(s, i + 2)) |close| {
                const label = s[i + 2 .. close];
                if (close + 1 < s.len and s[close + 1] == '(') {
                    if (parseInlineLinkDestination(s, close + 2)) |dest| {
                        out.writeSlice("<img src=\"");
                        writeURIAttrEscaped(out, dest.href);
                        out.writeSlice("\" alt=\"");
                        const alt = buildImageAltText(label, tmp_buf[0..]);
                        writeLinkAttrEscaped(out, alt);
                        out.writeByte('"');
                        if (dest.title.len > 0) {
                            out.writeSlice(" title=\"");
                            writeLinkAttrEscaped(out, dest.title);
                            out.writeByte('"');
                        }
                        out.writeSlice(" />");
                        i = dest.next;
                        continue;
                    }
                }

                var ref_label = label;
                var ref_next = close + 1;
                if (close + 1 < s.len and s[close + 1] == '[') {
                    if (findUnescapedRightBracket(s, close + 2)) |ref_close| {
                        if (ref_close == close + 2) {
                            ref_label = label;
                        } else {
                            ref_label = s[close + 2 .. ref_close];
                        }
                        ref_next = ref_close + 1;
                    }
                }

                if (lookupRefDef(ref_label)) |ref_def| {
                    out.writeSlice("<img src=\"");
                    writeURIAttrEscaped(out, ref_def.href);
                    out.writeSlice("\" alt=\"");
                    const alt = buildImageAltText(label, tmp_buf[0..]);
                    writeLinkAttrEscaped(out, alt);
                    out.writeByte('"');
                    if (ref_def.title.len > 0) {
                        out.writeSlice(" title=\"");
                        writeLinkAttrEscaped(out, ref_def.title);
                        out.writeByte('"');
                    }
                    out.writeSlice(" />");
                    i = ref_next;
                    continue;
                }
            }
        }

        if (b == '<') {
            if (std.mem.startsWith(u8, s[i..], "<![CDATA[")) {
                if (std.mem.indexOfPos(u8, s, i + 9, "]]>")) |end_idx| {
                    out.writeSlice(s[i .. end_idx + 3]);
                    i = end_idx + 3;
                    continue;
                }
            }
            var close_opt: ?usize = null;
            var p = i + 1;
            var saw_newline = false;
            var quote: u8 = 0;
            while (p < s.len) : (p += 1) {
                const ch = s[p];
                if (quote != 0) {
                    if (ch == quote) {
                        quote = 0;
                        continue;
                    }
                    if (ch == '\n') {
                        if (saw_newline) break;
                        saw_newline = true;
                    }
                    continue;
                }
                if (ch == '"' or ch == '\'') {
                    quote = ch;
                    continue;
                }
                if (ch == '>') {
                    close_opt = p;
                    break;
                }
                if (ch == '\n') {
                    if (saw_newline) break;
                    saw_newline = true;
                }
            }
            if (close_opt) |close| {
                const inner = s[i + 1 .. close];
                if (writeAutolink(out, inner)) {
                    i = close + 1;
                    continue;
                }
                if (inner.len > 0) {
                    const c0 = inner[0];
                    if (c0 == '/' or isAsciiAlpha(c0)) {
                        if (isPlausibleInlineTag(inner)) {
                            out.writeByte('<');
                            out.writeSlice(inner);
                            out.writeByte('>');
                            i = close + 1;
                            continue;
                        }
                    } else if (c0 == '!' or c0 == '?') {
                        out.writeByte('<');
                        out.writeSlice(inner);
                        out.writeByte('>');
                        i = close + 1;
                        continue;
                    }
                }
            }
        }

        if (b == '&') {
            var semi = i + 1;
            while (semi < s.len and semi - i <= 32 and s[semi] != ';' and s[semi] != '\n') : (semi += 1) {}
            if (semi < s.len and s[semi] == ';') {
                const ent = s[i .. semi + 1];
                var dec_buf: [8]u8 = undefined;
                if (isEntity(ent)) {
                    if (decodeEntityToBuf(ent, &dec_buf)) |decoded| {
                        for (decoded) |db| out.writeEscapedByte(db);
                        i = semi + 1;
                        continue;
                    }
                }
            }
            out.writeSlice("&amp;");
            i += 1;
            continue;
        }

        if (b == '*' or b == '_') {
            var run_len: usize = 1;
            while (i + run_len < s.len and s[i + run_len] == b) : (run_len += 1) {}
            const run_can_open = canOpenDelimiter(s, i, run_len, b);
            var strong_open = i;
            if (run_len > 2) {
                const close_chars1 = countCloseDelimiterChars(s, i + run_len, b, 1);
                if (close_chars1 < run_len) {
                    const max_shift = run_len - 2;
                    const want_shift = run_len - close_chars1;
                    const shift = @min(want_shift, max_shift);
                    strong_open = i + shift;
                }
            }
            const strong_from = strong_open + 2;

            const odd_run_prefers_single = run_len >= 3 and (run_len & 1) == 1;
            if (run_can_open and odd_run_prefers_single) {
                const end1_opt = findMatchingEmphasisRun(s, i + 1, b, 1);
                const end2_opt = if (run_len >= 2) findMatchingEmphasisRun(s, strong_from, b, 2) else null;
                const run_can_close = canCloseDelimiter(s, i, run_len, b);

                var prefer_strong_tie = false;
                if (end1_opt != null and end2_opt != null and !run_can_close and end1_opt.? <= end2_opt.? + 1) {
                    const end2 = end2_opt.?;
                    var run_start = end2;
                    while (run_start > 0 and s[run_start - 1] == b) : (run_start -= 1) {}
                    var run_end = run_start;
                    while (run_end < s.len and s[run_end] == b) : (run_end += 1) {}
                    prefer_strong_tie = (run_end - run_start) == 2;
                }

                if (prefer_strong_tie and end2_opt != null) {
                    const end2 = end2_opt.?;
                    if (end2 == strong_from) {
                        out.writeEscapedByte(b);
                        i += 1;
                        continue;
                    }
                    var lead_strong = i;
                    while (lead_strong < strong_open) : (lead_strong += 1) out.writeEscapedByte(b);
                    out.writeSlice("<strong>");
                    writeInline(out, s[strong_from .. end2]);
                    out.writeSlice("</strong>");
                    i = end2 + 2;
                    continue;
                }

                if (end1_opt) |end1| {
                    if (end1 == i + 1) {
                        out.writeEscapedByte(b);
                        i += 1;
                        continue;
                    }
                    out.writeSlice("<em>");
                    writeInline(out, s[i + 1 .. end1]);
                    out.writeSlice("</em>");
                    i = end1 + 1;
                    continue;
                }

                if (end2_opt) |end2| {
                    if (end2 == strong_from) {
                        out.writeEscapedByte(b);
                        i += 1;
                        continue;
                    }
                    var lead_strong = i;
                    while (lead_strong < strong_open) : (lead_strong += 1) out.writeEscapedByte(b);
                    out.writeSlice("<strong>");
                    writeInline(out, s[strong_from .. end2]);
                    out.writeSlice("</strong>");
                    i = end2 + 2;
                    continue;
                }
            }
            if (run_len >= 2 and run_can_open) {
                if (findMatchingEmphasisRun(s, strong_from, b, 2)) |end2| {
                    if (end2 == strong_from) {
                        out.writeEscapedByte(b);
                        i += 1;
                        continue;
                    }
                    var lead_strong = i;
                    while (lead_strong < strong_open) : (lead_strong += 1) out.writeEscapedByte(b);
                    out.writeSlice("<strong>");
                    writeInline(out, s[strong_from .. end2]);
                    out.writeSlice("</strong>");
                    i = end2 + 2;
                    continue;
                }
            }
            if (run_can_open and !odd_run_prefers_single) {
                const has_strong_match_here = run_len >= 2 and findMatchingEmphasisRun(s, strong_from, b, 2) != null;
                const defer_to_inner_strong = run_len == 2 and !has_strong_match_here and hasOpenDelimiterRun(s, i + 2, s.len, b, 2) and hasCloseDelimiterRun(s, i + 2, b, 2);
                if (!defer_to_inner_strong) {
                    var single_open = i;
                    if (run_len > 1) {
                        const close_chars = countCloseDelimiterChars(s, i + run_len, b, 1);
                        if (close_chars < run_len) {
                            const max_shift = run_len - 1;
                            const want_shift = run_len - close_chars;
                            const shift = @min(want_shift, max_shift);
                            single_open = i + shift;
                        }
                    }
                    const single_from = single_open + 1;
                    if (findMatchingEmphasisRun(s, single_from, b, 1)) |end1| {
                        if (end1 == single_open + 1) {
                            out.writeEscapedByte(b);
                            i += 1;
                            continue;
                        }
                        var lead = i;
                        while (lead < single_open) : (lead += 1) out.writeEscapedByte(b);
                        out.writeSlice("<em>");
                        writeInline(out, s[single_open + 1 .. end1]);
                        out.writeSlice("</em>");
                        i = end1 + 1;
                        continue;
                    }
                }
            }
            var t: usize = 0;
            while (t < run_len) : (t += 1) out.writeEscapedByte(b);
            i += run_len;
            continue;
        }

        out.writeEscapedByte(b);
        i += 1;
    }
}

fn renderParagraph(input: []const u8, out: *Writer, i_ptr: *u32) void {
    const start = i_ptr.*;
    var i = start;
    while (i < lines_count) : (i += 1) {
        const line = lineSlice(input, i);
        if (isBlankLine(line)) break;
        if (i != start) {
            if (parseATXHeading(line) != null) break;
            if (parseThematicBreak(line)) break;
            if (parseFenceOpen(line) != null) break;
            if (canInterruptParagraphWithList(line)) break;
            const prev_blank = if (i == 0) true else isBlankLine(lineSlice(input, i - 1));
            const html_block = detectHtmlBlockStart(line, prev_blank);
            if (html_block != .none and html_block != .type7) break;
            const ind = leadingIndent(line);
            if (ind.cols <= 3 and ind.idx < line.len and line[ind.idx] == '>') break;
        }
    }

    var para = Writer.init(tmp2_buf[0..]);
    var j = start;
    while (j < i) : (j += 1) {
        if (j != start) para.writeByte('\n');
        const line = lineSlice(input, j);
        var seg: []const u8 = undefined;
        if (j != start) {
            seg = stripAllLeadingSpacesTabs(line);
        } else {
            seg = stripBlockIndentUpTo3(line);
        }
        if (j + 1 == i) seg = trimRightSpacesTabs(seg);
        para.writeSlice(seg);
    }

    out.writeSlice("<p>");
    writeInline(out, para.buf[0..para.idx]);
    out.writeSlice("</p>\n");

    i_ptr.* = i;
}

fn renderFencedCode(input: []const u8, out: *Writer, i_ptr: *u32, fence: Fence) void {
    var i = i_ptr.* + 1;

    out.writeSlice("<pre><code");
    if (fence.info.len > 0) {
        var info_end: usize = 0;
        while (info_end < fence.info.len and !isWhitespace(fence.info[info_end])) : (info_end += 1) {}
        const lang = fence.info[0..info_end];
        if (lang.len > 0) {
            out.writeSlice(" class=\"language-");
            writeLinkAttrEscaped(out, lang);
            out.writeByte('"');
        }
    }
    out.writeSlice(">");

    while (i < lines_count) : (i += 1) {
        const line = lineSlice(input, i);
        if (isFenceClose(line, fence)) {
            i += 1;
            break;
        }
        var tmp = Writer.init(tmp2_buf[0..]);
        appendStrippedIndent(&tmp, line, fence.indent);
        out.writeEscaped(tmp.buf[0..tmp.idx]);
        out.writeByte('\n');
    }

    out.writeSlice("</code></pre>\n");
    i_ptr.* = i;
}

fn renderIndentedCode(input: []const u8, out: *Writer, i_ptr: *u32) void {
    var i = i_ptr.*;
    var code = Writer.init(tmp2_buf[0..]);
    var seen_content = false;

    out.writeSlice("<pre><code>");

    while (i < lines_count) : (i += 1) {
        const line = lineSlice(input, i);
        if (isBlankLine(line)) {
            const bi = leadingIndent(line);
            var stripped: []const u8 = "";
            if (bi.cols >= 4) {
                stripped = stripIndentCols(line, 4);
            }
            if (!seen_content and trimAscii(stripped).len == 0) continue;
            code.writeEscaped(stripped);
            code.writeByte('\n');
            continue;
        }
        const ind = leadingIndent(line);
        if (ind.cols < 4) break;
        const stripped = stripIndentCols(line, 4);
        if (trimAscii(stripped).len > 0) seen_content = true;
        code.writeEscaped(stripped);
        code.writeByte('\n');
    }

    // Trim trailing blank lines from indented code blocks.
    while (code.idx > 0) {
        if (code.buf[code.idx - 1] != '\n') break;
        var start = code.idx - 1;
        while (start > 0 and code.buf[start - 1] != '\n') : (start -= 1) {}
        const line_content = code.buf[start .. code.idx - 1];
        if (trimAscii(line_content).len != 0) break;
        code.idx = start;
    }

    out.writeSlice(code.buf[0..code.idx]);
    out.writeSlice("</code></pre>\n");
    i_ptr.* = i;
}

fn appendTmp(dst: *Writer, s: []const u8) void {
    dst.writeSlice(s);
}

fn appendListItemFirstLine(tmp: *Writer, line: []const u8, mark: ListMarker) void {
    var ps: usize = 0;
    while (ps < mark.prefix_spaces) : (ps += 1) tmp.writeByte(' ');
    const first_rem = line[mark.content_start..];
    const first_ind = leadingIndent(first_rem);
    var fs: usize = 0;
    while (fs < first_ind.cols) : (fs += 1) tmp.writeByte(' ');
    appendTmp(tmp, first_rem[first_ind.idx..]);
}

fn listItemContinuationBase(first_line: []const u8, mark: ListMarker) usize {
    const marker_min = mark.marker_end + 1;
    if (mark.content_start >= first_line.len) return marker_min;
    if (trimAscii(first_line[mark.content_start..]).len == 0) return marker_min;
    if (mark.content_start > mark.marker_end) return mark.content_start;
    return marker_min;
}

fn canLazyContinueListParagraph(line: []const u8) bool {
    if (parseATXHeading(line) != null) return false;
    if (parseThematicBreak(line)) return false;
    if (parseFenceOpen(line) != null) return false;
    if (canInterruptParagraphWithList(line)) return false;
    const html_block = detectHtmlBlockStart(line, false);
    if (html_block != .none and html_block != .type7) return false;
    const ind = leadingIndent(line);
    if (ind.cols <= 3 and ind.idx < line.len and line[ind.idx] == '>') return false;
    return true;
}

fn sameLevelListIndentLimit(base_indent: usize) usize {
    return if (base_indent == 0) 3 else base_indent;
}

fn nextTmpLine(text: []const u8, cursor: *usize) ?[]const u8 {
    if (cursor.* >= text.len) return null;
    const start = cursor.*;
    var end = start;
    while (end < text.len and text[end] != '\n') : (end += 1) {}
    if (end < text.len and text[end] == '\n') end += 1;
    cursor.* = end;
    return trimRightCR(text[start .. if (end > start and text[end - 1] == '\n') end - 1 else end]);
}

fn renderTmpList(out: *Writer, text: []const u8, cursor: *usize, first_line: []const u8) void {
    const first_mark = parseListMarker(first_line) orelse return;
    const ordered = first_mark.kind == .ordered;

    if (ordered) {
        if (first_mark.ordered_start != 1) {
            out.writeSlice("<ol start=\"");
            var num_buf: [32]u8 = undefined;
            const n = std.fmt.bufPrint(&num_buf, "{d}", .{first_mark.ordered_start}) catch "1";
            out.writeSlice(n);
            out.writeSlice("\">\n");
        } else {
            out.writeSlice("<ol>\n");
        }
    } else {
        out.writeSlice("<ul>\n");
    }

    var line = first_line;
    var done = false;
    var list_is_loose = false;
    while (!done) {
        const same_level_limit = first_mark.indent_cols;
        if (parseThematicBreak(line)) break;
        const mark = parseListMarker(line) orelse break;
        if (mark.kind != first_mark.kind or mark.marker != first_mark.marker) break;
        if (mark.indent_cols > same_level_limit) break;
        const item_content_base = listItemContinuationBase(line, mark);

        var tmp = Writer.init(tmp_buf[0..]);
        appendListItemFirstLine(&tmp, line, mark);
        var item_has_blank = false;
        var saw_nonblank = trimAscii(tmp.buf[0..tmp.idx]).len != 0;
        var separator_blank = false;
        var saw_nested_list = false;

        while (true) {
            const save = cursor.*;
            const maybe_ln = nextTmpLine(text, cursor);
            if (maybe_ln == null) break;
            const ln = maybe_ln.?;
            if (isBlankLine(ln)) {
                if (!saw_nonblank) break;
                var look = cursor.*;
                var next_nonblank: ?[]const u8 = null;
                while (nextTmpLine(text, &look)) |peek| {
                    if (isBlankLine(peek)) continue;
                    next_nonblank = peek;
                    break;
                }
                if (next_nonblank == null) break;
                const next_ln = next_nonblank.?;
                if (parseListMarker(next_ln)) |nm| {
                    if (leadingIndent(next_ln).cols <= first_mark.indent_cols) {
                        if (nm.kind == first_mark.kind and nm.marker == first_mark.marker) {
                            separator_blank = true;
                        }
                        break;
                    }
                } else if (leadingIndent(next_ln).cols < item_content_base) {
                    break;
                }
                appendTmp(&tmp, "\n");
                if (!tmpInsideFence(tmp.buf[0..tmp.idx]) and (!saw_nested_list or leadingIndent(next_ln).cols <= item_content_base + 1)) {
                    item_has_blank = true;
                }
                continue;
            }

            if (parseListMarker(ln)) |nm| {
                const ind = leadingIndent(ln);
                if (ind.cols <= same_level_limit) {
                    _ = nm;
                    cursor.* = save;
                    break;
                }
            }

            const ind = leadingIndent(ln);
            if (ind.cols < item_content_base and parseListMarker(ln) == null) {
                if (saw_nonblank and !item_has_blank and canLazyContinueListParagraph(ln)) {
                    appendTmp(&tmp, "\n");
                    appendTmp(&tmp, trimRightCR(ln));
                    saw_nonblank = true;
                    continue;
                }
                cursor.* = save;
                break;
            }
            if (parseListMarker(ln) != null and ind.cols >= item_content_base) saw_nested_list = true;

            appendTmp(&tmp, "\n");
            appendListContinuation(&tmp, ln, item_content_base);
            saw_nonblank = true;
        }

        const item_is_tight = !(list_is_loose or item_has_blank or separator_blank);
        const item_empty = trimAscii(tmp.buf[0..tmp.idx]).len == 0;
        if (item_empty) {
            out.writeSlice("<li></li>\n");
            list_is_loose = list_is_loose or item_has_blank or separator_blank;
        } else {
            if (!item_is_tight or firstListItemBlockIsCode(tmp.buf[0..tmp.idx])) {
                out.writeSlice("<li>\n");
            } else {
                out.writeSlice("<li>");
            }
            renderListItemContent(out, tmp.buf[0..tmp.idx], item_is_tight);
            out.writeSlice("</li>\n");
            list_is_loose = list_is_loose or item_has_blank or separator_blank;
        }

        var have_next = false;
        while (true) {
            const save = cursor.*;
            const maybe_next = nextTmpLine(text, cursor);
            if (maybe_next == null) {
                done = true;
                break;
            }
            const nl = maybe_next.?;
            if (isBlankLine(nl)) continue;

            if (parseListMarker(nl)) |nm| {
                const ind = leadingIndent(nl);
                if (nm.kind == first_mark.kind and nm.marker == first_mark.marker and ind.cols <= same_level_limit) {
                    line = nl;
                    have_next = true;
                    break;
                }
            }

            cursor.* = save;
            done = true;
            break;
        }
        if (!have_next) break;
    }

    if (ordered) {
        out.writeSlice("</ol>\n");
    } else {
        out.writeSlice("</ul>\n");
    }
}

fn renderTmpBlockquote(out: *Writer, text: []const u8, cursor: *usize, first_line: []const u8) void {
    var tmp = Writer.init(tmp_buf[0..]);
    var line = first_line;
    var line_start_set = false;
    var current_line_start: usize = 0;
    var started = false;
    var allow_lazy = false;

    while (true) {
        if (isBlankLine(line)) {
            if (line_start_set) cursor.* = current_line_start;
            break;
        }

        var stripped_line = Writer.init(tmp2_buf[0..]);
        if (appendBlockquoteStripped(&stripped_line, line)) {
            const stripped = stripped_line.buf[0..stripped_line.idx];
            appendTmp(&tmp, stripped);
            appendTmp(&tmp, "\n");
            started = true;
            if (isBlankLine(stripped)) {
                allow_lazy = false;
            } else {
                const si = leadingIndent(stripped);
                const html_block = detectHtmlBlockStart(stripped, false);
                allow_lazy = parseATXHeading(stripped) == null and
                    !parseThematicBreak(stripped) and
                    parseFenceOpen(stripped) == null and
                    (html_block == .none or html_block == .type7) and
                    si.cols < 4;
            }
        } else {
            if (!started or !allow_lazy) {
                if (line_start_set) cursor.* = current_line_start;
                break;
            }
            if (parseATXHeading(line) != null or
                parseThematicBreak(line) or
                parseFenceOpen(line) != null or
                canInterruptParagraphWithList(line))
            {
                if (line_start_set) cursor.* = current_line_start;
                break;
            }
            const prev_blank = false;
            const html_block = detectHtmlBlockStart(line, prev_blank);
            if (html_block != .none and html_block != .type7) {
                if (line_start_set) cursor.* = current_line_start;
                break;
            }
            appendTmp(&tmp, trimRightCR(line));
            appendTmp(&tmp, "\n");
            allow_lazy = true;
        }

        const save = cursor.*;
        const maybe_next = nextTmpLine(text, cursor);
        if (maybe_next == null) break;
        current_line_start = save;
        line_start_set = true;
        line = maybe_next.?;
    }

    out.writeSlice("<blockquote>\n");
    renderListItemContent(out, tmp.buf[0..tmp.idx], false);
    out.writeSlice("</blockquote>\n");
}

fn renderListItemContent(out: *Writer, text: []const u8, tight: bool) void {
    var cursor: usize = 0;
    var first_block = true;
    var prev_blank = true;

    while (cursor < text.len) {
        const line = nextTmpLine(text, &cursor) orelse break;
        if (isBlankLine(line)) {
            prev_blank = true;
            continue;
        }
        if (parseReferenceDefLine(line) != null) {
            prev_blank = false;
            continue;
        }

        const qi = leadingIndent(line);
        if (qi.cols <= 3 and qi.idx < line.len and line[qi.idx] == '>') {
            if (tight and !first_block) out.writeByte('\n');
            renderTmpBlockquote(out, text, &cursor, line);
            first_block = false;
            prev_blank = false;
            continue;
        }

        const html_block = detectHtmlBlockStart(line, prev_blank);
        if (html_block != .none) {
            out.writeSlice(line);
            out.writeByte('\n');
            while (true) {
                const save = cursor;
                const maybe_next = nextTmpLine(text, &cursor);
                if (maybe_next == null) break;
                const nl = maybe_next.?;
                var next_save = cursor;
                const maybe_after = nextTmpLine(text, &next_save);
                const next_is_blank = maybe_after == null or isBlankLine(maybe_after.?);
                out.writeSlice(nl);
                out.writeByte('\n');
                if (htmlBlockEnds(html_block, nl, next_is_blank)) {
                    if ((html_block == .type6 or html_block == .type7) and maybe_after != null and isBlankLine(maybe_after.?)) {
                        cursor = next_save;
                    }
                    break;
                }
                _ = save;
            }
            first_block = false;
            prev_blank = false;
            continue;
        }

        if (parseFenceOpen(line)) |fence| {
            out.writeSlice("<pre><code");
            if (fence.info.len > 0) {
                var info_end: usize = 0;
                while (info_end < fence.info.len and !isWhitespace(fence.info[info_end])) : (info_end += 1) {}
                const lang = fence.info[0..info_end];
                if (lang.len > 0) {
                    out.writeSlice(" class=\"language-");
                    writeLinkAttrEscaped(out, lang);
                    out.writeByte('"');
                }
            }
            out.writeSlice(">");

            while (true) {
                const maybe_next = nextTmpLine(text, &cursor);
                if (maybe_next == null) break;
                const nl = maybe_next.?;
                if (isFenceClose(nl, fence)) break;
                var stripped = Writer.init(tmp3_buf[0..]);
                appendStrippedIndent(&stripped, nl, fence.indent);
                out.writeEscaped(stripped.buf[0..stripped.idx]);
                out.writeByte('\n');
            }
            out.writeSlice("</code></pre>\n");
            first_block = false;
            prev_blank = false;
            continue;
        }

        if (parseThematicBreak(line)) {
            if (tight and !first_block) out.writeByte('\n');
            out.writeSlice("<hr />\n");
            first_block = false;
            prev_blank = false;
            continue;
        }

        if (parseATXHeading(line)) |h| {
            var tag: [6]u8 = undefined;
            const open = std.fmt.bufPrint(&tag, "<h{d}>", .{h.level}) catch "<h1>";
            out.writeSlice(open);
            writeInline(out, h.text);
            const close = std.fmt.bufPrint(&tag, "</h{d}>\n", .{h.level}) catch "</h1>\n";
            out.writeSlice(close);
            first_block = false;
            prev_blank = false;
            continue;
        }

        {
            const save = cursor;
            const maybe_next = nextTmpLine(text, &cursor);
            if (maybe_next) |nl| {
                if (!isBlankLine(nl)) {
                    if (parseSetextUnderline(nl)) |lvl| {
                        var tag: [6]u8 = undefined;
                        const open = std.fmt.bufPrint(&tag, "<h{d}>", .{lvl}) catch "<h1>";
                        out.writeSlice(open);
                        writeInline(out, trimAscii(line));
                        const close = std.fmt.bufPrint(&tag, "</h{d}>\n", .{lvl}) catch "</h1>\n";
                        out.writeSlice(close);
                        first_block = false;
                        prev_blank = false;
                        continue;
                    }
                }
            }
            cursor = save;
        }

        if (parseListMarker(line) != null) {
            if (tight and !first_block) out.writeByte('\n');
            renderTmpList(out, text, &cursor, line);
            first_block = false;
            prev_blank = false;
            continue;
        }

        const ind = leadingIndent(line);
        if (ind.cols >= 4) {
            var code = Writer.init(tmp3_buf[0..]);
            var code_line = line;
            while (true) {
                code.writeEscaped(stripIndentCols(code_line, 4));
                code.writeByte('\n');
                const save = cursor;
                const maybe_next = nextTmpLine(text, &cursor);
                if (maybe_next == null) break;
                const nl = maybe_next.?;
                if (isBlankLine(nl)) {
                    code_line = nl;
                    continue;
                }
                const ni = leadingIndent(nl);
                if (ni.cols < 4) {
                    cursor = save;
                    break;
                }
                code_line = nl;
            }

            while (code.idx > 0) {
                if (code.buf[code.idx - 1] != '\n') break;
                var start = code.idx - 1;
                while (start > 0 and code.buf[start - 1] != '\n') : (start -= 1) {}
                const line_content = code.buf[start .. code.idx - 1];
                if (trimAscii(line_content).len != 0) break;
                code.idx = start;
            }

            out.writeSlice("<pre><code>");
            out.writeSlice(code.buf[0..code.idx]);
            out.writeSlice("</code></pre>\n");
            first_block = false;
            prev_blank = false;
            continue;
        }

        var para = Writer.init(tmp2_buf[0..]);
        para.writeSlice(line);
        while (true) {
            const save = cursor;
            const maybe_next = nextTmpLine(text, &cursor);
            if (maybe_next == null) break;
            const nl = maybe_next.?;
            if (isBlankLine(nl)) break;
            if (parseATXHeading(nl) != null) {
                cursor = save;
                break;
            }
            if (parseThematicBreak(nl)) {
                cursor = save;
                break;
            }
            if (parseFenceOpen(nl) != null) {
                cursor = save;
                break;
            }
            if (canInterruptParagraphWithList(nl)) {
                cursor = save;
                break;
            }
            const nl_html = detectHtmlBlockStart(nl, false);
            if (nl_html != .none and nl_html != .type7) {
                cursor = save;
                break;
            }
            const ni = leadingIndent(nl);
            if (ni.cols <= 3 and ni.idx < nl.len and nl[ni.idx] == '>') {
                cursor = save;
                break;
            }
            para.writeByte('\n');
            para.writeSlice(stripAllLeadingSpacesTabs(nl));
        }

        if (tight and first_block) {
            writeInline(out, trimAscii(para.buf[0..para.idx]));
        } else if (tight) {
            writeInline(out, trimAscii(para.buf[0..para.idx]));
        } else {
            out.writeSlice("<p>");
            writeInline(out, trimAscii(para.buf[0..para.idx]));
            out.writeSlice("</p>\n");
        }
        first_block = false;
        prev_blank = false;
    }
}

fn firstListItemBlockIsCode(text: []const u8) bool {
    var cursor: usize = 0;
    var prev_blank = true;
    while (nextTmpLine(text, &cursor)) |line| {
        if (isBlankLine(line)) {
            prev_blank = true;
            continue;
        }
        if (parseATXHeading(line) != null) return true;
        const save = cursor;
        if (nextTmpLine(text, &cursor)) |nl| {
            if (!isBlankLine(nl) and parseSetextUnderline(nl) != null) return true;
        }
        cursor = save;
        if (leadingIndent(line).cols >= 4) return true;
        if (parseFenceOpen(line) != null) return true;
        const ind = leadingIndent(line);
        if (ind.cols <= 3 and ind.idx < line.len and line[ind.idx] == '>') return true;
        if (parseThematicBreak(line)) return true;
        if (parseListMarker(line) != null) return true;
        if (detectHtmlBlockStart(line, prev_blank) != .none) return true;
        return false;
    }
    return false;
}

fn firstListItemStartsFence(text: []const u8) bool {
    var cursor: usize = 0;
    while (nextTmpLine(text, &cursor)) |line| {
        if (isBlankLine(line)) continue;
        return parseFenceOpen(line) != null;
    }
    return false;
}

fn tmpInsideFence(text: []const u8) bool {
    var cursor: usize = 0;
    var open: ?Fence = null;
    while (nextTmpLine(text, &cursor)) |line| {
        if (open) |f| {
            if (isFenceClose(line, f)) open = null;
            continue;
        }
        if (parseFenceOpen(line)) |f| {
            open = f;
            continue;
        }
    }
    return open != null;
}

fn renderSimpleBlockquote(input: []const u8, out: *Writer, i_ptr: *u32) void {
    var i = i_ptr.*;
    var tmp = Writer.init(tmp_buf[0..]);
    var started = false;
    var allow_lazy = false;

    while (i < lines_count) : (i += 1) {
        const line = lineSlice(input, i);
        if (isBlankLine(line)) {
            break;
        }
        var stripped_line = Writer.init(tmp2_buf[0..]);
        if (appendBlockquoteStripped(&stripped_line, line)) {
            const stripped = stripped_line.buf[0..stripped_line.idx];
            appendTmp(&tmp, stripped);
            appendTmp(&tmp, "\n");
            started = true;
            if (isBlankLine(stripped)) {
                allow_lazy = false;
            } else {
                const si = leadingIndent(stripped);
                const prev_blank_for_html = false;
                const html_block = detectHtmlBlockStart(stripped, prev_blank_for_html);
                allow_lazy = parseATXHeading(stripped) == null and
                    !parseThematicBreak(stripped) and
                    parseFenceOpen(stripped) == null and
                    (html_block == .none or html_block == .type7) and
                    si.cols < 4;
            }
            continue;
        }
        if (!started) break;
        if (!allow_lazy) break;
        if (parseATXHeading(line) != null) break;
        if (parseThematicBreak(line)) break;
        if (parseFenceOpen(line) != null) break;
        if (canInterruptParagraphWithList(line)) break;
        const prev_blank = if (i == 0) true else isBlankLine(lineSlice(input, i - 1));
        const html_block = detectHtmlBlockStart(line, prev_blank);
        if (html_block != .none and html_block != .type7) break;
        // Lazy continuation line inside an open blockquote paragraph.
        appendTmp(&tmp, trimRightCR(line));
        appendTmp(&tmp, "\n");
        allow_lazy = true;
    }

    out.writeSlice("<blockquote>\n");
    renderListItemContent(out, tmp.buf[0..tmp.idx], false);
    out.writeSlice("</blockquote>\n");
    i_ptr.* = i;
}

fn listHasSiblingSeparatorBlank(input: []const u8, start_i: u32, first: ListMarker) bool {
    var i = start_i;
    while (i < lines_count) {
        const line = lineSlice(input, i);
        if (isBlankLine(line)) {
            i += 1;
            continue;
        }
        if (parseThematicBreak(line)) break;
        if (leadingIndent(line).cols > 3) break;
        const mark = parseListMarker(line) orelse break;
        if (mark.kind != first.kind or mark.marker != first.marker) break;
        const item_content_base = listItemContinuationBase(line, mark);
        var saw_nested_list = false;
        var saw_nonblank = if (mark.content_start < line.len) trimAscii(line[mark.content_start..]).len != 0 else false;
        const starts_fence = if (mark.content_start < line.len) parseFenceOpen(line[mark.content_start..]) != null else false;

        var j = i + 1;
        while (j < lines_count) : (j += 1) {
            const ln = lineSlice(input, j);
            if (isBlankLine(ln)) {
                var k = j + 1;
                while (k < lines_count and isBlankLine(lineSlice(input, k))) : (k += 1) {}
                if (k >= lines_count) return false;
                const next_ln = lineSlice(input, k);
                const ni = leadingIndent(next_ln);
                const next_mark = if (ni.cols <= 3) parseListMarker(next_ln) else null;
                if (next_mark) |nm| {
                    if (ni.cols < item_content_base) {
                        if (nm.kind == first.kind and nm.marker == first.marker) return true;
                        break;
                    }
                } else if (ni.cols < item_content_base) {
                    break;
                }
                if (!starts_fence and (!saw_nested_list or ni.cols <= item_content_base + 1)) return true;
                break;
            }
            const ind = leadingIndent(ln);
            const maybe_next = if (ind.cols <= 3) parseListMarker(ln) else null;
            if (maybe_next) |nm| {
                if (ind.cols < item_content_base) {
                    if (nm.kind == first.kind and nm.marker == first.marker) break;
                    break;
                }
            }
            if (ind.cols < item_content_base and maybe_next == null) {
                if (saw_nonblank and canLazyContinueListParagraph(ln)) continue;
                break;
            }
            if (maybe_next != null and ind.cols >= item_content_base) saw_nested_list = true;
            saw_nonblank = true;
        }
        i = j;
    }
    return false;
}

fn renderList(input: []const u8, out: *Writer, i_ptr: *u32, first: ListMarker) void {
    const ordered = first.kind == .ordered;
    if (ordered) {
        if (first.ordered_start != 1) {
            out.writeSlice("<ol start=\"");
            var num_buf: [32]u8 = undefined;
            const n = std.fmt.bufPrint(&num_buf, "{d}", .{first.ordered_start}) catch "1";
            out.writeSlice(n);
            out.writeSlice("\">\n");
        } else {
            out.writeSlice("<ol>\n");
        }
    } else {
        out.writeSlice("<ul>\n");
    }

    var i = i_ptr.*;
    var list_is_loose = listHasSiblingSeparatorBlank(input, i_ptr.*, first);
    while (i < lines_count) {
        const line = lineSlice(input, i);
        if (isBlankLine(line)) {
            i += 1;
            continue;
        }
        if (parseThematicBreak(line)) break;
        if (leadingIndent(line).cols > 3) break;

        const mark = parseListMarker(line) orelse break;
        if (mark.kind != first.kind or mark.marker != first.marker) break;
        const item_content_base = listItemContinuationBase(line, mark);

        var tmp = Writer.init(tmp_buf[0..]);
        appendListItemFirstLine(&tmp, line, mark);
        var item_has_blank = false;
        var saw_nonblank = trimAscii(tmp.buf[0..tmp.idx]).len != 0;
        var separator_blank = false;
        var saw_nested_list = false;

        var j = i + 1;
        while (j < lines_count) : (j += 1) {
            const ln = lineSlice(input, j);
            if (isBlankLine(ln)) {
                if (!saw_nonblank) break;
                var k = j + 1;
                while (k < lines_count and isBlankLine(lineSlice(input, k))) : (k += 1) {}
                if (k >= lines_count) break;
                const next_ln = lineSlice(input, k);
                const next_ind = leadingIndent(next_ln);
                if (next_ind.cols <= 3) {
                    if (parseListMarker(next_ln)) |nm| {
                        if (next_ind.cols < item_content_base) {
                            if (nm.kind == first.kind and nm.marker == first.marker) {
                                separator_blank = true;
                            }
                            break;
                        }
                    } else if (next_ind.cols < item_content_base) {
                        break;
                    }
                } else if (next_ind.cols < item_content_base) {
                    break;
                }
                appendTmp(&tmp, "\n");
                if (!tmpInsideFence(tmp.buf[0..tmp.idx]) and (!saw_nested_list or next_ind.cols <= item_content_base + 1)) {
                    item_has_blank = true;
                }
                continue;
            }

            const ind = leadingIndent(ln);
            const maybe_next = if (ind.cols <= 3) parseListMarker(ln) else null;
            if (maybe_next) |nm| {
                _ = nm;
                if (ind.cols < item_content_base) break;
            }
            if (ind.cols < item_content_base and maybe_next == null) {
                if (saw_nonblank and !item_has_blank and canLazyContinueListParagraph(ln)) {
                    appendTmp(&tmp, "\n");
                    appendTmp(&tmp, trimRightCR(ln));
                    saw_nonblank = true;
                    continue;
                }
                break;
            }
            if (maybe_next != null and ind.cols >= item_content_base) saw_nested_list = true;

            appendTmp(&tmp, "\n");
            appendListContinuation(&tmp, ln, item_content_base);
            saw_nonblank = true;
        }

        const item_is_tight = !(list_is_loose or item_has_blank or separator_blank);
        const item_empty = trimAscii(tmp.buf[0..tmp.idx]).len == 0;
        if (item_empty) {
            out.writeSlice("<li></li>\n");
            list_is_loose = list_is_loose or item_has_blank or separator_blank;
        } else {
            if (!item_is_tight or firstListItemBlockIsCode(tmp.buf[0..tmp.idx])) {
                out.writeSlice("<li>\n");
            } else {
                out.writeSlice("<li>");
            }
            renderListItemContent(out, tmp.buf[0..tmp.idx], item_is_tight);
            out.writeSlice("</li>\n");
            list_is_loose = list_is_loose or item_has_blank or separator_blank;
        }

        i = j;
    }

    if (ordered) {
        out.writeSlice("</ol>\n");
    } else {
        out.writeSlice("</ul>\n");
    }
    i_ptr.* = i;
}

fn renderHTMLBlock(input: []const u8, out: *Writer, i_ptr: *u32, block: HtmlBlockType) void {
    var i = i_ptr.*;
    while (i < lines_count) : (i += 1) {
        const line = lineRawSlice(input, i);
        out.writeSlice(line);
        if (line.len == 0 or line[line.len - 1] != '\n') out.writeByte('\n');
        const next_is_blank = i + 1 >= lines_count or isBlankLine(lineSlice(input, i + 1));
        if (htmlBlockEnds(block, trimRightCR(lineSlice(input, i)), next_is_blank)) {
            if ((block == .type6 or block == .type7) and i + 1 < lines_count and isBlankLine(lineSlice(input, i + 1))) {
                i += 1;
            }
            i += 1;
            break;
        }
    }
    i_ptr.* = i;
}

fn renderBlocks(input: []const u8, out: *Writer) void {
    var i: u32 = 0;
    while (i < lines_count and !out.overflow) {
        const line = lineSlice(input, i);

        if (isBlankLine(line)) {
            i += 1;
            continue;
        }
        const ind = leadingIndent(line);
        if (ind.cols >= 4) {
            renderIndentedCode(input, out, &i);
            continue;
        }

        if (parseATXHeading(line)) |h| {
            var tag: [6]u8 = undefined;
            const open = std.fmt.bufPrint(&tag, "<h{d}>", .{h.level}) catch "<h1>";
            out.writeSlice(open);
            writeInline(out, h.text);
            const close = std.fmt.bufPrint(&tag, "</h{d}>\n", .{h.level}) catch "</h1>\n";
            out.writeSlice(close);
            i += 1;
            continue;
        }

        if (parseThematicBreak(line)) {
            out.writeSlice("<hr />\n");
            i += 1;
            continue;
        }

        if (parseFenceOpen(line)) |f| {
            renderFencedCode(input, out, &i, f);
            continue;
        }

        const prev_blank = if (i == 0) true else isBlankLine(lineSlice(input, i - 1));
        const html_block = detectHtmlBlockStart(line, prev_blank);
        if (html_block != .none) {
            renderHTMLBlock(input, out, &i, html_block);
            continue;
        }

        if (parseReferenceDefAt(input, i)) |def| {
            i = def.next_idx;
            continue;
        }

        if (parseListMarker(line)) |mark| {
            renderList(input, out, &i, mark);
            continue;
        }

        if (ind.cols <= 3 and ind.idx < line.len and line[ind.idx] == '>') {
            renderSimpleBlockquote(input, out, &i);
            continue;
        }

        var setext_level: u8 = 0;
        var setext_underline_idx: u32 = 0;
        var j = i + 1;
        while (j < lines_count) : (j += 1) {
            const l = lineSlice(input, j);
            if (isBlankLine(l)) break;
            if (parseSetextUnderline(l)) |lvl| {
                setext_level = lvl;
                setext_underline_idx = j;
                break;
            }
            if (parseATXHeading(l) != null) break;
            if (parseThematicBreak(l)) break;
            if (parseFenceOpen(l) != null) break;
            if (canInterruptParagraphWithList(l)) break;
            const l_prev_blank = if (j == 0) true else isBlankLine(lineSlice(input, j - 1));
            const l_html_block = detectHtmlBlockStart(l, l_prev_blank);
            if (l_html_block != .none and l_html_block != .type7) break;
            const li = leadingIndent(l);
            if (li.cols <= 3 and li.idx < l.len and l[li.idx] == '>') break;
        }
        if (setext_level != 0) {
            var para = Writer.init(tmp2_buf[0..]);
            var k = i;
            while (k < setext_underline_idx) : (k += 1) {
                if (k != i) para.writeByte('\n');
                const l = lineSlice(input, k);
                if (k != i and leadingIndent(l).cols >= 4) {
                    para.writeSlice(trimRightSpacesTabs(stripIndentCols(l, 4)));
                } else {
                    para.writeSlice(trimRightSpacesTabs(stripBlockIndentUpTo3(l)));
                }
            }
            if (!para.overflow) {
                var tag: [7]u8 = undefined;
                const open = std.fmt.bufPrint(&tag, "<h{d}>", .{setext_level}) catch "<h1>";
                out.writeSlice(open);
                writeInline(out, para.buf[0..para.idx]);
                const close = std.fmt.bufPrint(&tag, "</h{d}>\n", .{setext_level}) catch "</h1>\n";
                out.writeSlice(close);
                i = setext_underline_idx + 1;
                continue;
            }
        }

        renderParagraph(input, out, &i);
    }
}

fn compactEmptyListItems(buf: []u8, len: usize) usize {
    const pattern = "<li>\n</li>\n";
    const replacement = "<li></li>\n";
    var r: usize = 0;
    var w: usize = 0;
    while (r < len) {
        if (r + pattern.len <= len and std.mem.eql(u8, buf[r .. r + pattern.len], pattern)) {
            @memcpy(buf[w..][0..replacement.len], replacement);
            w += replacement.len;
            r += pattern.len;
            continue;
        }
        buf[w] = buf[r];
        w += 1;
        r += 1;
    }
    return w;
}

fn renderMarkdown(input: []const u8, out: []u8) u32 {
    if (!splitLines(input)) return 0;
    collectReferenceDefs(input);
    var w = Writer.init(out);
    renderBlocks(input, &w);
    if (w.overflow) return 0;
    w.idx = compactEmptyListItems(w.buf, w.idx);
    return w.len();
}

export fn render(input_size_in: u32) u32 {
    var input_size = input_size_in;
    if (input_size > INPUT_CAP) input_size = INPUT_CAP;

    const in = input_buf[0..@as(usize, @intCast(input_size))];
    return renderMarkdown(in, output_buf[0..]);
}
