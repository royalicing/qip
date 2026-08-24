const std = @import("std");

const INPUT_CAP: u32 = 0x80000;
const OUTPUT_CAP: u32 = 0x100000;
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "text/html";
const MAX_HEADINGS: usize = 512;
const SLUG_CAP: usize = 96;

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
    idx: usize = 0,
    overflow: bool = false,

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
            self.overflow = true;
            return;
        }
        @memcpy(self.buf[self.idx..][0..s.len], s);
        self.idx += s.len;
    }
};

const SlugSet = struct {
    buf: [MAX_HEADINGS][SLUG_CAP]u8 = undefined,
    lens: [MAX_HEADINGS]usize = undefined,
    count: usize = 0,

    fn makeUnique(self: *SlugSet, base: []const u8, out: []u8) []const u8 {
        if (base.len == 0) {
            @memcpy(out[0.."section".len], "section");
            return self.makeUnique(out[0.."section".len], out);
        }

        const base_len = @min(base.len, out.len);
        @memcpy(out[0..base_len], base[0..base_len]);
        var len = base_len;

        var suffix: usize = 1;
        while (self.contains(out[0..len])) : (suffix += 1) {
            var suffix_buf: [16]u8 = undefined;
            const suffix_text = std.fmt.bufPrint(&suffix_buf, "-{d}", .{suffix}) catch unreachable;
            const prefix_len = @min(base_len, out.len - suffix_text.len);
            @memcpy(out[0..prefix_len], base[0..prefix_len]);
            @memcpy(out[prefix_len..][0..suffix_text.len], suffix_text);
            len = prefix_len + suffix_text.len;
        }

        self.add(out[0..len]);
        return out[0..len];
    }

    fn contains(self: *const SlugSet, slug: []const u8) bool {
        for (self.lens[0..self.count], 0..) |len, i| {
            if (std.mem.eql(u8, self.buf[i][0..len], slug)) return true;
        }
        return false;
    }

    fn add(self: *SlugSet, slug: []const u8) void {
        if (self.count >= MAX_HEADINGS) @panic("too many h2 headings");
        self.lens[self.count] = slug.len;
        @memcpy(self.buf[self.count][0..slug.len], slug);
        self.count += 1;
    }
};

fn isAsciiAlnum(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9');
}

fn lowerAscii(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

fn appendSlugChar(out: []u8, len: *usize, pending_dash: *bool, ch: u8) void {
    if (isAsciiAlnum(ch)) {
        if (pending_dash.* and len.* > 0 and len.* < out.len) {
            out[len.*] = '-';
            len.* += 1;
        }
        pending_dash.* = false;
        if (len.* < out.len) {
            out[len.*] = lowerAscii(ch);
            len.* += 1;
        }
    } else if (len.* > 0) {
        pending_dash.* = true;
    }
}

fn entityChar(entity: []const u8) ?u8 {
    if (std.mem.eql(u8, entity, "amp")) return '&';
    if (std.mem.eql(u8, entity, "lt")) return '<';
    if (std.mem.eql(u8, entity, "gt")) return '>';
    if (std.mem.eql(u8, entity, "quot")) return '"';
    if (std.mem.eql(u8, entity, "apos")) return '\'';
    if (std.mem.eql(u8, entity, "#39")) return '\'';
    if (entity.len >= 2 and entity[0] == '#') {
        const value = if (entity[1] == 'x' or entity[1] == 'X')
            std.fmt.parseUnsigned(u21, entity[2..], 16) catch return null
        else
            std.fmt.parseUnsigned(u21, entity[1..], 10) catch return null;
        if (value <= 0x7f) return @as(u8, @intCast(value));
    }
    return null;
}

fn appendEntityOrDash(s: []const u8, i: *usize, slug: []u8, len: *usize, pending_dash: *bool) void {
    var j = i.* + 1;
    while (j < s.len and j - i.* <= 16 and s[j] != ';') : (j += 1) {}
    if (j < s.len and s[j] == ';') {
        if (entityChar(s[i.* + 1 .. j])) |ch| {
            appendSlugChar(slug, len, pending_dash, ch);
        } else if (len.* > 0) {
            pending_dash.* = true;
        }
        i.* = j;
    } else if (len.* > 0) {
        pending_dash.* = true;
    }
}

fn findTagEnd(input: []const u8, start: usize) ?usize {
    var quote: u8 = 0;
    var i = start;
    while (i < input.len) : (i += 1) {
        const ch = input[i];
        if (quote != 0) {
            if (ch == quote) quote = 0;
        } else if (ch == '"' or ch == '\'') {
            quote = ch;
        } else if (ch == '>') {
            return i;
        }
    }
    return null;
}

fn h2OpenEnd(input: []const u8, start: usize) ?usize {
    if (start + 3 > input.len or input[start] != '<') return null;
    const h = lowerAscii(input[start + 1]);
    if (h != 'h' or input[start + 2] != '2') return null;
    if (start + 3 >= input.len) return null;
    const next = input[start + 3];
    if (next != '>' and next != ' ' and next != '\t' and next != '\n' and next != '\r') return null;
    return findTagEnd(input, start + 3);
}

fn h2CloseStart(input: []const u8, start: usize) ?usize {
    var i = start;
    while (i + 5 <= input.len) : (i += 1) {
        if (input[i] == '<' and input[i + 1] == '/' and lowerAscii(input[i + 2]) == 'h' and input[i + 3] == '2' and input[i + 4] == '>') {
            return i;
        }
    }
    return null;
}

fn makeSlugFromHeading(html: []const u8, out: []u8) []const u8 {
    var len: usize = 0;
    var pending_dash = false;
    var i: usize = 0;
    while (i < html.len) : (i += 1) {
        if (html[i] == '<') {
            if (findTagEnd(html, i)) |end| {
                i = end;
                if (len > 0) pending_dash = true;
                continue;
            }
        }
        if (html[i] == '&') {
            appendEntityOrDash(html, &i, out, &len, &pending_dash);
        } else {
            appendSlugChar(out, &len, &pending_dash, html[i]);
        }
    }
    return out[0..len];
}

fn isNameBoundary(ch: u8) bool {
    return ch == '<' or ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == '/';
}

fn h2IdValue(open_tag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 2 < open_tag.len) : (i += 1) {
        if (lowerAscii(open_tag[i]) != 'i' or lowerAscii(open_tag[i + 1]) != 'd') continue;
        if (i > 0 and !isNameBoundary(open_tag[i - 1])) continue;

        var j = i + 2;
        while (j < open_tag.len and (open_tag[j] == ' ' or open_tag[j] == '\t' or open_tag[j] == '\n' or open_tag[j] == '\r')) : (j += 1) {}
        if (j >= open_tag.len or open_tag[j] != '=') continue;
        j += 1;
        while (j < open_tag.len and (open_tag[j] == ' ' or open_tag[j] == '\t' or open_tag[j] == '\n' or open_tag[j] == '\r')) : (j += 1) {}
        if (j >= open_tag.len) return null;

        if (open_tag[j] == '"' or open_tag[j] == '\'') {
            const quote = open_tag[j];
            const start = j + 1;
            j = start;
            while (j < open_tag.len and open_tag[j] != quote) : (j += 1) {}
            if (j < open_tag.len) return open_tag[start..j];
            return null;
        }

        const start = j;
        while (j < open_tag.len and open_tag[j] != ' ' and open_tag[j] != '\t' and open_tag[j] != '\n' and open_tag[j] != '\r' and open_tag[j] != '>') : (j += 1) {}
        if (j > start) return open_tag[start..j];
    }
    return null;
}

