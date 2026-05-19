const std = @import("std");

const INPUT_CAP: usize = 128 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "application/warc";
const OUTPUT_CONTENT_TYPE = "application/warc";

const PATH_TABLE_CAP: usize = 65536;

var input_buf: [INPUT_CAP]u8 = undefined;

const PathEntry = struct {
    used: bool = false,
    path: []const u8 = "",
    status: u16 = 0,
};

var path_table: [PATH_TABLE_CAP]PathEntry = [_]PathEntry{.{}} ** PATH_TABLE_CAP;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_ptr() u32 {
    // Pass-through: successful validation returns the original input bytes.
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
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

const WARCRecord = struct {
    next: usize,
    warc_type: []const u8,
    target_uri: []const u8,
    payload: []const u8,
};

const HTTPMeta = struct {
    status: u16,
    content_type: []const u8,
    body: []const u8,
};

const ResolveResult = union(enum) {
    ignore,
    invalid,
    ok: []const u8,
};

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

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return eqlIgnoreCase(s[0..prefix.len], prefix);
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

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn isTagNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == ':';
}

fn isSchemeChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '+' or c == '-' or c == '.';
}

fn findHeaderEnd(buf: []const u8, start: usize) ?struct { end: usize, delim_len: usize } {
    if (start >= buf.len) return null;

    if (std.mem.indexOfPos(u8, buf, start, "\r\n\r\n")) |pos| {
        return .{ .end = pos + 4, .delim_len = 4 };
    }
    if (std.mem.indexOfPos(u8, buf, start, "\n\n")) |pos| {
        return .{ .end = pos + 2, .delim_len = 2 };
    }
    return null;
}

fn parseUnsigned10(s: []const u8) ?usize {
    if (s.len == 0) return null;
    var value: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        const digit = @as(usize, c - '0');
        value = value * 10 + digit;
    }
    return value;
}

fn parseStatusCode(line: []const u8) ?u16 {
    var i: usize = 0;
    while (i < line.len and line[i] != ' ') : (i += 1) {}
    if (i >= line.len) return null;
    while (i < line.len and line[i] == ' ') : (i += 1) {}
    const code_start = i;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    if (i == code_start) return null;
    const code = parseUnsigned10(line[code_start..i]) orelse return null;
    if (code > std.math.maxInt(u16)) return null;
    return @as(u16, @intCast(code));
}

fn parseWARCRecord(input: []const u8, start: usize) ?WARCRecord {
    const head = findHeaderEnd(input, start) orelse return null;
    const header_slice = input[start..head.end];
    var warc_type: []const u8 = "";
    var target_uri: []const u8 = "";
    var content_length: ?usize = null;

    var line_start: usize = 0;
    var line_index: usize = 0;
    while (line_start < header_slice.len) : (line_index += 1) {
        const nl_rel = std.mem.indexOfPos(u8, header_slice, line_start, "\n") orelse header_slice.len;
        var line = header_slice[line_start..nl_rel];
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }
        line = trimASCIIWhitespace(line);
        line_start = if (nl_rel < header_slice.len) nl_rel + 1 else header_slice.len;
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
    if (head.end + payload_len > input.len) return null;
    const payload = input[head.end .. head.end + payload_len];

    var next = head.end + payload_len;
    while (next < input.len and (input[next] == '\r' or input[next] == '\n')) : (next += 1) {}

    return .{
        .next = next,
        .warc_type = warc_type,
        .target_uri = target_uri,
        .payload = payload,
    };
}

fn parseHTTPMeta(payload: []const u8) ?HTTPMeta {
    const head = findHeaderEnd(payload, 0) orelse return null;
    const header_slice = payload[0..head.end];
    var status: ?u16 = null;
    var content_type: []const u8 = "";

    var line_start: usize = 0;
    var line_index: usize = 0;
    while (line_start < header_slice.len) : (line_index += 1) {
        const nl_rel = std.mem.indexOfPos(u8, header_slice, line_start, "\n") orelse header_slice.len;
        var line = header_slice[line_start..nl_rel];
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }
        line = trimASCIIWhitespace(line);
        line_start = if (nl_rel < header_slice.len) nl_rel + 1 else header_slice.len;
        if (line.len == 0) break;

        if (line_index == 0) {
            status = parseStatusCode(line);
            continue;
        }

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = trimASCIIWhitespace(line[0..colon]);
        const value = trimASCIIWhitespace(line[colon + 1 ..]);
        if (eqlIgnoreCase(key, "Content-Type")) {
            content_type = value;
        }
    }

    return .{
        .status = status orelse return null,
        .content_type = content_type,
        .body = payload[head.end..],
    };
}

