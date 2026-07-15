const std = @import("std");

const INPUT_CAP: usize = 256 * 1024 * 1024;
const OUTPUT_CAP: usize = 256 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "application/warc";
const OUTPUT_CONTENT_TYPE = "application/warc";
const CONTENT_SIZE_TAG = "qip-content-size";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const WARCRecord = struct {
    next: usize,
    warc_type: []const u8,
    target_uri: []const u8,
    payload: []const u8,
};

const HTTPPayload = struct {
    status: u16,
    status_line: []const u8,
    content_type: []const u8,
    header_block: []const u8,
    body: []const u8,
};

const Element = struct {
    start: usize,
    open_end: usize,
    content_end: usize,
    end: usize,
    src: []const u8,
};

const Output = struct {
    idx: usize = 0,
    overflow: bool = false,

    fn remaining(self: *const Output) usize {
        return output_buf.len - self.idx;
    }

    fn writeByte(self: *Output, b: u8) void {
        if (self.overflow) return;
        if (self.remaining() < 1) {
            self.overflow = true;
            return;
        }
        output_buf[self.idx] = b;
        self.idx += 1;
    }

    fn writeSlice(self: *Output, s: []const u8) void {
        if (self.overflow or s.len == 0) return;
        if (self.remaining() < s.len) {
            self.overflow = true;
            return;
        }
        @memcpy(output_buf[self.idx .. self.idx + s.len], s);
        self.idx += s.len;
    }

    fn writeUnsigned(self: *Output, value: usize) void {
        var buf: [32]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, "{d}", .{value}) catch {
            self.overflow = true;
            return;
        };
        self.writeSlice(formatted);
    }
};

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&output_buf)));
}

export fn output_bytes_cap() u32 {
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

fn startsWithIgnoreCase(a: []const u8, prefix: []const u8) bool {
    if (a.len < prefix.len) return false;
    return eqlIgnoreCase(a[0..prefix.len], prefix);
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8, start: usize) ?usize {
    if (needle.len == 0) return start;
    if (start >= haystack.len or haystack.len - start < needle.len) return null;
    var i = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn trimASCIIWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end) : (start += 1) {
        const c = s[start];
        if (c != ' ' and c != '\t' and c != '\r' and c != '\n') break;
    }
    while (end > start) : (end -= 1) {
        const c = s[end - 1];
        if (c != ' ' and c != '\t' and c != '\r' and c != '\n') break;
    }
    return s[start..end];
}

fn skipASCIIWhitespaceIn(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\r' or s[i] == '\n')) : (i += 1) {}
    return i;
}

fn findHeaderEnd(buf: []const u8, start: usize) ?usize {
    if (start >= buf.len) return null;
    if (std.mem.indexOfPos(u8, buf, start, "\r\n\r\n")) |pos| return pos + 4;
    if (std.mem.indexOfPos(u8, buf, start, "\n\n")) |pos| return pos + 2;
    return null;
}

fn parseUnsigned10(s: []const u8) ?usize {
    if (s.len == 0) return null;
    var value: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        value = value * 10 + (c - '0');
    }
    return value;
}

fn parseStatusCode(status_line: []const u8) ?u16 {
    var i: usize = 0;
    while (i < status_line.len and status_line[i] != ' ') : (i += 1) {}
    if (i >= status_line.len) return null;
    while (i < status_line.len and status_line[i] == ' ') : (i += 1) {}
    const code_start = i;
    while (i < status_line.len and status_line[i] >= '0' and status_line[i] <= '9') : (i += 1) {}
    if (i == code_start) return null;
    const code = parseUnsigned10(status_line[code_start..i]) orelse return null;
    if (code > std.math.maxInt(u16)) return null;
    return @as(u16, @intCast(code));
}

