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
    .{ "asserts", {} },
    .{ "async", {} },
    .{ "await", {} },
    .{ "break", {} },
    .{ "case", {} },
    .{ "catch", {} },
    .{ "class", {} },
    .{ "const", {} },
    .{ "continue", {} },
    .{ "debugger", {} },
    .{ "declare", {} },
    .{ "default", {} },
    .{ "delete", {} },
    .{ "do", {} },
    .{ "else", {} },
    .{ "enum", {} },
    .{ "export", {} },
    .{ "extends", {} },
    .{ "finally", {} },
    .{ "for", {} },
    .{ "from", {} },
    .{ "function", {} },
    .{ "get", {} },
    .{ "if", {} },
    .{ "implements", {} },
    .{ "import", {} },
    .{ "in", {} },
    .{ "infer", {} },
    .{ "instanceof", {} },
    .{ "interface", {} },
    .{ "is", {} },
    .{ "keyof", {} },
    .{ "let", {} },
    .{ "module", {} },
    .{ "namespace", {} },
    .{ "new", {} },
    .{ "of", {} },
    .{ "override", {} },
    .{ "package", {} },
    .{ "private", {} },
    .{ "protected", {} },
    .{ "public", {} },
    .{ "readonly", {} },
    .{ "return", {} },
    .{ "satisfies", {} },
    .{ "set", {} },
    .{ "static", {} },
    .{ "super", {} },
    .{ "switch", {} },
    .{ "this", {} },
    .{ "throw", {} },
    .{ "try", {} },
    .{ "type", {} },
    .{ "typeof", {} },
    .{ "using", {} },
    .{ "var", {} },
    .{ "void", {} },
    .{ "while", {} },
    .{ "with", {} },
    .{ "yield", {} },
});

const TypeSet = std.StaticStringMap(void).initComptime(.{
    .{ "any", {} },
    .{ "Array", {} },
    .{ "bigint", {} },
    .{ "boolean", {} },
    .{ "Date", {} },
    .{ "Error", {} },
    .{ "Map", {} },
    .{ "never", {} },
    .{ "number", {} },
    .{ "object", {} },
    .{ "Promise", {} },
    .{ "ReadonlyArray", {} },
    .{ "Record", {} },
    .{ "RegExp", {} },
    .{ "Set", {} },
    .{ "string", {} },
    .{ "symbol", {} },
    .{ "Uint8Array", {} },
    .{ "unknown", {} },
});

const LiteralSet = std.StaticStringMap(void).initComptime(.{
    .{ "false", {} },
    .{ "Infinity", {} },
    .{ "NaN", {} },
    .{ "null", {} },
    .{ "true", {} },
    .{ "undefined", {} },
});