fn mimeTypeToken(content_type_raw: []const u8) []const u8 {
    const content_type = trimASCIIWhitespace(content_type_raw);
    var end = content_type.len;
    if (std.mem.indexOfScalar(u8, content_type, ';')) |idx| end = @min(end, idx);
    if (std.mem.indexOfScalar(u8, content_type, ' ')) |idx| end = @min(end, idx);
    return trimASCIIWhitespace(content_type[0..end]);
}

fn isHTMLContentType(content_type_raw: []const u8) bool {
    const content_type = mimeTypeToken(content_type_raw);
    if (content_type.len == 0) return false;
    return eqlIgnoreCase(content_type, "text/html") or eqlIgnoreCase(content_type, "application/xhtml+xml");
}

fn pathFromTargetURI(uri: []const u8) []const u8 {
    if (uri.len == 0) return "/";

    var path = uri;
    if (std.mem.indexOf(u8, uri, "://")) |scheme_sep| {
        const after_scheme = scheme_sep + 3;
        if (std.mem.indexOfPos(u8, uri, after_scheme, "/")) |slash_pos| {
            path = uri[slash_pos..];
        } else {
            path = "/";
        }
    } else if (std.mem.startsWith(u8, uri, "//")) {
        if (std.mem.indexOfPos(u8, uri, 2, "/")) |slash_pos| {
            path = uri[slash_pos..];
        } else {
            path = "/";
        }
    } else if (uri[0] != '/') {
        if (std.mem.indexOfScalar(u8, uri, '/')) |slash_pos| {
            path = uri[slash_pos..];
        } else {
            path = "/";
        }
    }

    var end = path.len;
    if (std.mem.indexOfScalar(u8, path, '?')) |pos| end = @min(end, pos);
    if (std.mem.indexOfScalar(u8, path, '#')) |pos| end = @min(end, pos);
    path = path[0..end];
    if (path.len == 0) return "/";
    if (path[0] != '/') return "/";
    return path;
}

fn authorityFromTargetURI(uri: []const u8) []const u8 {
    var rest = uri;
    if (startsWithIgnoreCase(uri, "http://")) {
        rest = uri["http://".len..];
    } else if (startsWithIgnoreCase(uri, "https://")) {
        rest = uri["https://".len..];
    } else if (std.mem.startsWith(u8, uri, "//")) {
        rest = uri[2..];
    } else {
        return "";
    }

    var end = rest.len;
    if (std.mem.indexOfScalar(u8, rest, '/')) |idx| end = @min(end, idx);
    if (std.mem.indexOfScalar(u8, rest, '?')) |idx| end = @min(end, idx);
    if (std.mem.indexOfScalar(u8, rest, '#')) |idx| end = @min(end, idx);
    return rest[0..end];
}

fn schemeSeparatorIndex(raw: []const u8) ?usize {
    if (raw.len == 0) return null;
    if (!((raw[0] >= 'a' and raw[0] <= 'z') or (raw[0] >= 'A' and raw[0] <= 'Z'))) return null;
    var i: usize = 1;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == ':') return i;
        if (c == '/' or c == '?' or c == '#') return null;
        if (!isSchemeChar(c)) return null;
    }
    return null;
}

fn canonicalizePath(path_raw: []const u8, out_buf: []u8) ?[]const u8 {
    if (path_raw.len == 0 or path_raw[0] != '/') return null;
    if (out_buf.len == 0) return null;

    out_buf[0] = '/';
    var out_len: usize = 1;
    var i: usize = 1;
    while (true) {
        while (i < path_raw.len and path_raw[i] == '/') : (i += 1) {}
        if (i >= path_raw.len) break;

        const seg_start = i;
        while (i < path_raw.len and path_raw[i] != '/') : (i += 1) {}
        const seg = path_raw[seg_start..i];
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (out_len > 1) {
                out_len -= 1;
                while (out_len > 0 and out_buf[out_len - 1] != '/') : (out_len -= 1) {}
            }
            continue;
        }

        if (out_len > 1 and out_buf[out_len - 1] != '/') {
            if (out_len >= out_buf.len) return null;
            out_buf[out_len] = '/';
            out_len += 1;
        }
        if (out_len + seg.len > out_buf.len) return null;
        @memcpy(out_buf[out_len .. out_len + seg.len], seg);
        out_len += seg.len;
    }

    if (out_len == 0) return null;
    return out_buf[0..out_len];
}

