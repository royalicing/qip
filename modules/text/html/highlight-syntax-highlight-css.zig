const std = @import("std");

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = 4 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "text/html";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const Writer = struct {
    idx: usize = 0,
    overflow: bool = false,

    fn writeByte(self: *Writer, byte: u8) void {
        if (self.overflow) return;
        if (self.idx == output_buf.len) {
            self.overflow = true;
            return;
        }
        output_buf[self.idx] = byte;
        self.idx += 1;
    }

    fn writeSlice(self: *Writer, value: []const u8) void {
        if (self.overflow or value.len == 0) return;
        if (value.len > output_buf.len - self.idx) {
            self.overflow = true;
            return;
        }
        @memcpy(output_buf[self.idx .. self.idx + value.len], value);
        self.idx += value.len;
    }

    fn writeSpan(self: *Writer, class_name: []const u8, value: []const u8) void {
        self.writeSlice("<span class=\"");
        self.writeSlice(class_name);
        self.writeSlice("\">");
        self.writeSlice(value);
        self.writeSlice("</span>");
    }
};

const CodeInfo = struct { end: usize, is_css: bool, has_hljs: bool };
const ClassRange = struct { start: usize, end: usize };
const CloseTag = struct { start: usize, end: usize };

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}
export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}
export fn output_ptr() u32 {
    return @intCast(@intFromPtr(&output_buf));
}
export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}
export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}
export fn input_content_type_size() u32 {
    return INPUT_CONTENT_TYPE.len;
}
export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}
export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

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

fn tokenInClass(value: []const u8, wanted: []const u8) bool {
    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and isSpace(value[i])) : (i += 1) {}
        const start = i;
        while (i < value.len and !isSpace(value[i])) : (i += 1) {}
        if (i > start and eqlIgnoreCase(value[start..i], wanted)) return true;
    }
    return false;
}

fn isCssClass(value: []const u8) bool {
    return tokenInClass(value, "language-css");
}

fn findTagEnd(input: []const u8, start: usize) ?usize {
    var quote: u8 = 0;
    var i = start;
    while (i < input.len) : (i += 1) {
        if (quote != 0) {
            if (input[i] == quote) quote = 0;
        } else if (input[i] == '"' or input[i] == '\'') {
            quote = input[i];
        } else if (input[i] == '>') {
            return i;
        }
    }
    return null;
}

fn findClassRange(tag: []const u8) ?ClassRange {
    var i: usize = 5;
    while (i < tag.len) {
        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len or tag[i] == '>') break;
        const name_start = i;
        while (i < tag.len and (isNameContinue(tag[i]) or tag[i] == ':')) : (i += 1) {}
        if (i == name_start) {
            i += 1;
            continue;
        }
        const name = tag[name_start..i];
        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len or tag[i] != '=') continue;
        i += 1;
        while (i < tag.len and isSpace(tag[i])) : (i += 1) {}
        if (i >= tag.len) break;

        var start = i;
        var end = i;
        if (tag[i] == '"' or tag[i] == '\'') {
            const quote = tag[i];
            start = i + 1;
            i += 1;
            while (i < tag.len and tag[i] != quote) : (i += 1) {}
            end = i;
            if (i < tag.len) i += 1;
        } else {
            start = i;
            while (i < tag.len and !isSpace(tag[i]) and tag[i] != '>') : (i += 1) {}
            end = i;
        }
        if (eqlIgnoreCase(name, "class")) return .{ .start = start, .end = end };
    }
    return null;
}

fn parseCodeOpen(input: []const u8, start: usize) ?CodeInfo {
    if (start + 5 > input.len or input[start] != '<' or !eqlIgnoreCase(input[start + 1 .. start + 5], "code")) return null;
    if (start + 5 < input.len and !isSpace(input[start + 5]) and input[start + 5] != '>') return null;
    const end = findTagEnd(input, start + 5) orelse return null;
    const range = findClassRange(input[start .. end + 1]) orelse return .{ .end = end, .is_css = false, .has_hljs = false };
    const value = input[start + range.start .. start + range.end];
    return .{ .end = end, .is_css = isCssClass(value), .has_hljs = tokenInClass(value, "hljs") };
}

