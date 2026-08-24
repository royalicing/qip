const std = @import("std");

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = 4 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "text/html";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const KeywordSet = std.StaticStringMap(void).initComptime(.{
    .{ "abstract", {} },
    .{ "assert", {} },
    .{ "break", {} },
    .{ "case", {} },
    .{ "catch", {} },
    .{ "class", {} },
    .{ "continue", {} },
    .{ "default", {} },
    .{ "do", {} },
    .{ "else", {} },
    .{ "enum", {} },
    .{ "extends", {} },
    .{ "final", {} },
    .{ "finally", {} },
    .{ "for", {} },
    .{ "if", {} },
    .{ "implements", {} },
    .{ "import", {} },
    .{ "instanceof", {} },
    .{ "interface", {} },
    .{ "native", {} },
    .{ "new", {} },
    .{ "package", {} },
    .{ "permits", {} },
    .{ "private", {} },
    .{ "protected", {} },
    .{ "public", {} },
    .{ "record", {} },
    .{ "return", {} },
    .{ "sealed", {} },
    .{ "static", {} },
    .{ "strictfp", {} },
    .{ "super", {} },
    .{ "switch", {} },
    .{ "synchronized", {} },
    .{ "this", {} },
    .{ "throw", {} },
    .{ "throws", {} },
    .{ "transient", {} },
    .{ "try", {} },
    .{ "var", {} },
    .{ "volatile", {} },
    .{ "while", {} },
    .{ "yield", {} },
});

const TypeSet = std.StaticStringMap(void).initComptime(.{
    .{ "boolean", {} },
    .{ "byte", {} },
    .{ "char", {} },
    .{ "double", {} },
    .{ "float", {} },
    .{ "int", {} },
    .{ "long", {} },
    .{ "short", {} },
    .{ "void", {} },
    .{ "String", {} },
    .{ "Object", {} },
    .{ "Class", {} },
    .{ "Path", {} },
    .{ "Memory", {} },
    .{ "ExportFunction", {} },
    .{ "Instance", {} },
});

const LiteralSet = std.StaticStringMap(void).initComptime(.{
    .{ "false", {} },
    .{ "null", {} },
    .{ "true", {} },
});

const BuiltinSet = std.StaticStringMap(void).initComptime(.{
    .{ "System", {} },
    .{ "Math", {} },
    .{ "Integer", {} },
    .{ "Long", {} },
    .{ "Double", {} },
    .{ "Boolean", {} },
    .{ "StandardCharsets", {} },
    .{ "Parser", {} },
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
        self.openSpan(class_name);
        self.writeSlice(text);
        self.closeSpan();
    }

    fn openSpan(self: *Writer, class_name: []const u8) void {
        self.writeSlice("<span class=\"");
        self.writeSlice(class_name);
        self.writeSlice("\">");
    }

    fn closeSpan(self: *Writer) void {
        self.writeSlice("</span>");
    }
};