fn dirnameForPath(path: []const u8) []const u8 {
    if (path.len == 0 or path[0] != '/') return "/";
    if (std.mem.eql(u8, path, "/")) return "/";
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "/";
    if (slash == 0) return "/";
    return path[0 .. slash + 1];
}

fn cutPathPart(raw: []const u8) []const u8 {
    var end = raw.len;
    if (std.mem.indexOfScalar(u8, raw, '?')) |idx| end = @min(end, idx);
    if (std.mem.indexOfScalar(u8, raw, '#')) |idx| end = @min(end, idx);
    return raw[0..end];
}

fn resolveInternalLinkPath(source_path: []const u8, href_raw: []const u8, internal_host: []const u8, join_buf: []u8, canonical_buf: []u8) ResolveResult {
    const href = trimASCIIWhitespace(href_raw);
    if (href.len == 0) return .ignore;
    if (href[0] == '#') return .ignore;

    var reference = href;
    var empty_path_base = source_path;
    if (std.mem.startsWith(u8, href, "//")) {
        if (internal_host.len == 0) return .invalid;
        const no_slashes = href[2..];
        var host_end = no_slashes.len;
        if (std.mem.indexOfScalar(u8, no_slashes, '/')) |idx| host_end = @min(host_end, idx);
        if (std.mem.indexOfScalar(u8, no_slashes, '?')) |idx| host_end = @min(host_end, idx);
        if (std.mem.indexOfScalar(u8, no_slashes, '#')) |idx| host_end = @min(host_end, idx);
        const host = no_slashes[0..host_end];
        if (host.len == 0) return .invalid;
        if (!eqlIgnoreCase(host, internal_host)) return .ignore;
        if (host_end == no_slashes.len) {
            reference = "/";
        } else {
            reference = no_slashes[host_end..];
        }
        empty_path_base = "/";
    } else if (schemeSeparatorIndex(href)) |sep| {
        const scheme = href[0..sep];
        if (!eqlIgnoreCase(scheme, "http") and !eqlIgnoreCase(scheme, "https")) return .ignore;
        if (internal_host.len == 0) return .invalid;

        const after_scheme = href[sep + 1 ..];
        if (!std.mem.startsWith(u8, after_scheme, "//")) return .invalid;
        const no_slashes = after_scheme[2..];
        var host_end = no_slashes.len;
        if (std.mem.indexOfScalar(u8, no_slashes, '/')) |idx| host_end = @min(host_end, idx);
        if (std.mem.indexOfScalar(u8, no_slashes, '?')) |idx| host_end = @min(host_end, idx);
        if (std.mem.indexOfScalar(u8, no_slashes, '#')) |idx| host_end = @min(host_end, idx);
        const host = no_slashes[0..host_end];
        if (host.len == 0) return .invalid;
        if (!eqlIgnoreCase(host, internal_host)) return .ignore;
        if (host_end == no_slashes.len) {
            reference = "/";
        } else {
            reference = no_slashes[host_end..];
        }
        empty_path_base = "/";
    }

    var path_part = cutPathPart(reference);
    if (path_part.len == 0) {
        path_part = empty_path_base;
    }

    var candidate_path = path_part;
    if (path_part[0] != '/') {
        const base_dir = dirnameForPath(source_path);
        if (base_dir.len + path_part.len > join_buf.len) return .invalid;
        @memcpy(join_buf[0..base_dir.len], base_dir);
        @memcpy(join_buf[base_dir.len .. base_dir.len + path_part.len], path_part);
        candidate_path = join_buf[0 .. base_dir.len + path_part.len];
    }

    const canonical = canonicalizePath(candidate_path, canonical_buf) orelse return .invalid;
    return .{ .ok = canonical };
}

fn pathHash(path: []const u8) u64 {
    var h: u64 = 14695981039346656037;
    for (path) |b| {
        h ^= b;
        h *%= 1099511628211;
    }
    return h;
}

fn clearPathTable() void {
    for (&path_table) |*entry| {
        entry.* = .{};
    }
}

