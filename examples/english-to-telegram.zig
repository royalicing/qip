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

fn pushByte(out: []u8, idx: *usize, ch: u8) bool {
    if (idx.* >= out.len) return false;
    out[idx.*] = ch;
    idx.* += 1;
    return true;
}

fn pushSlice(out: []u8, idx: *usize, s: []const u8) bool {
    if (idx.* + s.len > out.len) return false;
    @memcpy(out[idx.* .. idx.* + s.len], s);
    idx.* += s.len;
    return true;
}

fn emitToken(out: []u8, idx: *usize, need_space: *bool, token: []const u8) bool {
    if (need_space.*) {
        if (!pushByte(out, idx, ' ')) return false;
    }
    if (!pushSlice(out, idx, token)) return false;
    need_space.* = true;
    return true;
}

fn telegramify(input: []const u8, out: []u8) ?usize {
    var i: usize = 0;
    var idx: usize = 0;
    var need_space = false;

    while (i < input.len) {
        const ch = input[i];

        if (std.ascii.isAlphanumeric(ch)) {
            if (need_space) {
                if (!pushByte(out, &idx, ' ')) return null;
            }
            while (i < input.len and std.ascii.isAlphanumeric(input[i])) : (i += 1) {
                if (!pushByte(out, &idx, std.ascii.toUpper(input[i]))) return null;
            }
            need_space = true;
            continue;
        }

        if (ch == ',') {
            if (!emitToken(out, &idx, &need_space, "COMMA")) return null;
        } else if (ch == '.' or ch == '!' or ch == '?' or ch == ';' or ch == ':') {
            if (!emitToken(out, &idx, &need_space, "STOP")) return null;
        }

        i += 1;
    }

    return idx;
}

export fn run(input_size_in: u32) u32 {
    const input_size: usize = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    const written = telegramify(input_buf[0..input_size], output_buf[0..]) orelse return 0;
    return @as(u32, @intCast(written));
}

fn runString(input: []const u8, out: []u8) !usize {
    @memcpy(input_buf[0..input.len], input);
    const written = run(@as(u32, @intCast(input.len)));
    if (written == 0 and input.len != 0) return error.OutputTooSmall;
    @memcpy(out[0..written], output_buf[0..written]);
    return @as(usize, @intCast(written));
}

test "converts punctuation to telegram tokens" {
    var out: [256]u8 = undefined;
    const written = try runString("Meet me at noon, please.", out[0..]);
    try std.testing.expectEqualStrings("MEET ME AT NOON COMMA PLEASE STOP", out[0..written]);
}

test "normalizes separators and uppercase" {
    var out: [256]u8 = undefined;
    const written = try runString("ready\nset\tgo!", out[0..]);
    try std.testing.expectEqualStrings("READY SET GO STOP", out[0..written]);
}