fn addH2FragmentLinks(input: []const u8, output: []u8) usize {
    var w = Writer{ .buf = output };
    var slugs = SlugSet{};
    var i: usize = 0;

    while (i < input.len) {
        const open_end = h2OpenEnd(input, i) orelse {
            w.writeByte(input[i]);
            i += 1;
            continue;
        };
        const close_start = h2CloseStart(input, open_end + 1) orelse {
            w.writeByte(input[i]);
            i += 1;
            continue;
        };

        const open_tag = input[i .. open_end + 1];
        var base_buf: [SLUG_CAP]u8 = undefined;
        const existing_id = h2IdValue(open_tag);
        const base = existing_id orelse makeSlugFromHeading(input[open_end + 1 .. close_start], &base_buf);
        var slug_buf: [SLUG_CAP]u8 = undefined;
        const slug = if (existing_id) |id| existing: {
            if (id.len <= SLUG_CAP and !slugs.contains(id)) slugs.add(id);
            break :existing id;
        } else slugs.makeUnique(base, &slug_buf);

        if (existing_id != null) {
            w.writeSlice(open_tag);
        } else {
            w.writeSlice(open_tag[0 .. open_tag.len - 1]);
            w.writeSlice(" id=\"");
            w.writeSlice(slug);
            w.writeSlice("\">");
        }
        w.writeSlice(input[open_end + 1 .. close_start]);
        w.writeSlice(" <a class=\"heading-anchor\" href=\"#");
        w.writeSlice(slug);
        w.writeSlice("\" aria-label=\"Link to this section\">#</a>");
        w.writeSlice("</h2>");
        i = close_start + "</h2>".len;
    }

    if (w.overflow) @panic("output buffer overflow");
    return w.idx;
}

fn renderImpl(input_size: u32) u32 {
    const size = @as(usize, @intCast(input_size));
    const written = addH2FragmentLinks(input_buf[0..size], output_buf[0..]);
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

test "adds h2 ids and fragment links" {
    const input = "<main><h2>Component Contract</h2><p>Body</p></main>";
    const expected = "<main><h2 id=\"component-contract\">Component Contract <a class=\"heading-anchor\" href=\"#component-contract\" aria-label=\"Link to this section\">#</a></h2><p>Body</p></main>";
    var out: [expected.len]u8 = undefined;
    const written = addH2FragmentLinks(input, out[0..]);
    try std.testing.expectEqualStrings(expected, out[0..written]);
}

test "uses inline tag text and unique slugs" {
    const input = "<h2>Use <code>input_ptr</code> &amp; output</h2><h2>Use input_ptr &amp; output</h2>";
    const expected = "<h2 id=\"use-input-ptr-output\">Use <code>input_ptr</code> &amp; output <a class=\"heading-anchor\" href=\"#use-input-ptr-output\" aria-label=\"Link to this section\">#</a></h2><h2 id=\"use-input-ptr-output-1\">Use input_ptr &amp; output <a class=\"heading-anchor\" href=\"#use-input-ptr-output-1\" aria-label=\"Link to this section\">#</a></h2>";
    var out: [expected.len]u8 = undefined;
    const written = addH2FragmentLinks(input, out[0..]);
    try std.testing.expectEqualStrings(expected, out[0..written]);
}

test "preserves existing h2 id for anchor href" {
    const input = "<h2 id=\"already-here\">Already Here</h2>";
    const expected = "<h2 id=\"already-here\">Already Here <a class=\"heading-anchor\" href=\"#already-here\" aria-label=\"Link to this section\">#</a></h2>";
    var out: [expected.len]u8 = undefined;
    const written = addH2FragmentLinks(input, out[0..]);
    try std.testing.expectEqualStrings(expected, out[0..written]);
}
