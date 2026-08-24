const std = @import("std");

const KeywordSet = std.StaticStringMap(void).initComptime(.{
    .{ "abstract", {} },  .{ "as", {} },      .{ "asserts", {} },    .{ "async", {} },
    .{ "await", {} },     .{ "break", {} },   .{ "case", {} },       .{ "catch", {} },
    .{ "class", {} },     .{ "const", {} },   .{ "continue", {} },   .{ "debugger", {} },
    .{ "declare", {} },   .{ "default", {} }, .{ "delete", {} },     .{ "do", {} },
    .{ "else", {} },      .{ "enum", {} },    .{ "export", {} },     .{ "extends", {} },
    .{ "finally", {} },   .{ "for", {} },     .{ "from", {} },       .{ "function", {} },
    .{ "get", {} },       .{ "if", {} },      .{ "implements", {} }, .{ "import", {} },
    .{ "in", {} },        .{ "infer", {} },   .{ "instanceof", {} }, .{ "interface", {} },
    .{ "is", {} },        .{ "keyof", {} },   .{ "let", {} },        .{ "module", {} },
    .{ "namespace", {} }, .{ "new", {} },     .{ "of", {} },         .{ "override", {} },
    .{ "package", {} },   .{ "private", {} }, .{ "protected", {} },  .{ "public", {} },
    .{ "readonly", {} },  .{ "return", {} },  .{ "satisfies", {} },  .{ "set", {} },
    .{ "static", {} },    .{ "super", {} },   .{ "switch", {} },     .{ "this", {} },
    .{ "throw", {} },     .{ "try", {} },     .{ "type", {} },       .{ "typeof", {} },
    .{ "using", {} },     .{ "var", {} },     .{ "void", {} },       .{ "while", {} },
    .{ "with", {} },      .{ "yield", {} },
});

const TypeSet = std.StaticStringMap(void).initComptime(.{
    .{ "any", {} },    .{ "Array", {} },      .{ "bigint", {} },  .{ "boolean", {} },
    .{ "Date", {} },   .{ "Error", {} },      .{ "Map", {} },     .{ "never", {} },
    .{ "number", {} }, .{ "object", {} },     .{ "Promise", {} }, .{ "ReadonlyArray", {} },
    .{ "Record", {} }, .{ "RegExp", {} },     .{ "Set", {} },     .{ "string", {} },
    .{ "symbol", {} }, .{ "Uint8Array", {} }, .{ "unknown", {} },
});

const LiteralSet = std.StaticStringMap(void).initComptime(.{
    .{ "false", {} }, .{ "Infinity", {} },  .{ "NaN", {} }, .{ "null", {} },
    .{ "true", {} },  .{ "undefined", {} },
});

const BuiltinSet = std.StaticStringMap(void).initComptime(.{
    .{ "Array", {} },       .{ "Boolean", {} },    .{ "clearInterval", {} }, .{ "clearTimeout", {} },
    .{ "console", {} },     .{ "Date", {} },       .{ "document", {} },      .{ "fetch", {} },
    .{ "globalThis", {} },  .{ "JSON", {} },       .{ "Map", {} },           .{ "Math", {} },
    .{ "Number", {} },      .{ "Object", {} },     .{ "Promise", {} },       .{ "RegExp", {} },
    .{ "setInterval", {} }, .{ "setTimeout", {} }, .{ "String", {} },        .{ "Symbol", {} },
    .{ "window", {} },
});

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
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