fn pathTableInsert(path: []const u8, status: u16) bool {
    if (path.len == 0) return false;
    var idx: usize = @as(usize, @intCast(pathHash(path) % PATH_TABLE_CAP));
    var probes: usize = 0;
    while (probes < PATH_TABLE_CAP) : (probes += 1) {
        const entry = &path_table[idx];
        if (!entry.used) {
            entry.used = true;
            entry.path = path;
            entry.status = status;
            return true;
        }
        if (std.mem.eql(u8, entry.path, path)) {
            entry.status = status;
            return true;
        }
        idx = (idx + 1) % PATH_TABLE_CAP;
    }
    return false;
}

fn pathTableLookup(path: []const u8) ?u16 {
    if (path.len == 0) return null;
    var idx: usize = @as(usize, @intCast(pathHash(path) % PATH_TABLE_CAP));
    var probes: usize = 0;
    while (probes < PATH_TABLE_CAP) : (probes += 1) {
        const entry = path_table[idx];
        if (!entry.used) return null;
        if (std.mem.eql(u8, entry.path, path)) return entry.status;
        idx = (idx + 1) % PATH_TABLE_CAP;
    }
    return null;
}

fn indexOfCloseTagIgnoreCase(body: []const u8, start: usize, tag_name: []const u8) ?usize {
    if (start >= body.len) return null;
    var i = start;
    while (i + 2 + tag_name.len <= body.len) : (i += 1) {
        if (body[i] != '<') continue;
        if (i + 1 >= body.len or body[i + 1] != '/') continue;
        if (i + 2 + tag_name.len > body.len) continue;
        if (!eqlIgnoreCase(body[i + 2 .. i + 2 + tag_name.len], tag_name)) continue;
        return i;
    }
    return null;
}

fn checkLink(source_path: []const u8, href: []const u8, internal_host: []const u8, join_buf: []u8, canonical_buf: []u8, checked_links: *usize, broken_links: *usize) void {
    const resolved = resolveInternalLinkPath(source_path, href, internal_host, join_buf, canonical_buf);
    switch (resolved) {
        .ignore => return,
        .invalid => {
            checked_links.* += 1;
            broken_links.* += 1;
        },
        .ok => |target| {
            checked_links.* += 1;
            const status = pathTableLookup(target) orelse {
                broken_links.* += 1;
                return;
            };
            if (status >= 400) {
                broken_links.* += 1;
            }
        },
    }
}

fn processSrcSet(source_path: []const u8, value: []const u8, internal_host: []const u8, join_buf: []u8, canonical_buf: []u8, checked_links: *usize, broken_links: *usize) void {
    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and (isSpace(value[i]) or value[i] == ',')) : (i += 1) {}
        if (i >= value.len) break;
        const item_start = i;
        while (i < value.len and value[i] != ',') : (i += 1) {}
        const item_raw = trimASCIIWhitespace(value[item_start..i]);
        if (item_raw.len == 0) continue;
        var url_end = item_raw.len;
        var j: usize = 0;
        while (j < item_raw.len) : (j += 1) {
            if (isSpace(item_raw[j])) {
                url_end = j;
                break;
            }
        }
        const url = item_raw[0..url_end];
        checkLink(source_path, url, internal_host, join_buf, canonical_buf, checked_links, broken_links);
    }
}

fn processTagLinkAttr(tag: []const u8, attr: []const u8, value: []const u8, source_path: []const u8, internal_host: []const u8, join_buf: []u8, canonical_buf: []u8, checked_links: *usize, broken_links: *usize) void {
    if (value.len == 0) return;
    if (eqlIgnoreCase(attr, "href")) {
        if (eqlIgnoreCase(tag, "a") or eqlIgnoreCase(tag, "area") or eqlIgnoreCase(tag, "link")) {
            checkLink(source_path, value, internal_host, join_buf, canonical_buf, checked_links, broken_links);
        }
        return;
    }
    if (eqlIgnoreCase(attr, "src")) {
        if (eqlIgnoreCase(tag, "img") or eqlIgnoreCase(tag, "script") or eqlIgnoreCase(tag, "iframe") or eqlIgnoreCase(tag, "source") or eqlIgnoreCase(tag, "audio") or eqlIgnoreCase(tag, "video") or eqlIgnoreCase(tag, "track") or eqlIgnoreCase(tag, "embed")) {
            checkLink(source_path, value, internal_host, join_buf, canonical_buf, checked_links, broken_links);
        }
        return;
    }
    if (eqlIgnoreCase(attr, "action")) {
        if (eqlIgnoreCase(tag, "form")) {
            checkLink(source_path, value, internal_host, join_buf, canonical_buf, checked_links, broken_links);
        }
        return;
    }
    if (eqlIgnoreCase(attr, "data")) {
        if (eqlIgnoreCase(tag, "object")) {
            checkLink(source_path, value, internal_host, join_buf, canonical_buf, checked_links, broken_links);
        }
        return;
    }
    if (eqlIgnoreCase(attr, "srcset")) {
        if (eqlIgnoreCase(tag, "img") or eqlIgnoreCase(tag, "source")) {
            processSrcSet(source_path, value, internal_host, join_buf, canonical_buf, checked_links, broken_links);
        }
    }
}