const BuiltinSet = std.StaticStringMap(void).initComptime(.{
    .{ "Array", {} },
    .{ "Boolean", {} },
    .{ "clearInterval", {} },
    .{ "clearTimeout", {} },
    .{ "console", {} },
    .{ "Date", {} },
    .{ "document", {} },
    .{ "fetch", {} },
    .{ "globalThis", {} },
    .{ "JSON", {} },
    .{ "Map", {} },
    .{ "Math", {} },
    .{ "Number", {} },
    .{ "Object", {} },
    .{ "Promise", {} },
    .{ "RegExp", {} },
    .{ "setInterval", {} },
    .{ "setTimeout", {} },
    .{ "String", {} },
    .{ "Symbol", {} },
    .{ "window", {} },
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
    has_language_tsx: bool,
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

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isLetter(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isIdentStart(c: u8) bool {
    return isLetter(c) or c == '_' or c == '$';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isBinaryDigit(c: u8) bool {
    return c == '0' or c == '1';
}

fn isOctDigit(c: u8) bool {
    return c >= '0' and c <= '7';
}

fn classContainsLanguageTSX(value: []const u8) bool {
    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and isSpace(value[i])) : (i += 1) {}
        const start = i;
        while (i < value.len and !isSpace(value[i])) : (i += 1) {}
        if (i <= start) continue;
        const token = value[start..i];
        if (eqlIgnoreCase(token, "language-js") or
            eqlIgnoreCase(token, "language-jsx") or
            eqlIgnoreCase(token, "language-javascript") or
            eqlIgnoreCase(token, "language-cjs") or
            eqlIgnoreCase(token, "language-mjs") or
            eqlIgnoreCase(token, "language-ts") or
            eqlIgnoreCase(token, "language-tsx") or
            eqlIgnoreCase(token, "language-typescript"))
        {
            return true;
        }
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

fn codeTagClassInfoTSX(tag: []const u8) CodeClassInfo {
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
            if (classContainsLanguageTSX(value)) out.has_language = true;
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
    const info = codeTagClassInfoTSX(input[start .. end + 1]);
    return .{
        .end = end,
        .has_language_tsx = info.has_language,
        .has_hljs = info.has_hljs,
    };
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

fn numberEnd(code: []const u8, start: usize) usize {
    var i = start;
    if (i < code.len and code[i] == '.' and i + 1 < code.len and isDigit(code[i + 1])) {
        i += 1;
        while (i < code.len and (isDigit(code[i]) or code[i] == '_')) : (i += 1) {}
    } else if (i + 2 < code.len and code[i] == '0' and (code[i + 1] == 'x' or code[i + 1] == 'X')) {
        i += 2;
        while (i < code.len and (isHexDigit(code[i]) or code[i] == '_')) : (i += 1) {}
        if (i < code.len and code[i] == 'n') i += 1;
        return i;
    } else if (i + 2 < code.len and code[i] == '0' and (code[i + 1] == 'b' or code[i + 1] == 'B')) {
        i += 2;
        while (i < code.len and (isBinaryDigit(code[i]) or code[i] == '_')) : (i += 1) {}
        if (i < code.len and code[i] == 'n') i += 1;
        return i;
    } else if (i + 2 < code.len and code[i] == '0' and (code[i + 1] == 'o' or code[i + 1] == 'O')) {
        i += 2;
        while (i < code.len and (isOctDigit(code[i]) or code[i] == '_')) : (i += 1) {}
        if (i < code.len and code[i] == 'n') i += 1;
        return i;
    } else {
        while (i < code.len and (isDigit(code[i]) or code[i] == '_')) : (i += 1) {}
    }

    if (i < code.len and code[i] == '.') {
        if (i + 1 < code.len and isDigit(code[i + 1])) {
            i += 1;
            while (i < code.len and (isDigit(code[i]) or code[i] == '_')) : (i += 1) {}
        }
    }

    if (i < code.len and (code[i] == 'e' or code[i] == 'E')) {
        var j = i + 1;
        if (j < code.len and (code[j] == '+' or code[j] == '-')) j += 1;
        var has_exp_digits = false;
        while (j < code.len and (isDigit(code[j]) or code[j] == '_')) : (j += 1) {
            has_exp_digits = true;
        }
        if (has_exp_digits) i = j;
    }

    if (i < code.len and code[i] == 'n') i += 1;
    return i;
}

fn stringEnd(code: []const u8, start: usize) usize {
    if (start >= code.len) return start;
    const quote = code[start];
    var i = start + 1;
    var escaped = false;
    while (i < code.len) : (i += 1) {
        const c = code[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == quote) return i + 1;
    }
    return code.len;
}

fn startsWithAt(code: []const u8, idx: usize, needle: []const u8) bool {
    if (idx + needle.len > code.len) return false;
    return std.mem.eql(u8, code[idx .. idx + needle.len], needle);
}

fn isJsxTagBoundary(c: u8) bool {
    return isSpace(c) or c == '(' or c == '{' or c == '[' or c == '=' or c == ',' or c == ':' or c == ';';
}

fn isJsxNameStart(c: u8) bool {
    return isLetter(c) or c == '_' or c == '$';
}

fn isJsxNameContinue(c: u8) bool {
    return isJsxNameStart(c) or isDigit(c) or c == '-' or c == '.' or c == ':';
}

fn jsxTagEnd(code: []const u8, start: usize) ?usize {
    if (!startsWithAt(code, start, "&lt;")) return null;
    if (start > 0 and !isJsxTagBoundary(code[start - 1])) return null;

    var i = start + 4;
    if (i >= code.len) return null;
    if (startsWithAt(code, i, "&gt;")) return i + 4; // fragment open
    if (code[i] == '/') i += 1;
    if (startsWithAt(code, i, "&gt;")) return i + 4; // fragment close
    if (i >= code.len or !isJsxNameStart(code[i])) return null;

    i += 1;
    while (i < code.len and isJsxNameContinue(code[i])) : (i += 1) {}

    while (i < code.len) : (i += 1) {
        if (startsWithAt(code, i, "&gt;")) return i + 4;
    }
    return null;
}

fn writeHighlightedTSX(code: []const u8, w: *Writer) void {
    var i: usize = 0;

    while (i < code.len) {
        if (i + 1 < code.len and code[i] == '/' and code[i + 1] == '*') {
            var j = i + 2;
            while (j + 1 < code.len and !(code[j] == '*' and code[j + 1] == '/')) : (j += 1) {}
            if (j + 1 < code.len) {
                j += 2;
            } else {
                j = code.len;
            }
            w.writeSpan("hljs-comment", code[i..j]);
            i = j;
            continue;
        }

        if (i + 1 < code.len and code[i] == '/' and code[i + 1] == '/') {
            var j = i + 2;
            while (j < code.len and code[j] != '\n') : (j += 1) {}
            w.writeSpan("hljs-comment", code[i..j]);
            i = j;
            continue;
        }

        if (code[i] == '"' or code[i] == '\'' or code[i] == '`') {
            const j = stringEnd(code, i);
            w.writeSpan("hljs-string", code[i..j]);
            i = j;
            continue;
        }

        if (isDigit(code[i]) or (code[i] == '.' and i + 1 < code.len and isDigit(code[i + 1]))) {
            const j = numberEnd(code, i);
            w.writeSpan("hljs-number", code[i..j]);
            i = j;
            continue;
        }

        if (code[i] == '@' and i + 1 < code.len and isIdentStart(code[i + 1])) {
            var j = i + 2;
            while (j < code.len and isIdentContinue(code[j])) : (j += 1) {}
            w.writeSpan("hljs-meta", code[i..j]);
            i = j;
            continue;
        }

        if (jsxTagEnd(code, i)) |j| {
            w.writeSpan("hljs-tag", code[i..j]);
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
        const should_highlight = open.has_language_tsx and !open.has_hljs;
        if (!should_highlight) {
            w.writeSlice(input[i .. close.end + 1]);
            cursor = close.end + 1;
            i = cursor;
            continue;
        }

        writeCodeOpenTagWithHljs(input[i .. open.end + 1], w);
        writeHighlightedTSX(inner, w);
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

test "highlights plain text language-tsx code blocks" {
    const input = "<pre><code class=\"language-tsx\">const App = () =&gt; &lt;Button label={msg} /&gt;;</code></pre>";
    const got = runForTest(input);
    const expected = "<pre><code class=\"language-tsx hljs\"><span class=\"hljs-keyword\">const</span> App = () =&gt; <span class=\"hljs-tag\">&lt;Button label={msg} /&gt;</span>;</code></pre>";
    try std.testing.expectEqualStrings(expected, got);
}

test "skips code blocks that already contain spans" {
    const input = "<code class=\"language-js hljs\"><span class=\"hljs-keyword\">const</span> x = <span class=\"hljs-number\">1</span>;</code>";
    const got = runForTest(input);
    try std.testing.expectEqualStrings(input, got);
}

test "skips non-js-tsx code blocks" {
    const input = "<code class=\"language-rust\">const x = 1;</code>";
    const got = runForTest(input);
    try std.testing.expectEqualStrings(input, got);
}

test "highlights js ts and jsx aliases" {
    const input = "<code class=\"language-jsx\">const n: number = 0xff; // comment</code><code class=\"language-ts\">console.log(n)</code>";
    const got = runForTest(input);
    const expected = "<code class=\"language-jsx hljs\"><span class=\"hljs-keyword\">const</span> n: <span class=\"hljs-type\">number</span> = <span class=\"hljs-number\">0xff</span>; <span class=\"hljs-comment\">// comment</span></code><code class=\"language-ts hljs\"><span class=\"hljs-built_in\">console</span>.log(n)</code>";
    try std.testing.expectEqualStrings(expected, got);
}