const CodeOpenTag = struct {
    end: usize,
    has_language_java: bool,
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

fn classContainsLanguageJava(value: []const u8) bool {
    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and isSpace(value[i])) : (i += 1) {}
        const start = i;
        while (i < value.len and !isSpace(value[i])) : (i += 1) {}
        if (i <= start) continue;
        const token = value[start..i];
        if (eqlIgnoreCase(token, "language-java")) return true;
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

fn codeTagClassInfoJava(tag: []const u8) CodeClassInfo {
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
            if (classContainsLanguageJava(value)) out.has_language = true;
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
    const info = codeTagClassInfoJava(input[start .. end + 1]);
    return .{ .end = end, .has_language_java = info.has_language, .has_hljs = info.has_hljs };
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

fn stringEnd(code: []const u8, start: usize) usize {
    if (start >= code.len) return start;
    const quote = code[start];
    const triple = start + 2 < code.len and code[start + 1] == quote and code[start + 2] == quote;
    var i = start + (if (triple) @as(usize, 3) else 1);
    var escaped = false;
    while (i < code.len) {
        const c = code[i];
        if (escaped) {
            escaped = false;
            i += 1;
            continue;
        }
        if (c == '\\') {
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
            if (previous == 'e' or previous == 'E' or previous == 'p' or previous == 'P') {
                i += 1;
                continue;
            }
        }
        break;
    }
    return i;
}

fn matchingParen(code: []const u8, start: usize) ?usize {
    if (start >= code.len or code[start] != '(') return null;
    var depth: usize = 1;
    var i = start + 1;
    while (i < code.len) {
        if (code[i] == '"' or code[i] == '\'') {
            i = stringEnd(code, i);
            continue;
        }
        if (code[i] == '(') depth += 1;
        if (code[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
        i += 1;
    }
    return null;
}

fn skipSpace(code: []const u8, start: usize) usize {
    var i = start;
    while (i < code.len and isSpace(code[i])) : (i += 1) {}
    return i;
}

fn isMethodDeclaration(code: []const u8, ident_end: usize) ?struct { params_start: usize, params_end: usize } {
    const params_start = skipSpace(code, ident_end);
    if (params_start >= code.len or code[params_start] != '(') return null;
    const params_end = matchingParen(code, params_start) orelse return null;
    var after = skipSpace(code, params_end + 1);
    if (after + "throws".len <= code.len and std.mem.eql(u8, code[after .. after + "throws".len], "throws")) {
        after += "throws".len;
        while (after < code.len and code[after] != '{' and code[after] != ';' and code[after] != '\n') : (after += 1) {}
    }
    if (after < code.len and code[after] == '{') return .{ .params_start = params_start, .params_end = params_end };
    return null;
}

fn isConstantName(ident: []const u8) bool {
    var has_letter = false;
    for (ident) |c| {
        if (c >= 'a' and c <= 'z') return false;
        if (c >= 'A' and c <= 'Z') has_letter = true;
    }
    return has_letter;
}

fn writeHighlightedJava(code: []const u8, w: *Writer) void {
    var i: usize = 0;
    var expect_class_name = false;
    var expect_inherited_name = false;
    var record_declaration = false;
    while (i < code.len) {
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
        if (code[i] == '"' or code[i] == '\'') {
            const j = stringEnd(code, i);
            w.writeSpan("hljs-string", code[i..j]);
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
        if (isDigit(code[i])) {
            const j = numberEnd(code, i);
            w.writeSpan("hljs-number", code[i..j]);
            i = j;
            continue;
        }
        if (code[i] == '=') {
            w.writeSpan("hljs-operator", code[i .. i + 1]);
            i += 1;
            continue;
        }
        if (isIdentStart(code[i])) {
            var j = i + 1;
            while (j < code.len and isIdentContinue(code[j])) : (j += 1) {}
            const ident = code[i..j];
            if (KeywordSet.get(ident) != null) {
                w.writeSpan("hljs-keyword", ident);
                expect_class_name = std.mem.eql(u8, ident, "class") or std.mem.eql(u8, ident, "interface") or
                    std.mem.eql(u8, ident, "enum") or std.mem.eql(u8, ident, "record");
                record_declaration = std.mem.eql(u8, ident, "record");
                expect_inherited_name = std.mem.eql(u8, ident, "extends") or std.mem.eql(u8, ident, "implements");
            } else if (expect_class_name) {
                w.writeSpan("hljs-title class_", ident);
                expect_class_name = false;
                if (record_declaration) {
                    const params_start = skipSpace(code, j);
                    if (params_start < code.len and code[params_start] == '(') {
                        if (matchingParen(code, params_start)) |params_end| {
                            w.writeSlice(code[j..params_start]);
                            w.openSpan("hljs-params");
                            w.writeByte('(');
                            writeHighlightedJava(code[params_start + 1 .. params_end], w);
                            w.writeByte(')');
                            w.closeSpan();
                            i = params_end + 1;
                            record_declaration = false;
                            continue;
                        }
                    }
                }
                record_declaration = false;
            } else if (expect_inherited_name) {
                w.writeSpan("hljs-title class_", ident);
                expect_inherited_name = false;
            } else if (isMethodDeclaration(code, j)) |method| {
                w.writeSpan("hljs-title function_", ident);
                w.writeSlice(code[j..method.params_start]);
                w.openSpan("hljs-params");
                w.writeByte('(');
                writeHighlightedJava(code[method.params_start + 1 .. method.params_end], w);
                w.writeByte(')');
                w.closeSpan();
                i = method.params_end + 1;
                continue;
            } else if (isConstantName(ident) and skipSpace(code, j) < code.len and code[skipSpace(code, j)] == '=') {
                w.writeSpan("hljs-variable", ident);
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
        const should_highlight = open.has_language_java and !open.has_hljs;
        if (!should_highlight) {
            w.writeSlice(input[i .. close.end + 1]);
            cursor = close.end + 1;
            i = cursor;
            continue;
        }

        writeCodeOpenTagWithHljs(input[i .. open.end + 1], w);
        writeHighlightedJava(inner, w);
        w.writeSlice(input[close.start .. close.end + 1]);
        cursor = close.end + 1;
        i = cursor;
    }
    if (cursor < input.len) {
        w.writeSlice(input[cursor..]);
    }
}

fn renderImpl(input_size: u32) u32 {
    const input_len: usize = @intCast(input_size);
    if (input_len > INPUT_CAP) @trap();
    const input = input_buf[0..input_len];

    var w = Writer{};
    transformHTML(input, &w);
    if (w.overflow) @trap();
    return @as(u32, @intCast(w.idx));
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

fn runForTest(input: []const u8) []const u8 {
    if (input.len > INPUT_CAP) @trap();
    @memcpy(input_buf[0..input.len], input);
    const out_len = renderImpl(@as(u32, @intCast(input.len)));
    return output_buf[0..@as(usize, @intCast(out_len))];
}

test "highlights Java declarations strings and literals" {
    const input = "<pre><code class=\"language-java\">public final class App { String name = \"QIP\"; boolean ready = true; }</code></pre>";
    const got = runForTest(input);
    const expected = "<pre><code class=\"language-java hljs\"><span class=\"hljs-keyword\">public</span> <span class=\"hljs-keyword\">final</span> <span class=\"hljs-keyword\">class</span> <span class=\"hljs-title class_\">App</span> { <span class=\"hljs-type\">String</span> name <span class=\"hljs-operator\">=</span> <span class=\"hljs-string\">\"QIP\"</span>; <span class=\"hljs-type\">boolean</span> ready <span class=\"hljs-operator\">=</span> <span class=\"hljs-literal\">true</span>; }</code></pre>";
    try std.testing.expectEqualStrings(expected, got);
}

test "highlights Java annotations comments and numbers" {
    const input = "<code class=\"language-java\">@Override public int size() { return 42; } // bytes</code>";
    const got = runForTest(input);
    const expected = "<code class=\"language-java hljs\"><span class=\"hljs-meta\">@Override</span> <span class=\"hljs-keyword\">public</span> <span class=\"hljs-type\">int</span> <span class=\"hljs-title function_\">size</span><span class=\"hljs-params\">()</span> { <span class=\"hljs-keyword\">return</span> <span class=\"hljs-number\">42</span>; } <span class=\"hljs-comment\">// bytes</span></code>";
    try std.testing.expectEqualStrings(expected, got);
}

test "skips highlighted and non-Java blocks" {
    const highlighted = "<code class=\"language-java hljs\"><span class=\"hljs-keyword\">class</span></code>";
    try std.testing.expectEqualStrings(highlighted, runForTest(highlighted));
    const python = "<code class=\"language-python\">print(1)</code>";
    try std.testing.expectEqualStrings(python, runForTest(python));
}
