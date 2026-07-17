const std = @import("std");

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (lower(x) != lower(y)) return false;
    return true;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn isNameStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '-';
}

fn isNameContinue(c: u8) bool {
    return isNameStart(c) or (c >= '0' and c <= '9');
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

fn commentEnd(code: []const u8, start: usize) usize {
    var i = start + 2;
    while (i + 1 < code.len and !(code[i] == '*' and code[i + 1] == '/')) : (i += 1) {}
    return if (i + 1 < code.len) i + 2 else code.len;
}

fn numberEnd(code: []const u8, start: usize) usize {
    var i = start;
    if (code[i] == '+' or code[i] == '-') i += 1;
    if (code[i] == '.') i += 1;
    while (i < code.len and ((code[i] >= '0' and code[i] <= '9') or code[i] == '.')) : (i += 1) {}
    while (i < code.len and ((code[i] >= 'a' and code[i] <= 'z') or code[i] == '%' or code[i] == '-')) : (i += 1) {}
    return i;
}

fn startsNumber(code: []const u8, start: usize) bool {
    if (code[start] >= '0' and code[start] <= '9') return true;
    if (code[start] == '.') return start + 1 < code.len and code[start + 1] >= '0' and code[start + 1] <= '9';
    if (code[start] != '+' and code[start] != '-') return false;
    if (start + 1 >= code.len) return false;
    if (code[start + 1] >= '0' and code[start + 1] <= '9') return true;
    return code[start + 1] == '.' and start + 2 < code.len and code[start + 2] >= '0' and code[start + 2] <= '9';
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isContainerAtRule(name: []const u8) bool {
    return eqlIgnoreCase(name, "media") or eqlIgnoreCase(name, "supports") or eqlIgnoreCase(name, "layer") or eqlIgnoreCase(name, "container") or eqlIgnoreCase(name, "keyframes");
}

pub fn write(code: []const u8, writer: anytype) void {
    var declaration_stack: [64]bool = [_]bool{false} ** 64;
    var property_stack: [64]bool = [_]bool{false} ** 64;
    var depth: usize = 0;
    var pending_container = false;
    var i: usize = 0;

    while (i < code.len) {
        const in_declarations = depth > 0 and declaration_stack[depth - 1];

        if (i + 1 < code.len and code[i] == '/' and code[i + 1] == '*') {
            const end = commentEnd(code, i);
            writer.writeSpan("hljs-comment", code[i..end]);
            i = end;
            continue;
        }
        if (code[i] == '"' or code[i] == '\'') {
            const end = stringEnd(code, i);
            writer.writeSpan("hljs-string", code[i..end]);
            i = end;
            continue;
        }
        if (code[i] == '&') {
            var end = i + 1;
            while (end < code.len and end - i <= 8 and code[end] != ';' and isNameContinue(code[end])) : (end += 1) {}
            if (end < code.len and code[end] == ';') end += 1;
            writer.writeSlice(code[i..end]);
            i = end;
            continue;
        }
        if (code[i] == '@' and i + 1 < code.len and isNameStart(code[i + 1])) {
            var end = i + 2;
            while (end < code.len and isNameContinue(code[end])) : (end += 1) {}
            writer.writeSpan("hljs-keyword", code[i..end]);
            pending_container = isContainerAtRule(code[i + 1 .. end]);
            i = end;
            continue;
        }
        if (code[i] == '{') {
            writer.writeByte(code[i]);
            if (depth < declaration_stack.len) {
                declaration_stack[depth] = !pending_container;
                property_stack[depth] = !pending_container;
                depth += 1;
            }
            pending_container = false;
            i += 1;
            continue;
        }
        if (code[i] == '}') {
            writer.writeByte(code[i]);
            if (depth > 0) depth -= 1;
            i += 1;
            continue;
        }
        if (in_declarations and code[i] == ';') {
            writer.writeByte(';');
            property_stack[depth - 1] = true;
            i += 1;
            continue;
        }
        if (in_declarations and property_stack[depth - 1] and isNameStart(code[i])) {
            var end = i + 1;
            while (end < code.len and isNameContinue(code[end])) : (end += 1) {}
            var next = end;
            while (next < code.len and isSpace(code[next])) : (next += 1) {}
            if (next < code.len and code[next] == ':') {
                writer.writeSpan("hljs-attribute", code[i..end]);
                property_stack[depth - 1] = false;
            } else {
                writer.writeSlice(code[i..end]);
            }
            i = end;
            continue;
        }
        if (in_declarations and code[i] == '#' and i + 1 < code.len and isHexDigit(code[i + 1])) {
            var end = i + 2;
            while (end < code.len and isHexDigit(code[end])) : (end += 1) {}
            writer.writeSpan("hljs-number", code[i..end]);
            i = end;
            continue;
        }
        if (startsNumber(code, i)) {
            const end = numberEnd(code, i);
            writer.writeSpan("hljs-number", code[i..end]);
            i = end;
            continue;
        }
        if (!in_declarations and code[i] == '.' and i + 1 < code.len and isNameStart(code[i + 1])) {
            var end = i + 2;
            while (end < code.len and isNameContinue(code[end])) : (end += 1) {}
            writer.writeSpan("hljs-selector-class", code[i..end]);
            i = end;
            continue;
        }
        if (!in_declarations and code[i] == '#' and i + 1 < code.len and isNameContinue(code[i + 1])) {
            var end = i + 2;
            while (end < code.len and isNameContinue(code[end])) : (end += 1) {}
            writer.writeSpan("hljs-selector-id", code[i..end]);
            i = end;
            continue;
        }
        if (!in_declarations and code[i] == ':' and i + 1 < code.len and (isNameStart(code[i + 1]) or code[i + 1] == ':')) {
            var end = i + 1;
            if (code[end] == ':') end += 1;
            while (end < code.len and isNameContinue(code[end])) : (end += 1) {}
            writer.writeSpan("hljs-selector-pseudo", code[i..end]);
            i = end;
            continue;
        }
        if (!in_declarations and code[i] == '[') {
            var end = i + 1;
            while (end < code.len and code[end] != ']') : (end += 1) {}
            if (end < code.len) end += 1;
            writer.writeSpan("hljs-selector-attr", code[i..end]);
            i = end;
            continue;
        }
        if (isNameStart(code[i])) {
            var end = i + 1;
            while (end < code.len and isNameContinue(code[end])) : (end += 1) {}
            var next = end;
            while (next < code.len and isSpace(code[next])) : (next += 1) {}
            if (in_declarations and next < code.len and code[next] == '(') {
                writer.writeSpan("hljs-built_in", code[i..end]);
            } else if (!in_declarations and !pending_container) {
                writer.writeSpan("hljs-selector-tag", code[i..end]);
            } else {
                writer.writeSlice(code[i..end]);
            }
            i = end;
            continue;
        }
        writer.writeByte(code[i]);
        i += 1;
    }
}