fn findClose(input: []const u8, start: usize) ?CloseTag {
    var i = start;
    while (i + 7 <= input.len) : (i += 1) {
        if (input[i] == '<' and input[i + 1] == '/' and eqlIgnoreCase(input[i + 2 .. i + 6], "code")) {
            var end = i + 6;
            while (end < input.len and isSpace(input[end])) : (end += 1) {}
            if (end < input.len and input[end] == '>') return .{ .start = i, .end = end };
        }
    }
    return null;
}

fn writeOpenWithHljs(tag: []const u8, w: *Writer) void {
    const range = findClassRange(tag) orelse {
        w.writeSlice(tag);
        return;
    };
    w.writeSlice(tag[0..range.end]);
    w.writeSlice(" hljs");
    w.writeSlice(tag[range.end..]);
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
    if (code[i] == '.') i += 1;
    while (i < code.len and ((code[i] >= '0' and code[i] <= '9') or code[i] == '.')) : (i += 1) {}
    while (i < code.len and ((code[i] >= 'a' and code[i] <= 'z') or code[i] == '%' or code[i] == '-')) : (i += 1) {}
    return i;
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isContainerAtRule(name: []const u8) bool {
    return eqlIgnoreCase(name, "media") or eqlIgnoreCase(name, "supports") or eqlIgnoreCase(name, "layer") or eqlIgnoreCase(name, "container") or eqlIgnoreCase(name, "keyframes");
}

fn writeHighlightedCSS(code: []const u8, w: *Writer) void {
    var declaration_stack: [64]bool = [_]bool{false} ** 64;
    var property_stack: [64]bool = [_]bool{false} ** 64;
    var depth: usize = 0;
    var pending_container = false;
    var i: usize = 0;

    while (i < code.len) {
        const in_declarations = depth > 0 and declaration_stack[depth - 1];

        if (i + 1 < code.len and code[i] == '/' and code[i + 1] == '*') {
            const end = commentEnd(code, i);
            w.writeSpan("hljs-comment", code[i..end]);
            i = end;
            continue;
        }
        if (code[i] == '"' or code[i] == '\'') {
            const end = stringEnd(code, i);
            w.writeSpan("hljs-string", code[i..end]);
            i = end;
            continue;
        }
        if (code[i] == '&') {
            var end = i + 1;
            while (end < code.len and end - i <= 8 and code[end] != ';' and isNameContinue(code[end])) : (end += 1) {}
            if (end < code.len and code[end] == ';') end += 1;
            w.writeSlice(code[i..end]);
            i = end;
            continue;
        }
        if (code[i] == '@' and i + 1 < code.len and isNameStart(code[i + 1])) {
            var end = i + 2;
            while (end < code.len and isNameContinue(code[end])) : (end += 1) {}
            w.writeSpan("hljs-keyword", code[i..end]);
            pending_container = isContainerAtRule(code[i + 1 .. end]);
            i = end;
            continue;
        }
        if (code[i] == '{') {
            w.writeByte(code[i]);
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
            w.writeByte(code[i]);
            if (depth > 0) depth -= 1;
            i += 1;
            continue;
        }
        if (in_declarations and code[i] == ';') {
            w.writeByte(';');
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
                w.writeSpan("hljs-attribute", code[i..end]);
                property_stack[depth - 1] = false;
            } else {
                w.writeSlice(code[i..end]);
            }
            i = end;
            continue;
        }
        if (in_declarations and code[i] == '#' and i + 1 < code.len and isHexDigit(code[i + 1])) {
            var end = i + 2;
            while (end < code.len and isHexDigit(code[end])) : (end += 1) {}
            w.writeSpan("hljs-number", code[i..end]);
            i = end;
            continue;
        }
        if ((code[i] >= '0' and code[i] <= '9') or (code[i] == '.' and i + 1 < code.len and code[i + 1] >= '0' and code[i + 1] <= '9')) {
            const end = numberEnd(code, i);
            w.writeSpan("hljs-number", code[i..end]);
            i = end;
            continue;
        }
        if (!in_declarations and code[i] == '.' and i + 1 < code.len and isNameStart(code[i + 1])) {
            var end = i + 2;
            while (end < code.len and isNameContinue(code[end])) : (end += 1) {}
            w.writeSpan("hljs-selector-class", code[i..end]);
            i = end;
            continue;
        }
        if (!in_declarations and code[i] == '#' and i + 1 < code.len and isNameContinue(code[i + 1])) {
            var end = i + 2;
            while (end < code.len and isNameContinue(code[end])) : (end += 1) {}
            w.writeSpan("hljs-selector-id", code[i..end]);
            i = end;
            continue;
        }
        if (!in_declarations and code[i] == ':' and i + 1 < code.len and (isNameStart(code[i + 1]) or code[i + 1] == ':')) {
            var end = i + 1;
            if (end < code.len and code[end] == ':') end += 1;
            while (end < code.len and isNameContinue(code[end])) : (end += 1) {}
            w.writeSpan("hljs-selector-pseudo", code[i..end]);
            i = end;
            continue;
        }
        if (!in_declarations and code[i] == '[') {
            var end = i + 1;
            while (end < code.len and code[end] != ']') : (end += 1) {}
            if (end < code.len) end += 1;
            w.writeSpan("hljs-selector-attr", code[i..end]);
            i = end;
            continue;
        }
        if (isNameStart(code[i])) {
            var end = i + 1;
            while (end < code.len and isNameContinue(code[end])) : (end += 1) {}
            var next = end;
            while (next < code.len and isSpace(code[next])) : (next += 1) {}
            if (in_declarations and next < code.len and code[next] == '(') {
                w.writeSpan("hljs-built_in", code[i..end]);
            } else if (!in_declarations and !pending_container) {
                w.writeSpan("hljs-selector-tag", code[i..end]);
            } else {
                w.writeSlice(code[i..end]);
            }
            i = end;
            continue;
        }
        w.writeByte(code[i]);
        i += 1;
    }
}