fn parseHTMLLinks(source_path: []const u8, html: []const u8, internal_host: []const u8, checked_links: *usize, broken_links: *usize) void {
    var join_buf: [4096]u8 = undefined;
    var canonical_buf: [4096]u8 = undefined;

    var i: usize = 0;
    while (i < html.len) {
        if (html[i] != '<') {
            i += 1;
            continue;
        }

        if (std.mem.startsWith(u8, html[i..], "<!--")) {
            if (std.mem.indexOfPos(u8, html, i + 4, "-->")) |end| {
                i = end + 3;
            } else {
                return;
            }
            continue;
        }

        var j = i + 1;
        if (j >= html.len) break;
        if (html[j] == '/' or html[j] == '!' or html[j] == '?') {
            if (std.mem.indexOfPos(u8, html, j, ">")) |end| {
                i = end + 1;
            } else {
                break;
            }
            continue;
        }

        const tag_start = j;
        while (j < html.len and isTagNameChar(html[j])) : (j += 1) {}
        if (j == tag_start) {
            i += 1;
            continue;
        }
        const tag = html[tag_start..j];
        const is_raw_text = eqlIgnoreCase(tag, "script") or eqlIgnoreCase(tag, "style");
        var is_self_closing = false;

        while (j < html.len) {
            while (j < html.len and isSpace(html[j])) : (j += 1) {}
            if (j >= html.len) break;
            if (html[j] == '>') {
                j += 1;
                break;
            }
            if (html[j] == '/') {
                is_self_closing = true;
                j += 1;
                continue;
            }

            const attr_start = j;
            while (j < html.len and isTagNameChar(html[j])) : (j += 1) {}
            if (j == attr_start) {
                j += 1;
                continue;
            }
            const attr = html[attr_start..j];

            while (j < html.len and isSpace(html[j])) : (j += 1) {}
            var value: []const u8 = "";
            if (j < html.len and html[j] == '=') {
                j += 1;
                while (j < html.len and isSpace(html[j])) : (j += 1) {}
                if (j < html.len and (html[j] == '"' or html[j] == '\'')) {
                    const quote = html[j];
                    j += 1;
                    const value_start = j;
                    while (j < html.len and html[j] != quote) : (j += 1) {}
                    value = html[value_start..@min(j, html.len)];
                    if (j < html.len and html[j] == quote) j += 1;
                } else {
                    const value_start = j;
                    while (j < html.len and !isSpace(html[j]) and html[j] != '>') : (j += 1) {}
                    value = html[value_start..j];
                }
            }

            processTagLinkAttr(tag, attr, value, source_path, internal_host, join_buf[0..], canonical_buf[0..], checked_links, broken_links);
        }

        i = j;
        if (is_raw_text and !is_self_closing) {
            if (indexOfCloseTagIgnoreCase(html, i, tag)) |close_start| {
                if (std.mem.indexOfPos(u8, html, close_start, ">")) |close_end| {
                    i = close_end + 1;
                } else {
                    return;
                }
            } else {
                return;
            }
        }
    }
}

const ValidationSummary = struct {
    checked_links: usize,
    broken_links: usize,
    page_count: usize,
};

