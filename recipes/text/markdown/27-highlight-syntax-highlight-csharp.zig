const std = @import("std");

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = 4 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "text/html";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const KeywordSet = std.StaticStringMap(void).initComptime(.{
    .{ "abstract", {} },
    .{ "as", {} },
    .{ "async", {} },
    .{ "await", {} },
    .{ "base", {} },
    .{ "break", {} },
    .{ "case", {} },
    .{ "catch", {} },
    .{ "checked", {} },
    .{ "class", {} },
    .{ "const", {} },
    .{ "continue", {} },
    .{ "default", {} },
    .{ "delegate", {} },
    .{ "do", {} },
    .{ "else", {} },
    .{ "enum", {} },
    .{ "event", {} },
    .{ "explicit", {} },
    .{ "extern", {} },
    .{ "finally", {} },
    .{ "fixed", {} },
    .{ "for", {} },
    .{ "foreach", {} },
    .{ "from", {} },
    .{ "get", {} },
    .{ "global", {} },
    .{ "goto", {} },
    .{ "if", {} },
    .{ "implicit", {} },
    .{ "in", {} },
    .{ "init", {} },
    .{ "interface", {} },
    .{ "internal", {} },
    .{ "is", {} },
    .{ "lock", {} },
    .{ "namespace", {} },
    .{ "new", {} },
    .{ "operator", {} },
    .{ "out", {} },
    .{ "override", {} },
    .{ "params", {} },
    .{ "partial", {} },
    .{ "private", {} },
    .{ "protected", {} },
    .{ "public", {} },
    .{ "readonly", {} },
    .{ "record", {} },
    .{ "ref", {} },
    .{ "required", {} },
    .{ "return", {} },
    .{ "scoped", {} },
    .{ "sealed", {} },
    .{ "set", {} },
    .{ "sizeof", {} },
    .{ "stackalloc", {} },
    .{ "static", {} },
    .{ "struct", {} },
    .{ "switch", {} },
    .{ "this", {} },
    .{ "throw", {} },
    .{ "try", {} },
    .{ "typeof", {} },
    .{ "unchecked", {} },
    .{ "unsafe", {} },
    .{ "using", {} },
    .{ "virtual", {} },
    .{ "when", {} },
    .{ "where", {} },
    .{ "while", {} },
    .{ "with", {} },
    .{ "yield", {} },
});

const TypeSet = std.StaticStringMap(void).initComptime(.{
    .{ "bool", {} },
    .{ "byte", {} },
    .{ "char", {} },
    .{ "decimal", {} },
    .{ "double", {} },
    .{ "dynamic", {} },
    .{ "float", {} },
    .{ "int", {} },
    .{ "long", {} },
    .{ "nint", {} },
    .{ "nuint", {} },
    .{ "object", {} },
    .{ "sbyte", {} },
    .{ "short", {} },
    .{ "string", {} },
    .{ "uint", {} },
    .{ "ulong", {} },
    .{ "ushort", {} },
    .{ "void", {} },
    .{ "Engine", {} },
    .{ "Module", {} },
    .{ "Linker", {} },
    .{ "Store", {} },
    .{ "Memory", {} },
    .{ "Func", {} },
});

const LiteralSet = std.StaticStringMap(void).initComptime(.{
    .{ "false", {} },
    .{ "null", {} },
    .{ "true", {} },
});

const BuiltinSet = std.StaticStringMap(void).initComptime(.{
    .{ "Console", {} },
    .{ "Encoding", {} },
    .{ "Environment", {} },
    .{ "Math", {} },
    .{ "Path", {} },
    .{ "System", {} },
    .{ "Wasmtime", {} },
});

const Writer = struct {
    idx: usize = 0,
    overflow: bool = false,

    fn remaining(self: *const Writer) usize {
        return output_buf.len - self.idx;
    }

    fn writeByte(self: *Writer, b: u8) void {
        if (self.overflow) return;
        if (self.remaining() < 1) {
            self.overflow = true;
            return;
        }
        output_buf[self.idx] = b;
        self.idx += 1;
    }

    fn writeSlice(self: *Writer, s: []const u8) void {
        if (self.overflow or s.len == 0) return;
        if (self.remaining() < s.len) {
            self.overflow = true;
            return;
        }
        @memcpy(output_buf[self.idx .. self.idx + s.len], s);
        self.idx += s.len;
    }

    fn writeSpan(self: *Writer, class_name: []const u8, text: []const u8) void {
        self.writeSlice("<span class=\"");
        self.writeSlice(class_name);
        self.writeSlice("\">");
        self.writeSlice(text);
        self.writeSlice("</span>");
    }
};

const CodeOpenTag = struct {
    end: usize,
    has_language_csharp: bool,
    has_hljs: bool,
};