fn transform(input: []const u8, w: *Writer) void {
    var cursor: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '<') {
            i += 1;
            continue;
        }
        const open = parseCodeOpen(input, i) orelse {
            i += 1;
            continue;
        };
        const close = findClose(input, open.end + 1) orelse {
            w.writeSlice(input[cursor..]);
            return;
        };
        w.writeSlice(input[cursor..i]);
        if (!open.is_css or open.has_hljs or std.mem.indexOf(u8, input[open.end + 1 .. close.start], "<span class=\"hljs-") != null) {
            w.writeSlice(input[i .. close.end + 1]);
        } else {
            writeOpenWithHljs(input[i .. open.end + 1], w);
            writeHighlightedCSS(input[open.end + 1 .. close.start], w);
            w.writeSlice(input[close.start .. close.end + 1]);
        }
        cursor = close.end + 1;
        i = cursor;
    }
    w.writeSlice(input[cursor..]);
}

export fn render(input_size: u32) u32 {
    const len: usize = @intCast(input_size);
    if (len > input_buf.len) @trap();
    var writer = Writer{};
    transform(input_buf[0..len], &writer);
    if (writer.overflow) @trap();
    return @intCast(writer.idx);
}

fn runForTest(input: []const u8) []const u8 {
    @memcpy(input_buf[0..input.len], input);
    return output_buf[0..render(@intCast(input.len))];
}

test "highlights selectors properties values strings and comments" {
    const input = "<code class=\"language-css\">.card:hover { color: #fff; width: 12rem; content: \"class color\"; /* display */ }</code>";
    const expected = "<code class=\"language-css hljs\"><span class=\"hljs-selector-class\">.card</span><span class=\"hljs-selector-pseudo\">:hover</span> { <span class=\"hljs-attribute\">color</span>: <span class=\"hljs-number\">#fff</span>; <span class=\"hljs-attribute\">width</span>: <span class=\"hljs-number\">12rem</span>; <span class=\"hljs-attribute\">content</span>: <span class=\"hljs-string\">\"class color\"</span>; <span class=\"hljs-comment\">/* display */</span> }</code>";
    try std.testing.expectEqualStrings(expected, runForTest(input));
}

test "skips other languages" {
    const input = "<code class=\"language-js\">const color = 1;</code>";
    try std.testing.expectEqualStrings(input, runForTest(input));
}