fn validateInternalLinks(input: []const u8) ValidationSummary {
    clearPathTable();

    var internal_host: []const u8 = "";
    var cursor: usize = 0;

    while (cursor < input.len) {
        while (cursor < input.len and (input[cursor] == '\r' or input[cursor] == '\n')) : (cursor += 1) {}
        if (cursor >= input.len) break;

        const rec = parseWARCRecord(input, cursor) orelse @trap();
        cursor = rec.next;
        if (!eqlIgnoreCase(rec.warc_type, "response")) continue;
        const http = parseHTTPMeta(rec.payload) orelse continue;
        const target_path = pathFromTargetURI(rec.target_uri);
        if (!pathTableInsert(target_path, http.status)) @trap();
        if (internal_host.len == 0) {
            internal_host = authorityFromTargetURI(rec.target_uri);
        }
    }

    var checked_links: usize = 0;
    var broken_links: usize = 0;
    var page_count: usize = 0;

    cursor = 0;
    while (cursor < input.len) {
        while (cursor < input.len and (input[cursor] == '\r' or input[cursor] == '\n')) : (cursor += 1) {}
        if (cursor >= input.len) break;

        const rec = parseWARCRecord(input, cursor) orelse @trap();
        cursor = rec.next;
        if (!eqlIgnoreCase(rec.warc_type, "response")) continue;
        const http = parseHTTPMeta(rec.payload) orelse continue;
        if (http.status != 200) continue;
        if (!isHTMLContentType(http.content_type)) continue;

        page_count += 1;
        var source_path_buf: [4096]u8 = undefined;
        const source_path = canonicalizePath(pathFromTargetURI(rec.target_uri), source_path_buf[0..]) orelse pathFromTargetURI(rec.target_uri);
        parseHTMLLinks(source_path, http.body, internal_host, &checked_links, &broken_links);
    }

    return .{
        .checked_links = checked_links,
        .broken_links = broken_links,
        .page_count = page_count,
    };
}

export fn render(input_size_u32: u32) u32 {
    const input_size: usize = @intCast(input_size_u32);
    if (input_size > INPUT_CAP) @trap();

    const input = input_buf[0..input_size];
    const summary = validateInternalLinks(input);
    if (summary.broken_links != 0) @trap();
    return input_size_u32;
}

fn appendWARCRecord(
    out_buf: []u8,
    cursor: *usize,
    warc_type: []const u8,
    target_uri: []const u8,
    payload: []const u8,
) !void {
    const rec = try std.fmt.bufPrint(
        out_buf[cursor.*..],
        "WARC/1.0\r\nWARC-Type: {s}\r\nWARC-Target-URI: {s}\r\nContent-Length: {d}\r\n\r\n{s}\r\n\r\n",
        .{ warc_type, target_uri, payload.len, payload },
    );
    cursor.* += rec.len;
}

test "all internal links resolve" {
    var build_buf: [8192]u8 = undefined;
    var n: usize = 0;

    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "http://qip.local/",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<a href=\"/about\">About</a><link rel=\"icon\" href=\"/favicon.ico\"><img src=\"/img/logo.png\"><a href=\"/docs/\">Docs</a><a href=\"https://example.com/\">External</a>",
    );
    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "http://qip.local/about",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<p>About</p>",
    );
    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "http://qip.local/docs",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<p>Docs</p>",
    );
    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "http://qip.local/favicon.ico",
        "HTTP/1.1 200 OK\r\nContent-Type: image/x-icon\r\n\r\nico",
    );
    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "http://qip.local/img/logo.png",
        "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\npng",
    );

    @memcpy(input_buf[0..n], build_buf[0..n]);
    const out_len = render(@as(u32, @intCast(n)));
    try std.testing.expectEqual(@as(u32, @intCast(n)), out_len);
    try std.testing.expectEqualSlices(u8, build_buf[0..n], input_buf[0..@as(usize, @intCast(out_len))]);
}

test "detects broken internal links" {
    var build_buf: [8192]u8 = undefined;
    var n: usize = 0;

    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "http://qip.local/",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<a href=\"/missing\">Missing</a><a href=\"/docs/\">Docs</a><a href=\"?v=1\">Self</a><img src=\"img/logo.png\"><a href=\"mailto:test@example.com\">Mail</a>",
    );
    try appendWARCRecord(
        build_buf[0..],
        &n,
        "response",
        "http://qip.local/docs",
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<p>Docs</p>",
    );

    const summary = validateInternalLinks(build_buf[0..n]);
    try std.testing.expectEqual(@as(usize, 4), summary.checked_links);
    try std.testing.expectEqual(@as(usize, 2), summary.broken_links);
    try std.testing.expectEqual(@as(usize, 2), summary.page_count);
}