fn numberEnd(code: []const u8, start: usize) usize {
    var i = start;
    if (code[i] == '.' and i + 1 < code.len and isDigit(code[i + 1])) {
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
    if (i < code.len and code[i] == '.' and i + 1 < code.len and isDigit(code[i + 1])) {
        i += 1;
        while (i < code.len and (isDigit(code[i]) or code[i] == '_')) : (i += 1) {}
    }
    if (i < code.len and (code[i] == 'e' or code[i] == 'E')) {
        var end = i + 1;
        if (end < code.len and (code[end] == '+' or code[end] == '-')) end += 1;
        const digits_start = end;
        while (end < code.len and (isDigit(code[end]) or code[end] == '_')) : (end += 1) {}
        if (end > digits_start) i = end;
    }
    if (i < code.len and code[i] == 'n') i += 1;
    return i;
}

const Quote = struct {
    byte: u8,
    len: usize,
};

fn quoteAt(code: []const u8, start: usize) ?Quote {
    if (start >= code.len) return null;
    if (code[start] == '"' or code[start] == '\'' or code[start] == '`') return .{ .byte = code[start], .len = 1 };
    if (startsWithAt(code, start, "&quot;")) return .{ .byte = '"', .len = 6 };
    if (startsWithAt(code, start, "&#39;")) return .{ .byte = '\'', .len = 5 };
    return null;
}

fn stringEnd(code: []const u8, start: usize, quote: Quote) usize {
    var escaped = false;
    var i = start + quote.len;
    while (i < code.len) {
        if (escaped) {
            escaped = false;
            i += 1;
        } else if (code[i] == '\\') {
            escaped = true;
            i += 1;
        } else if (quoteAt(code, i)) |candidate| {
            if (candidate.byte == quote.byte and candidate.len == quote.len) return i + candidate.len;
            i += 1;
        } else {
            i += 1;
        }
    }
    return code.len;
}

fn startsWithAt(code: []const u8, index: usize, needle: []const u8) bool {
    return index + needle.len <= code.len and std.mem.eql(u8, code[index .. index + needle.len], needle);
}

fn isJsxTagBoundary(c: u8) bool {
    return isSpace(c) or c == '(' or c == '{' or c == '}' or c == '[' or c == '=' or c == ',' or c == ':' or c == ';';
}

fn jsxTagEnd(code: []const u8, start: usize) ?usize {
    if (!startsWithAt(code, start, "&lt;")) return null;
    if (start > 0 and !isJsxTagBoundary(code[start - 1])) return null;
    var i = start + 4;
    if (i >= code.len) return null;
    if (startsWithAt(code, i, "&gt;")) return i + 4;
    if (code[i] == '/') i += 1;
    if (startsWithAt(code, i, "&gt;")) return i + 4;
    if (i >= code.len or !isIdentStart(code[i])) return null;
    i += 1;
    while (i < code.len and (isIdentContinue(code[i]) or code[i] == '-' or code[i] == '.' or code[i] == ':')) : (i += 1) {}
    while (i < code.len) : (i += 1) if (startsWithAt(code, i, "&gt;")) return i + 4;
    return null;
}

fn nextNonSpace(code: []const u8, start: usize) usize {
    var i = start;
    while (i < code.len and isSpace(code[i])) : (i += 1) {}
    return i;
}

fn matchingParen(code: []const u8, start: usize) ?usize {
    if (start >= code.len or code[start] != '(') return null;
    var depth: usize = 1;
    var i = start + 1;
    while (i < code.len) {
        if (quoteAt(code, i)) |quote| {
            i = stringEnd(code, i, quote);
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

fn braceExpressionEnd(code: []const u8, start: usize) usize {
    var depth: usize = 1;
    var i = start + 2;
    while (i < code.len) {
        if (quoteAt(code, i)) |quote| {
            i = stringEnd(code, i, quote);
            continue;
        }
        if (code[i] == '{') depth += 1;
        if (code[i] == '}') {
            depth -= 1;
            i += 1;
            if (depth == 0) return i;
            continue;
        }
        i += 1;
    }
    return code.len;
}

fn writeString(code: []const u8, start: usize, quote: Quote, writer: anytype) usize {
    if (quote.byte != '`') {
        const end = stringEnd(code, start, quote);
        writer.writeSpan("hljs-string", code[start..end]);
        return end;
    }

    writer.openSpan("hljs-string");
    writer.writeSlice(code[start .. start + quote.len]);
    var i = start + quote.len;
    while (i < code.len) {
        if (quoteAt(code, i)) |candidate| {
            if (candidate.byte == '`') {
                writer.writeSlice(code[i .. i + candidate.len]);
                i += candidate.len;
                writer.closeSpan();
                return i;
            }
        }
        if (startsWithAt(code, i, "${")) {
            const end = braceExpressionEnd(code, i);
            writer.writeSpan("hljs-subst", code[i..end]);
            i = end;
            continue;
        }
        if (code[i] == '\\' and i + 1 < code.len) {
            writer.writeSlice(code[i .. i + 2]);
            i += 2;
            continue;
        }
        writer.writeByte(code[i]);
        i += 1;
    }
    writer.closeSpan();
    return i;
}

fn regexpEnd(code: []const u8, start: usize) usize {
    var i = start + 1;
    var escaped = false;
    var in_class = false;
    while (i < code.len) : (i += 1) {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (code[i] == '\\') {
            escaped = true;
            continue;
        }
        if (code[i] == '[') in_class = true;
        if (code[i] == ']') in_class = false;
        if (code[i] == '/' and !in_class) {
            i += 1;
            while (i < code.len and isLetter(code[i])) : (i += 1) {}
            return i;
        }
        if (code[i] == '\n') return start + 1;
    }
    return start + 1;
}

fn writeJsxTag(code: []const u8, start: usize, end: usize, writer: anytype) void {
    writer.openSpan("hljs-tag");
    writer.writeSlice("&lt;");
    var i = start + 4;
    if (i < end and code[i] == '/') {
        writer.writeByte('/');
        i += 1;
    }
    const name_start = i;
    while (i < end and (isIdentContinue(code[i]) or code[i] == '-' or code[i] == '.' or code[i] == ':')) : (i += 1) {}
    if (i > name_start) writer.writeSpan("hljs-name", code[name_start..i]);

    while (i < end) {
        if (startsWithAt(code, i, "&gt;")) {
            writer.writeSlice("&gt;");
            i += 4;
            continue;
        }
        if (quoteAt(code, i)) |quote| {
            const string_end = @min(stringEnd(code, i, quote), end);
            writer.writeSpan("hljs-string", code[i..string_end]);
            i = string_end;
            continue;
        }
        if (isIdentStart(code[i])) {
            var attr_end = i + 1;
            while (attr_end < end and (isIdentContinue(code[attr_end]) or code[attr_end] == '-')) : (attr_end += 1) {}
            const after = nextNonSpace(code, attr_end);
            if (after < end and code[after] == '=') {
                writer.writeSpan("hljs-attr", code[i..attr_end]);
            } else {
                writer.writeSlice(code[i..attr_end]);
            }
            i = attr_end;
            continue;
        }
        writer.writeByte(code[i]);
        i += 1;
    }
    writer.closeSpan();
}

const ExpectedTitle = enum { none, function, class, inherited };

fn looksLikeArrowBinding(code: []const u8, ident_end: usize) bool {
    var i = nextNonSpace(code, ident_end);
    if (i >= code.len or code[i] != '=') return false;
    i = nextNonSpace(code, i + 1);
    if (i >= code.len or code[i] != '(') return false;
    const close = matchingParen(code, i) orelse return false;
    const after = nextNonSpace(code, close + 1);
    return startsWithAt(code, after, "=&gt;") or startsWithAt(code, after, "=>");
}

fn writeImpl(code: []const u8, writer: anytype, in_params: bool) void {
    var i: usize = 0;
    var expected_title: ExpectedTitle = .none;
    var can_start_regexp = true;
    while (i < code.len) {
        if (i + 1 < code.len and code[i] == '/' and code[i + 1] == '*') {
            var end = i + 2;
            while (end + 1 < code.len and !(code[end] == '*' and code[end + 1] == '/')) : (end += 1) {}
            end = if (end + 1 < code.len) end + 2 else code.len;
            writer.writeSpan("hljs-comment", code[i..end]);
            i = end;
            continue;
        }
        if (i + 1 < code.len and code[i] == '/' and code[i + 1] == '/') {
            var end = i + 2;
            while (end < code.len and code[end] != '\n') : (end += 1) {}
            writer.writeSpan("hljs-comment", code[i..end]);
            i = end;
            continue;
        }
        if (quoteAt(code, i)) |quote| {
            i = writeString(code, i, quote, writer);
            can_start_regexp = false;
            continue;
        }
        if (code[i] == '/' and can_start_regexp) {
            const end = regexpEnd(code, i);
            if (end > i + 1) {
                writer.writeSpan("hljs-regexp", code[i..end]);
                i = end;
                can_start_regexp = false;
                continue;
            }
        }
        if (isDigit(code[i]) or (code[i] == '.' and i + 1 < code.len and isDigit(code[i + 1]))) {
            const end = numberEnd(code, i);
            writer.writeSpan("hljs-number", code[i..end]);
            i = end;
            can_start_regexp = false;
            continue;
        }
        if (code[i] == '@' and i + 1 < code.len and isIdentStart(code[i + 1])) {
            var end = i + 2;
            while (end < code.len and isIdentContinue(code[end])) : (end += 1) {}
            writer.writeSpan("hljs-meta", code[i..end]);
            i = end;
            continue;
        }
        if (jsxTagEnd(code, i)) |end| {
            writeJsxTag(code, i, end, writer);
            i = end;
            can_start_regexp = false;
            continue;
        }
        if (code[i] == '(') {
            if (matchingParen(code, i)) |close| {
                const after = nextNonSpace(code, close + 1);
                const is_arrow = startsWithAt(code, after, "=&gt;") or startsWithAt(code, after, "=>");
                if (is_arrow) {
                    writer.writeByte('(');
                    writer.openSpan("hljs-params");
                    writeImpl(code[i + 1 .. close], writer, true);
                    writer.closeSpan();
                    writer.writeByte(')');
                    i = close + 1;
                    can_start_regexp = false;
                    continue;
                }
            }
        }
        if (isIdentStart(code[i])) {
            var end = i + 1;
            while (end < code.len and isIdentContinue(code[end])) : (end += 1) {}
            const ident = code[i..end];
            if (KeywordSet.get(ident) != null) {
                writer.writeSpan("hljs-keyword", ident);
                if (std.mem.eql(u8, ident, "function")) expected_title = .function;
                if (std.mem.eql(u8, ident, "class") or std.mem.eql(u8, ident, "interface")) expected_title = .class;
                if (std.mem.eql(u8, ident, "extends")) expected_title = .inherited;
                can_start_regexp = std.mem.eql(u8, ident, "return") or std.mem.eql(u8, ident, "throw") or std.mem.eql(u8, ident, "case");
            } else if (LiteralSet.get(ident) != null) {
                writer.writeSpan("hljs-literal", ident);
                can_start_regexp = false;
            } else {
                const after = nextNonSpace(code, end);
                const follows_colon = after < code.len and code[after] == ':';
                const is_call = after < code.len and code[after] == '(';
                const close = if (is_call) matchingParen(code, after) else null;
                const after_call = if (close) |pos| nextNonSpace(code, pos + 1) else code.len;
                const is_definition = is_call and after_call < code.len and code[after_call] == '{';
                const is_arrow_binding = looksLikeArrowBinding(code, end);

                if (expected_title == .function or is_arrow_binding) {
                    writer.writeSpan("hljs-title function_", ident);
                } else if (expected_title == .class) {
                    writer.writeSpan("hljs-title class_", ident);
                } else if (expected_title == .inherited) {
                    writer.writeSpan("hljs-title class_ inherited__", ident);
                } else if (is_definition or is_call) {
                    writer.writeSpan("hljs-title function_", ident);
                } else if (in_params and follows_colon) {
                    writer.writeSpan("hljs-attr", ident);
                } else if (follows_colon) {
                    writer.writeSpan("hljs-attr", ident);
                } else if (std.mem.eql(u8, ident, "console")) {
                    writer.writeSpan("hljs-variable language_", ident);
                } else if (std.mem.eql(u8, ident, "JSON") or std.mem.eql(u8, ident, "Promise") or
                    (ident.len > 0 and ident[0] >= 'A' and ident[0] <= 'Z' and in_params))
                {
                    writer.writeSpan("hljs-title class_", ident);
                } else if (TypeSet.get(ident) != null) {
                    writer.writeSpan("hljs-built_in", ident);
                } else {
                    writer.writeSlice(ident);
                }

                if (is_definition and close != null) {
                    writer.writeByte('(');
                    writer.openSpan("hljs-params");
                    writeImpl(code[after + 1 .. close.?], writer, true);
                    writer.closeSpan();
                    writer.writeByte(')');
                    i = close.? + 1;
                    expected_title = .none;
                    can_start_regexp = false;
                    continue;
                }
                expected_title = .none;
                can_start_regexp = false;
            }
            i = end;
            continue;
        }
        if (!isSpace(code[i])) {
            can_start_regexp = code[i] == '=' or code[i] == '(' or code[i] == '{' or code[i] == '[' or
                code[i] == ',' or code[i] == ':' or code[i] == ';' or code[i] == '!';
        }
        writer.writeByte(code[i]);
        i += 1;
    }
}

pub fn write(code: []const u8, writer: anytype) void {
    writeImpl(code, writer, false);
}
