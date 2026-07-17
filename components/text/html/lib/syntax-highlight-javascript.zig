const std = @import("std");

const KeywordSet = std.StaticStringMap(void).initComptime(.{
    .{ "abstract", {} }, .{ "as", {} }, .{ "asserts", {} }, .{ "async", {} },
    .{ "await", {} }, .{ "break", {} }, .{ "case", {} }, .{ "catch", {} },
    .{ "class", {} }, .{ "const", {} }, .{ "continue", {} }, .{ "debugger", {} },
    .{ "declare", {} }, .{ "default", {} }, .{ "delete", {} }, .{ "do", {} },
    .{ "else", {} }, .{ "enum", {} }, .{ "export", {} }, .{ "extends", {} },
    .{ "finally", {} }, .{ "for", {} }, .{ "from", {} }, .{ "function", {} },
    .{ "get", {} }, .{ "if", {} }, .{ "implements", {} }, .{ "import", {} },
    .{ "in", {} }, .{ "infer", {} }, .{ "instanceof", {} }, .{ "interface", {} },
    .{ "is", {} }, .{ "keyof", {} }, .{ "let", {} }, .{ "module", {} },
    .{ "namespace", {} }, .{ "new", {} }, .{ "of", {} }, .{ "override", {} },
    .{ "package", {} }, .{ "private", {} }, .{ "protected", {} }, .{ "public", {} },
    .{ "readonly", {} }, .{ "return", {} }, .{ "satisfies", {} }, .{ "set", {} },
    .{ "static", {} }, .{ "super", {} }, .{ "switch", {} }, .{ "this", {} },
    .{ "throw", {} }, .{ "try", {} }, .{ "type", {} }, .{ "typeof", {} },
    .{ "using", {} }, .{ "var", {} }, .{ "void", {} }, .{ "while", {} },
    .{ "with", {} }, .{ "yield", {} },
});

const TypeSet = std.StaticStringMap(void).initComptime(.{
    .{ "any", {} }, .{ "Array", {} }, .{ "bigint", {} }, .{ "boolean", {} },
    .{ "Date", {} }, .{ "Error", {} }, .{ "Map", {} }, .{ "never", {} },
    .{ "number", {} }, .{ "object", {} }, .{ "Promise", {} }, .{ "ReadonlyArray", {} },
    .{ "Record", {} }, .{ "RegExp", {} }, .{ "Set", {} }, .{ "string", {} },
    .{ "symbol", {} }, .{ "Uint8Array", {} }, .{ "unknown", {} },
});

const LiteralSet = std.StaticStringMap(void).initComptime(.{
    .{ "false", {} }, .{ "Infinity", {} }, .{ "NaN", {} }, .{ "null", {} },
    .{ "true", {} }, .{ "undefined", {} },
});

const BuiltinSet = std.StaticStringMap(void).initComptime(.{
    .{ "Array", {} }, .{ "Boolean", {} }, .{ "clearInterval", {} }, .{ "clearTimeout", {} },
    .{ "console", {} }, .{ "Date", {} }, .{ "document", {} }, .{ "fetch", {} },
    .{ "globalThis", {} }, .{ "JSON", {} }, .{ "Map", {} }, .{ "Math", {} },
    .{ "Number", {} }, .{ "Object", {} }, .{ "Promise", {} }, .{ "RegExp", {} },
    .{ "setInterval", {} }, .{ "setTimeout", {} }, .{ "String", {} }, .{ "Symbol", {} },
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

fn stringEnd(code: []const u8, start: usize) usize {
    const quote = code[start];
    var escaped = false;
    var i = start + 1;
    while (i < code.len) : (i += 1) {
        if (escaped) {
            escaped = false;
        } else if (code[i] == '\\') {
            escaped = true;
        } else if (code[i] == quote) {
            return i + 1;
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

pub fn write(code: []const u8, writer: anytype) void {
    var i: usize = 0;
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
        if (code[i] == '"' or code[i] == '\'' or code[i] == '`') {
            const end = stringEnd(code, i);
            writer.writeSpan("hljs-string", code[i..end]);
            i = end;
            continue;
        }
        if (isDigit(code[i]) or (code[i] == '.' and i + 1 < code.len and isDigit(code[i + 1]))) {
            const end = numberEnd(code, i);
            writer.writeSpan("hljs-number", code[i..end]);
            i = end;
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
            writer.writeSpan("hljs-tag", code[i..end]);
            i = end;
            continue;
        }
        if (isIdentStart(code[i])) {
            var end = i + 1;
            while (end < code.len and isIdentContinue(code[end])) : (end += 1) {}
            const ident = code[i..end];
            if (KeywordSet.get(ident) != null) {
                writer.writeSpan("hljs-keyword", ident);
            } else if (TypeSet.get(ident) != null) {
                writer.writeSpan("hljs-type", ident);
            } else if (LiteralSet.get(ident) != null) {
                writer.writeSpan("hljs-literal", ident);
            } else if (BuiltinSet.get(ident) != null) {
                writer.writeSpan("hljs-built_in", ident);
            } else {
                writer.writeSlice(ident);
            }
            i = end;
            continue;
        }
        writer.writeByte(code[i]);
        i += 1;
    }
}
