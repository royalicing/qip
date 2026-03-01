const std = @import("std");

const INPUT_CAP: usize = 64 * 1024;
const OUTPUT_CAP: usize = 64 * 1024;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

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

fn endsWithIgnoreCase(s: []const u8, suffix: []const u8) bool {
    if (s.len < suffix.len) return false;
    return eqlIgnoreCase(s[s.len - suffix.len ..], suffix);
}

fn trimASCIIWhitespace(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn firstOf(s: []const u8, chars: []const u8) ?usize {
    for (s, 0..) |c, i| {
        if (std.mem.indexOfScalar(u8, chars, c) != null) return i;
    }
    return null;
}

fn trimHostPrefix(host: []const u8) []const u8 {
    var h = host;
    while (true) {
        if (startsWithIgnoreCase(h, "www.")) {
            h = h[4..];
            continue;
        }
        if (startsWithIgnoreCase(h, "m.")) {
            h = h[2..];
            continue;
        }
        if (startsWithIgnoreCase(h, "music.")) {
            h = h[6..];
            continue;
        }
        return h;
    }
}

fn isVideoIdChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
}

fn isValidVideoId(id: []const u8) bool {
    if (id.len != 11) return false;
    for (id) |c| {
        if (!isVideoIdChar(c)) return false;
    }
    return true;
}

fn sliceUntilDelim(s: []const u8) []const u8 {
    const end = firstOf(s, "/?#&") orelse s.len;
    return s[0..end];
}

fn parseHostAndRest(input: []const u8) ?struct { host: []const u8, rest: []const u8 } {
    var s = input;
    if (std.mem.indexOf(u8, s, "://")) |scheme_idx| {
        s = s[scheme_idx + 3 ..];
    }

    const host_end_rel = firstOf(s, "/?#") orelse s.len;
    if (host_end_rel == 0) return null;

    var host = s[0..host_end_rel];
    const rest = s[host_end_rel..];

    if (std.mem.indexOfScalar(u8, host, '@')) |at| {
        if (at + 1 >= host.len) return null;
        host = host[at + 1 ..];
    }
    if (std.mem.indexOfScalar(u8, host, ':')) |colon| {
        host = host[0..colon];
    }
    if (host.len == 0) return null;

    return .{ .host = trimHostPrefix(host), .rest = rest };
}

fn queryFromRest(rest: []const u8) []const u8 {
    const q_idx = std.mem.indexOfScalar(u8, rest, '?') orelse return "";
    const q_start = q_idx + 1;
    const q_end_rel = std.mem.indexOfScalarPos(u8, rest, q_start, '#') orelse rest.len;
    return rest[q_start..q_end_rel];
}

fn extractFromWatch(rest: []const u8) ?[]const u8 {
    const query = queryFromRest(rest);
    var start: usize = 0;
    while (start <= query.len) {
        const amp_rel = std.mem.indexOfScalarPos(u8, query, start, '&') orelse query.len;
        const part = query[start..amp_rel];
        if (part.len >= 2 and (part[0] == 'v' or part[0] == 'V') and part[1] == '=') {
            const value = sliceUntilDelim(part[2..]);
            if (isValidVideoId(value)) return value;
        }
        if (amp_rel == query.len) break;
        start = amp_rel + 1;
    }
    return null;
}

fn extractPathSegment(rest: []const u8, prefix: []const u8) ?[]const u8 {
    if (!startsWithIgnoreCase(rest, prefix)) return null;
    if (rest.len <= prefix.len) return null;
    const segment = sliceUntilDelim(rest[prefix.len..]);
    if (isValidVideoId(segment)) return segment;
    return null;
}

fn extractVideoId(input_raw: []const u8) ?[]const u8 {
    const input = trimASCIIWhitespace(input_raw);
    if (isValidVideoId(input)) return input;

    const parsed = parseHostAndRest(input) orelse return null;
    const host = parsed.host;
    const rest = parsed.rest;

    if (eqlIgnoreCase(host, "youtu.be")) {
        if (rest.len < 2 or rest[0] != '/') return null;
        const id = sliceUntilDelim(rest[1..]);
        if (isValidVideoId(id)) return id;
        return null;
    }

    const is_youtube = eqlIgnoreCase(host, "youtube.com") or endsWithIgnoreCase(host, ".youtube.com") or eqlIgnoreCase(host, "youtube-nocookie.com") or endsWithIgnoreCase(host, ".youtube-nocookie.com");
    if (!is_youtube) return null;

    if (startsWithIgnoreCase(rest, "/watch")) return extractFromWatch(rest);
    if (extractPathSegment(rest, "/embed/")) |id| return id;
    if (extractPathSegment(rest, "/shorts/")) |id| return id;
    if (extractPathSegment(rest, "/live/")) |id| return id;
    if (extractPathSegment(rest, "/v/")) |id| return id;

    return null;
}

export fn run(input_size_in: u32) u32 {
    const input_size = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    const id = extractVideoId(input_buf[0..input_size]) orelse return 0;
    @memcpy(output_buf[0..id.len], id);
    return @as(u32, @intCast(id.len));
}

test "extracts from watch URL" {
    const id = extractVideoId("https://www.youtube.com/watch?v=dQw4w9WgXcQ") orelse return error.NoId;
    try std.testing.expectEqualStrings("dQw4w9WgXcQ", id);
}

test "extracts from short URL" {
    const id = extractVideoId("https://youtu.be/dQw4w9WgXcQ?t=43") orelse return error.NoId;
    try std.testing.expectEqualStrings("dQw4w9WgXcQ", id);
}

test "extracts from embed URL" {
    const id = extractVideoId("https://www.youtube.com/embed/dQw4w9WgXcQ") orelse return error.NoId;
    try std.testing.expectEqualStrings("dQw4w9WgXcQ", id);
}

test "extracts from shorts URL" {
    const id = extractVideoId("https://m.youtube.com/shorts/dQw4w9WgXcQ?feature=share") orelse return error.NoId;
    try std.testing.expectEqualStrings("dQw4w9WgXcQ", id);
}

test "rejects invalid or unsupported inputs" {
    try std.testing.expect(extractVideoId("https://example.com/watch?v=dQw4w9WgXcQ") == null);
    try std.testing.expect(extractVideoId("https://www.youtube.com/watch?v=short") == null);
    try std.testing.expect(extractVideoId("not a youtube url") == null);
}