const CodeClassInfo = struct {
    has_language: bool,
    has_hljs: bool,
};

const CodeCloseTag = struct {
    start: usize,
    end: usize,
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
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn isTagNameBoundary(c: u8) bool {
    return c == '>' or c == '/' or isSpace(c);
}

fn isAttrNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == ':';
}

fn isLetter(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isIdentStart(c: u8) bool {
    return isLetter(c) or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

fn classContainsLanguageCsharp(value: []const u8) bool {
    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and isSpace(value[i])) : (i += 1) {}
        const start = i;
        while (i < value.len and !isSpace(value[i])) : (i += 1) {}
        if (i <= start) continue;
        const token = value[start..i];
        if (eqlIgnoreCase(token, "language-csharp") or eqlIgnoreCase(token, "language-cs") or eqlIgnoreCase(token, "language-dotnet") or eqlIgnoreCase(token, "language-c#")) return true;
    }
    return false;
}

fn classContainsHljs(value: []const u8) bool {
    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and isSpace(value[i])) : (i += 1) {}
        const start = i;
        while (i < value.len and !isSpace(value[i])) : (i += 1) {}
        if (i <= start) continue;
        if (eqlIgnoreCase(value[start..i], "hljs")) return true;
    }
    return false;
}

fn findTagEnd(input: []const u8, start: usize) ?usize {
    var i = start;
    var quote: u8 = 0;
    while (i < input.len) : (i += 1) {
        const ch = input[i];
        if (quote != 0) {
            if (ch == quote) quote = 0;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        if (ch == '>') return i;
    }
    return null;
}

fn codeTagClassInfoCsharp(tag: []const u8) CodeClassInfo {
    var out: CodeClassInfo = .{ .has_language = false, .has_hljs = false };
    if (tag.len < 6) return out;
    var i: usize = 5; // after "<code"
    while (i < tag.len) {
        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len or tag[i] == '>') break;
        if (tag[i] == '/') {
            i += 1;
            continue;
        }

        const name_start = i;
        while (i < tag.len and isAttrNameChar(tag[i])) : (i += 1) {}
        if (name_start == i) {
            i += 1;
            continue;
        }
        const name = tag[name_start..i];

        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        var value: []const u8 = "";
        if (i < tag.len and tag[i] == '=') {
            i += 1;
            while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
            if (i >= tag.len) break;
            if (tag[i] == '"' or tag[i] == '\'') {
                const quote = tag[i];
                i += 1;
                const value_start = i;
                while (i < tag.len and tag[i] != quote) : (i += 1) {}
                value = tag[value_start..@min(i, tag.len)];
                if (i < tag.len and tag[i] == quote) i += 1;
            } else {
                const value_start = i;
                while (i < tag.len and !isSpace(tag[i]) and tag[i] != '>' and tag[i] != '/') : (i += 1) {}
                value = tag[value_start..i];
            }
        }

        if (eqlIgnoreCase(name, "class")) {
            if (classContainsLanguageCsharp(value)) out.has_language = true;
            if (classContainsHljs(value)) out.has_hljs = true;
        }
    }
    return out;
}

fn findClassValueRange(tag: []const u8) ?struct { value_start: usize, value_end: usize } {
    if (tag.len < 6) return null;
    var i: usize = 5; // after "<code"
    while (i < tag.len) {
        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len or tag[i] == '>') break;
        if (tag[i] == '/') {
            i += 1;
            continue;
        }

        const name_start = i;
        while (i < tag.len and isAttrNameChar(tag[i])) : (i += 1) {}
        if (name_start == i) {
            i += 1;
            continue;
        }
        const name = tag[name_start..i];

        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len or tag[i] != '=') continue;
        i += 1;
        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len) break;

        var value_start = i;
        var value_end = i;
        if (tag[i] == '"' or tag[i] == '\'') {
            const quote = tag[i];
            value_start = i + 1;
            i += 1;
            while (i < tag.len and tag[i] != quote) : (i += 1) {}
            value_end = @min(i, tag.len);
            if (i < tag.len and tag[i] == quote) i += 1;
        } else {
            value_start = i;
            while (i < tag.len and !isSpace(tag[i]) and tag[i] != '>' and tag[i] != '/') : (i += 1) {}
            value_end = i;
        }

        if (eqlIgnoreCase(name, "class")) {
            return .{ .value_start = value_start, .value_end = value_end };
        }
    }
    return null;
}