fn parseWARCRecord(input: []const u8, start: usize) ?WARCRecord {
    const header_end = findHeaderEnd(input, start) orelse return null;
    const header_slice = input[start..header_end];
    var warc_type: []const u8 = "";
    var target_uri: []const u8 = "";
    var content_length: ?usize = null;

    var line_start: usize = 0;
    var line_index: usize = 0;
    while (line_start < header_slice.len) : (line_index += 1) {
        const nl = std.mem.indexOfPos(u8, header_slice, line_start, "\n") orelse header_slice.len;
        var line = header_slice[line_start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line = trimASCIIWhitespace(line);
        line_start = if (nl < header_slice.len) nl + 1 else header_slice.len;
        if (line.len == 0) break;
        if (line_index == 0) continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = trimASCIIWhitespace(line[0..colon]);
        const value = trimASCIIWhitespace(line[colon + 1 ..]);
        if (eqlIgnoreCase(key, "WARC-Type")) {
            warc_type = value;
        } else if (eqlIgnoreCase(key, "WARC-Target-URI")) {
            target_uri = value;
        } else if (eqlIgnoreCase(key, "Content-Length")) {
            content_length = parseUnsigned10(value);
        }
    }

    const payload_len = content_length orelse return null;
    if (header_end + payload_len > input.len) return null;
    const payload = input[header_end .. header_end + payload_len];
    var next = header_end + payload_len;
    while (next < input.len and (input[next] == '\r' or input[next] == '\n')) : (next += 1) {}

    return .{ .next = next, .warc_type = warc_type, .target_uri = target_uri, .payload = payload };
}

fn parseHTTPPayload(payload: []const u8) ?HTTPPayload {
    const header_end = findHeaderEnd(payload, 0) orelse return null;
    const header_block = payload[0..header_end];
    var status_line: []const u8 = "";
    var status: ?u16 = null;
    var content_type: []const u8 = "";

    var line_start: usize = 0;
    var line_index: usize = 0;
    while (line_start < header_block.len) : (line_index += 1) {
        const nl = std.mem.indexOfPos(u8, header_block, line_start, "\n") orelse header_block.len;
        var line = header_block[line_start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line_start = if (nl < header_block.len) nl + 1 else header_block.len;

        const trimmed = trimASCIIWhitespace(line);
        if (trimmed.len == 0) break;
        if (line_index == 0) {
            status_line = trimmed;
            status = parseStatusCode(trimmed);
            continue;
        }

        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const key = trimASCIIWhitespace(trimmed[0..colon]);
        const value = trimASCIIWhitespace(trimmed[colon + 1 ..]);
        if (eqlIgnoreCase(key, "Content-Type")) {
            content_type = value;
        }
    }

    return .{
        .status = status orelse return null,
        .status_line = status_line,
        .content_type = content_type,
        .header_block = header_block,
        .body = payload[header_end..],
    };
}

fn mimeTypeToken(content_type_raw: []const u8) []const u8 {
    const content_type = trimASCIIWhitespace(content_type_raw);
    var end = content_type.len;
    if (std.mem.indexOfScalar(u8, content_type, ';')) |idx| end = @min(end, idx);
    if (std.mem.indexOfScalar(u8, content_type, ' ')) |idx| end = @min(end, idx);
    return trimASCIIWhitespace(content_type[0..end]);
}

fn isTextHTMLContentType(content_type_raw: []const u8) bool {
    const token = mimeTypeToken(content_type_raw);
    return token.len > 0 and eqlIgnoreCase(token, "text/html");
}

fn isHTMLContentType(content_type_raw: []const u8) bool {
    const token = mimeTypeToken(content_type_raw);
    return token.len > 0 and (eqlIgnoreCase(token, "text/html") or eqlIgnoreCase(token, "application/xhtml+xml"));
}

fn pathFromTargetURI(uri: []const u8) []const u8 {
    if (uri.len == 0) return "/";
    var path = uri;
    if (std.mem.indexOf(u8, uri, "://")) |scheme_sep| {
        const after_scheme = scheme_sep + 3;
        path = if (std.mem.indexOfPos(u8, uri, after_scheme, "/")) |slash_pos| uri[slash_pos..] else "/";
    } else if (startsWithIgnoreCase(uri, "//")) {
        path = if (std.mem.indexOfPos(u8, uri, 2, "/")) |slash_pos| uri[slash_pos..] else "/";
    } else if (uri[0] != '/') {
        path = if (std.mem.indexOfScalar(u8, uri, '/')) |slash_pos| uri[slash_pos..] else "/";
    }
    var end = path.len;
    if (std.mem.indexOfScalar(u8, path, '?')) |idx| end = @min(end, idx);
    if (std.mem.indexOfScalar(u8, path, '#')) |idx| end = @min(end, idx);
    path = path[0..end];
    if (path.len == 0 or path[0] != '/') return "/";
    return path;
}

fn isTagBoundary(c: u8) bool {
    return c == '>' or c == '/' or c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn findTagEnd(body: []const u8, start: usize) ?usize {
    var i = start;
    var quote: u8 = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        if (c == '>') return i + 1;
    }
    return null;
}

fn findAttributeValue(tag: []const u8, attr_name: []const u8) ?[]const u8 {
    var i: usize = 1 + CONTENT_SIZE_TAG.len;
    while (i < tag.len) {
        i = skipASCIIWhitespaceIn(tag, i);
        if (i >= tag.len or tag[i] == '>' or tag[i] == '/') return null;

        const name_start = i;
        while (i < tag.len and tag[i] != '=' and !isTagBoundary(tag[i])) : (i += 1) {}
        const name = tag[name_start..i];
        const after_name = i;
        i = skipASCIIWhitespaceIn(tag, i);
        if (i >= tag.len or tag[i] != '=') {
            i = after_name;
            continue;
        }

        i += 1;
        i = skipASCIIWhitespaceIn(tag, i);
        if (i >= tag.len) return null;

        var value: []const u8 = "";
        if (tag[i] == '"' or tag[i] == '\'') {
            const quote = tag[i];
            i += 1;
            const value_start = i;
            while (i < tag.len and tag[i] != quote) : (i += 1) {}
            if (i >= tag.len) return null;
            value = tag[value_start..i];
            i += 1;
        } else {
            const value_start = i;
            while (i < tag.len and !isTagBoundary(tag[i])) : (i += 1) {}
            value = tag[value_start..i];
        }
        if (eqlIgnoreCase(name, attr_name)) return value;
    }
    return null;
}

fn findNextElement(body: []const u8, cursor: usize) ?Element {
    const open_prefix = "<" ++ CONTENT_SIZE_TAG;
    const start = indexOfIgnoreCase(body, open_prefix, cursor) orelse return null;
    const boundary = start + open_prefix.len;
    if (boundary >= body.len or !isTagBoundary(body[boundary])) {
        return findNextElement(body, boundary);
    }

    const open_end = findTagEnd(body, start) orelse @trap();
    const src = findAttributeValue(body[start..open_end], "src") orelse @trap();
    if (src.len == 0 or src[0] != '/') @trap();

    const close_prefix = "</" ++ CONTENT_SIZE_TAG;
    var close_start = indexOfIgnoreCase(body, close_prefix, open_end) orelse @trap();
    while (true) {
        const close_boundary = close_start + close_prefix.len;
        if (close_boundary < body.len and isTagBoundary(body[close_boundary])) break;
        close_start = indexOfIgnoreCase(body, close_prefix, close_boundary) orelse @trap();
    }
    const close_end = findTagEnd(body, close_start) orelse @trap();
    return .{
        .start = start,
        .open_end = open_end,
        .content_end = close_start,
        .end = close_end,
        .src = src,
    };
}

fn normalizedSourcePath(src: []const u8) []const u8 {
    var end = src.len;
    if (std.mem.indexOfScalar(u8, src, '?')) |idx| end = @min(end, idx);
    if (std.mem.indexOfScalar(u8, src, '#')) |idx| end = @min(end, idx);
    if (end == 0 or src[0] != '/') @trap();
    return src[0..end];
}

fn lookupBodySize(input: []const u8, src: []const u8) ?usize {
    const wanted = normalizedSourcePath(src);
    var cursor: usize = 0;
    while (cursor < input.len) {
        while (cursor < input.len and (input[cursor] == '\r' or input[cursor] == '\n')) : (cursor += 1) {}
        if (cursor >= input.len) break;
        const record = parseWARCRecord(input, cursor) orelse @trap();
        cursor = record.next;
        if (!eqlIgnoreCase(record.warc_type, "response")) continue;
        if (!std.mem.eql(u8, pathFromTargetURI(record.target_uri), wanted)) continue;
        const http = parseHTTPPayload(record.payload) orelse continue;
        if (http.status < 200 or http.status >= 300) return null;
        if (isHTMLContentType(http.content_type)) return null;
        return http.body.len;
    }
    return null;
}

fn sizeTextLen(byte_len: usize) usize {
    if (byte_len < 1000) {
        return digits10(byte_len) + if (byte_len == 1) " byte".len else " bytes".len;
    }
    const hundredths = (byte_len * 100 + 500) / 1000;
    return digits10(hundredths / 100) + ".00 kB".len;
}

fn writeSizeText(out: *Output, byte_len: usize) void {
    if (byte_len < 1000) {
        out.writeUnsigned(byte_len);
        out.writeSlice(if (byte_len == 1) " byte" else " bytes");
        return;
    }
    const hundredths = (byte_len * 100 + 500) / 1000;
    out.writeUnsigned(hundredths / 100);
    out.writeByte('.');
    out.writeByte('0' + @as(u8, @intCast((hundredths / 10) % 10)));
    out.writeByte('0' + @as(u8, @intCast(hundredths % 10)));
    out.writeSlice(" kB");
}

fn bodyLenWithContentSizes(input: []const u8, body: []const u8) usize {
    var len = body.len;
    var cursor: usize = 0;
    while (findNextElement(body, cursor)) |element| {
        const byte_len = lookupBodySize(input, element.src) orelse @trap();
        const replacement_len = sizeTextLen(byte_len);
        len = len - (element.content_end - element.open_end) + replacement_len;
        cursor = element.end;
    }
    return len;
}
fn digits10(value: usize) usize {
    var n = value;
    var digits: usize = 1;
    while (n >= 10) : (digits += 1) n /= 10;
    return digits;
}

fn computeHeaderRewriteLen(http: HTTPPayload, body_len: usize) usize {
    var len: usize = http.status_line.len + 2;
    var line_start: usize = 0;
    var line_index: usize = 0;
    while (line_start < http.header_block.len) : (line_index += 1) {
        const nl = std.mem.indexOfPos(u8, http.header_block, line_start, "\n") orelse http.header_block.len;
        var line = http.header_block[line_start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line_start = if (nl < http.header_block.len) nl + 1 else http.header_block.len;
        const trimmed = trimASCIIWhitespace(line);
        if (trimmed.len == 0) break;
        if (line_index == 0) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse {
            len += trimmed.len + 2;
            continue;
        };
        const key = trimASCIIWhitespace(trimmed[0..colon]);
        if (eqlIgnoreCase(key, "Content-Length")) continue;
        len += trimmed.len + 2;
    }
    len += "Content-Length: ".len + digits10(body_len) + 4;
    return len;
}

fn writeWARCRecordHeader(out: *Output, warc_type: []const u8, target_uri: []const u8, payload_len: usize) void {
    out.writeSlice("WARC/1.0\r\nWARC-Type: ");
    out.writeSlice(warc_type);
    out.writeSlice("\r\nWARC-Target-URI: ");
    out.writeSlice(target_uri);
    out.writeSlice("\r\nContent-Length: ");
    out.writeUnsigned(payload_len);
    out.writeSlice("\r\n\r\n");
}

fn writeHTTPHeaders(out: *Output, http: HTTPPayload, body_len: usize) void {
    out.writeSlice(http.status_line);
    out.writeSlice("\r\n");
    var line_start: usize = 0;
    var line_index: usize = 0;
    while (line_start < http.header_block.len) : (line_index += 1) {
        const nl = std.mem.indexOfPos(u8, http.header_block, line_start, "\n") orelse http.header_block.len;
        var line = http.header_block[line_start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line_start = if (nl < http.header_block.len) nl + 1 else http.header_block.len;
        const trimmed = trimASCIIWhitespace(line);
        if (trimmed.len == 0) break;
        if (line_index == 0) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse {
            out.writeSlice(trimmed);
            out.writeSlice("\r\n");
            continue;
        };
        const key = trimASCIIWhitespace(trimmed[0..colon]);
        if (eqlIgnoreCase(key, "Content-Length")) continue;
        out.writeSlice(trimmed);
        out.writeSlice("\r\n");
    }
    out.writeSlice("Content-Length: ");
    out.writeUnsigned(body_len);
    out.writeSlice("\r\n\r\n");
}

fn writeBodyWithContentSizes(input: []const u8, out: *Output, body: []const u8) void {
    var cursor: usize = 0;
    while (findNextElement(body, cursor)) |element| {
        out.writeSlice(body[cursor..element.open_end]);
        const byte_len = lookupBodySize(input, element.src) orelse @trap();
        writeSizeText(out, byte_len);
        out.writeSlice(body[element.content_end..element.end]);
        cursor = element.end;
    }
    out.writeSlice(body[cursor..]);
}

fn writeHTTPPayloadWithContentSizes(input: []const u8, out: *Output, http: HTTPPayload) void {
    const body_len = bodyLenWithContentSizes(input, http.body);
    writeHTTPHeaders(out, http, body_len);
    writeBodyWithContentSizes(input, out, http.body);
}

fn processWARC(input: []const u8, out: *Output) void {
    var cursor: usize = 0;
    while (cursor < input.len and !out.overflow) {
        while (cursor < input.len and (input[cursor] == '\r' or input[cursor] == '\n')) : (cursor += 1) {}
        if (cursor >= input.len) break;

        const record = parseWARCRecord(input, cursor) orelse @trap();
        cursor = record.next;

        var payload_to_write: ?HTTPPayload = null;
        var payload_len = record.payload.len;

        if (eqlIgnoreCase(record.warc_type, "response")) {
            if (parseHTTPPayload(record.payload)) |http| {
                if (isTextHTMLContentType(http.content_type)) {
                    if (findNextElement(http.body, 0) != null) {
                        const body_len = bodyLenWithContentSizes(input, http.body);
                        payload_len = computeHeaderRewriteLen(http, body_len) + body_len;
                        payload_to_write = http;
                    }
                }
            }
        }

        writeWARCRecordHeader(out, record.warc_type, record.target_uri, payload_len);
        if (payload_to_write) |http| {
            writeHTTPPayloadWithContentSizes(input, out, http);
        } else {
            out.writeSlice(record.payload);
        }
        out.writeSlice("\r\n\r\n");
    }
}

export fn render(input_size_u32: u32) u32 {
    const input_size: usize = @intCast(input_size_u32);
    if (input_size > INPUT_CAP) @trap();

    var out = Output{};
    processWARC(input_buf[0..input_size], &out);
    if (out.overflow) @trap();
    return @as(u32, @intCast(out.idx));
}

fn appendWARCRecord(out_buf: []u8, cursor: *usize, warc_type: []const u8, target_uri: []const u8, payload: []const u8) !void {
    const rec = try std.fmt.bufPrint(
        out_buf[cursor.*..],
        "WARC/1.0\r\nWARC-Type: {s}\r\nWARC-Target-URI: {s}\r\nContent-Length: {d}\r\n\r\n{s}\r\n\r\n",
        .{ warc_type, target_uri, payload.len, payload },
    );
    cursor.* += rec.len;
}

fn runTransform(input: []const u8, out: []u8) ![]const u8 {
    @memset(out, 0);
    @memcpy(input_buf[0..input.len], input);
    const n = render(@as(u32, @intCast(input.len)));
    if (n > out.len) return error.OutputTooSmall;
    @memcpy(out[0..n], output_buf[0..n]);
    return out[0..n];
}

test "renders byte and decimal kilobyte sizes from later WARC records" {
    var warc_buf: [32768]u8 = undefined;
    var n: usize = 0;
    const page =
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: 1\r\n\r\n" ++
        "<p><qip-content-size src=\"/tiny.bin\">stale</qip-content-size></p>" ++
        "<p><qip-content-size src=\"/large.wasm\"></qip-content-size></p>";
    try appendWARCRecord(warc_buf[0..], &n, "response", "http://qip.local/downloads", page);
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/tiny.bin",
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\r\nhello",
    );

    var large_body: [2301]u8 = undefined;
    @memset(&large_body, 'x');
    var large_payload_buf: [4096]u8 = undefined;
    const large_payload = try std.fmt.bufPrint(
        &large_payload_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: application/wasm\r\n\r\n{s}",
        .{large_body[0..]},
    );
    try appendWARCRecord(warc_buf[0..], &n, "response", "http://qip.local/large.wasm", large_payload);

    var out: [65536]u8 = undefined;
    const transformed = try runTransform(warc_buf[0..n], out[0..]);
    try std.testing.expect(std.mem.indexOf(
        u8,
        transformed,
        "<qip-content-size src=\"/tiny.bin\">5 bytes</qip-content-size>",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        transformed,
        "<qip-content-size src=\"/large.wasm\">2.30 kB</qip-content-size>",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, transformed, ">stale</qip-content-size>") == null);

    const page_record = parseWARCRecord(transformed, 0) orelse return error.InvalidWARC;
    const page_http = parseHTTPPayload(page_record.payload) orelse return error.InvalidHTTP;
    try std.testing.expectEqual(page_record.payload.len, page_http.header_block.len + page_http.body.len);
    try std.testing.expect(parseWARCRecord(transformed, page_record.next) != null);
}

test "normalizes query and fragment in src paths" {
    var warc_buf: [8192]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/page",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<qip-content-size src=\"/one?download=1#x\"></qip-content-size>",
    );
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/one",
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\r\nx",
    );

    var out: [16384]u8 = undefined;
    const transformed = try runTransform(warc_buf[0..n], out[0..]);
    try std.testing.expect(std.mem.indexOf(u8, transformed, ">1 byte</qip-content-size>") != null);
}

test "missing and unsuccessful source paths do not resolve" {
    var warc_buf: [4096]u8 = undefined;
    var n: usize = 0;
    try appendWARCRecord(
        warc_buf[0..],
        &n,
        "response",
        "http://qip.local/missing",
        "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\nno",
    );
    try std.testing.expectEqual(@as(?usize, null), lookupBodySize(warc_buf[0..n], "/absent"));
    try std.testing.expectEqual(@as(?usize, null), lookupBodySize(warc_buf[0..n], "/missing"));
}

test "leaves non HTML responses unchanged" {
    var warc_buf: [8192]u8 = undefined;
    var n: usize = 0;
    const payload =
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n" ++
        "<qip-content-size src=\"/missing\"></qip-content-size>";
    try appendWARCRecord(warc_buf[0..], &n, "response", "http://qip.local/plain", payload);

    var out: [16384]u8 = undefined;
    const transformed = try runTransform(warc_buf[0..n], out[0..]);
    try std.testing.expect(std.mem.indexOf(
        u8,
        transformed,
        "<qip-content-size src=\"/missing\"></qip-content-size>",
    ) != null);
}