fn writeCodeOpenTagWithHljs(tag: []const u8, w: *Writer) void {
    const class_range = findClassValueRange(tag) orelse {
        w.writeSlice(tag);
        return;
    };
    const class_value = tag[class_range.value_start..class_range.value_end];
    if (classContainsHljs(class_value)) {
        w.writeSlice(tag);
        return;
    }
    w.writeSlice(tag[0..class_range.value_end]);
    if (class_value.len > 0) w.writeByte(' ');
    w.writeSlice("hljs");
    w.writeSlice(tag[class_range.value_end..]);
}

fn parseCodeOpenTag(input: []const u8, start: usize) ?CodeOpenTag {
    if (start + 5 > input.len) return null;
    if (input[start] != '<') return null;
    if (!eqlIgnoreCase(input[start + 1 .. start + 5], "code")) return null;
    if (start + 5 < input.len and !isTagNameBoundary(input[start + 5])) return null;

    const end = findTagEnd(input, start + 5) orelse return null;
    const info = codeTagClassInfoCsharp(input[start .. end + 1]);
    return .{ .end = end, .has_language_csharp = info.has_language, .has_hljs = info.has_hljs };
}

fn findCodeCloseTag(input: []const u8, from: usize) ?CodeCloseTag {
    var i = from;
    while (i + 7 <= input.len) : (i += 1) {
        if (input[i] != '<') continue;
        if (i + 2 >= input.len or input[i + 1] != '/') continue;
        if (i + 6 > input.len) continue;
        if (!eqlIgnoreCase(input[i + 2 .. i + 6], "code")) continue;

        var j = i + 6;
        if (j < input.len and !isTagNameBoundary(input[j])) continue;
        while (j < input.len and isSpace(input[j])) : (j += 1) {}
        if (j < input.len and input[j] == '>') {
            return .{ .start = i, .end = j };
        }
    }
    return null;
}

fn isStringStart(code: []const u8, start: usize) bool {
    if (start >= code.len) return false;
    if (code[start] == '"' or code[start] == '\'') return true;
    if (code[start] != '$' and code[start] != '@') return false;
    var i = start;
    while (i < code.len and (code[i] == '$' or code[i] == '@')) : (i += 1) {}
    return i < code.len and code[i] == '"';
}

fn stringEnd(code: []const u8, start: usize) usize {
    var quote_start = start;
    var verbatim = false;
    while (quote_start < code.len and (code[quote_start] == '$' or code[quote_start] == '@')) {
        if (code[quote_start] == '@') verbatim = true;
        quote_start += 1;
    }
    if (quote_start >= code.len) return code.len;
    const quote = code[quote_start];
    const triple = quote_start + 2 < code.len and code[quote_start + 1] == quote and code[quote_start + 2] == quote;
    var i = quote_start + (if (triple) @as(usize, 3) else 1);
    var escaped = false;
    while (i < code.len) {
        const c = code[i];
        if (verbatim and !triple and c == quote and i + 1 < code.len and code[i + 1] == quote) {
            i += 2;
            continue;
        }
        if (escaped) {
            escaped = false;
            i += 1;
            continue;
        }
        if (!verbatim and c == '\\') {
            escaped = true;
            i += 1;
            continue;
        }
        if (triple) {
            if (i + 2 < code.len and code[i] == quote and code[i + 1] == quote and code[i + 2] == quote) return i + 3;
        } else if (c == quote) {
            return i + 1;
        }
        i += 1;
    }
    return code.len;
}

fn numberEnd(code: []const u8, start: usize) usize {
    var i = start;
    while (i < code.len) {
        const c = code[i];
        if (isIdentContinue(c) or c == '.' or c == '_') {
            i += 1;
            continue;
        }
        if ((c == '+' or c == '-') and i > start) {
            const previous = code[i - 1];
            if (previous == 'e' or previous == 'E') {
                i += 1;
                continue;
            }
        }
        break;
    }
    return i;
}

fn writeHighlightedCsharp(code: []const u8, w: *Writer) void {
    var i: usize = 0;
    var at_line_start = true;
    while (i < code.len) {
        if (code[i] == '\n') {
            w.writeByte('\n');
            i += 1;
            at_line_start = true;
            continue;
        }
        if (at_line_start and (code[i] == ' ' or code[i] == '\t')) {
            w.writeByte(code[i]);
            i += 1;
            continue;
        }
        if (at_line_start and code[i] == '#') {
            var j = i + 1;
            while (j < code.len and code[j] != '\n') : (j += 1) {}
            w.writeSpan("hljs-meta", code[i..j]);
            i = j;
            at_line_start = false;
            continue;
        }
        at_line_start = false;
        if (i + 1 < code.len and code[i] == '/' and code[i + 1] == '/') {
            var j = i + 2;
            while (j < code.len and code[j] != '\n') : (j += 1) {}
            w.writeSpan("hljs-comment", code[i..j]);
            i = j;
            continue;
        }
        if (i + 1 < code.len and code[i] == '/' and code[i + 1] == '*') {
            var j = i + 2;
            while (j + 1 < code.len and !(code[j] == '*' and code[j + 1] == '/')) : (j += 1) {}
            if (j + 1 < code.len) j += 2 else j = code.len;
            w.writeSpan("hljs-comment", code[i..j]);
            i = j;
            continue;
        }
        if (isStringStart(code, i)) {
            const j = stringEnd(code, i);
            w.writeSpan("hljs-string", code[i..j]);
            i = j;
            continue;
        }
        if (isDigit(code[i])) {
            const j = numberEnd(code, i);
            w.writeSpan("hljs-number", code[i..j]);
            i = j;
            continue;
        }
        if (isIdentStart(code[i])) {
            var j = i + 1;
            while (j < code.len and isIdentContinue(code[j])) : (j += 1) {}
            const ident = code[i..j];
            if (KeywordSet.get(ident) != null) {
                w.writeSpan("hljs-keyword", ident);
            } else if (TypeSet.get(ident) != null) {
                w.writeSpan("hljs-type", ident);
            } else if (LiteralSet.get(ident) != null) {
                w.writeSpan("hljs-literal", ident);
            } else if (BuiltinSet.get(ident) != null) {
                w.writeSpan("hljs-built_in", ident);
            } else {
                w.writeSlice(ident);
            }
            i = j;
            continue;
        }
        w.writeByte(code[i]);
        i += 1;
    }
}

fn transformHTML(input: []const u8, w: *Writer) void {
    var cursor: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '<') {
            i += 1;
            continue;
        }

        const open = parseCodeOpenTag(input, i) orelse {
            i += 1;
            continue;
        };

        w.writeSlice(input[cursor..i]);
        const close = findCodeCloseTag(input, open.end + 1) orelse {
            w.writeSlice(input[i..]);
            return;
        };

        const inner = input[open.end + 1 .. close.start];
        const should_highlight = open.has_language_csharp and !open.has_hljs;
        if (!should_highlight) {
            w.writeSlice(input[i .. close.end + 1]);
            cursor = close.end + 1;
            i = cursor;
            continue;
        }

        writeCodeOpenTagWithHljs(input[i .. open.end + 1], w);
        writeHighlightedCsharp(inner, w);
        w.writeSlice(input[close.start .. close.end + 1]);
        cursor = close.end + 1;
        i = cursor;
    }
    if (cursor < input.len) {
        w.writeSlice(input[cursor..]);
    }
}

export fn render(input_size: u32) u32 {
    const input_len: usize = @intCast(input_size);
    if (input_len > INPUT_CAP) @trap();
    const input = input_buf[0..input_len];

    var w = Writer{};
    transformHTML(input, &w);
    if (w.overflow) @trap();
    return @as(u32, @intCast(w.idx));
}

fn runForTest(input: []const u8) []const u8 {
    if (input.len > INPUT_CAP) @trap();
    @memcpy(input_buf[0..input.len], input);
    const out_len = render(@as(u32, @intCast(input.len)));
    return output_buf[0..@as(usize, @intCast(out_len))];
}

test "highlights C sharp declarations strings and literals" {
    const input = "<pre><code class=\"language-csharp\">public sealed class App { string name = \"QIP\"; bool ready = true; }</code></pre>";
    const got = runForTest(input);
    const expected = "<pre><code class=\"language-csharp hljs\"><span class=\"hljs-keyword\">public</span> <span class=\"hljs-keyword\">sealed</span> <span class=\"hljs-keyword\">class</span> App { <span class=\"hljs-type\">string</span> name = <span class=\"hljs-string\">\"QIP\"</span>; <span class=\"hljs-type\">bool</span> ready = <span class=\"hljs-literal\">true</span>; }</code></pre>";
    try std.testing.expectEqualStrings(expected, got);
}

test "highlights C sharp aliases interpolation comments and numbers" {
    const input = "<code class=\"language-cs\">return $\"size: {42}\"; // bytes</code>";
    const got = runForTest(input);
    const expected = "<code class=\"language-cs hljs\"><span class=\"hljs-keyword\">return</span> <span class=\"hljs-string\">$\"size: {42}\"</span>; <span class=\"hljs-comment\">// bytes</span></code>";
    try std.testing.expectEqualStrings(expected, got);
}

test "skips highlighted and non-C-sharp blocks" {
    const highlighted = "<code class=\"language-csharp hljs\"><span class=\"hljs-keyword\">class</span></code>";
    try std.testing.expectEqualStrings(highlighted, runForTest(highlighted));
    const java = "<code class=\"language-java\">class App {}</code>";
    try std.testing.expectEqualStrings(java, runForTest(java));
}
