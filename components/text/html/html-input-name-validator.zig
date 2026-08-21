const std = @import("std");

const INPUT_CAP: usize = 64 * 1024;
const OUTPUT_CAP: usize = 64 * 1024;

const no_render: i64 = 1;
const invalid_input: i64 = -0x4000000000000000;

var input_buf: [INPUT_CAP]u8 = undefined;
var pending_commit_result: i64 = no_render;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

fn continuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn utf8Length(bytes: []const u8, i: usize) ?usize {
    const first = bytes[i];
    if (first <= 0x7f) return 1;
    if (first >= 0xc2 and first <= 0xdf and i + 1 < bytes.len and continuation(bytes[i + 1])) return 2;
    if (first == 0xe0 and i + 2 < bytes.len and bytes[i + 1] >= 0xa0 and bytes[i + 1] <= 0xbf and continuation(bytes[i + 2])) return 3;
    if (first >= 0xe1 and first <= 0xec and i + 2 < bytes.len and continuation(bytes[i + 1]) and continuation(bytes[i + 2])) return 3;
    if (first == 0xed and i + 2 < bytes.len and bytes[i + 1] >= 0x80 and bytes[i + 1] <= 0x9f and continuation(bytes[i + 2])) return 3;
    if (first >= 0xee and first <= 0xef and i + 2 < bytes.len and continuation(bytes[i + 1]) and continuation(bytes[i + 2])) return 3;
    if (first == 0xf0 and i + 3 < bytes.len and bytes[i + 1] >= 0x90 and bytes[i + 1] <= 0xbf and continuation(bytes[i + 2]) and continuation(bytes[i + 3])) return 4;
    if (first >= 0xf1 and first <= 0xf3 and i + 3 < bytes.len and continuation(bytes[i + 1]) and continuation(bytes[i + 2]) and continuation(bytes[i + 3])) return 4;
    if (first == 0xf4 and i + 3 < bytes.len and bytes[i + 1] >= 0x80 and bytes[i + 1] <= 0x8f and continuation(bytes[i + 2]) and continuation(bytes[i + 3])) return 4;
    return null;
}

export fn render(input_size: u32) u32 {
    const size: usize = @intCast(input_size);
    if (pending_commit_result != no_render) @trap();
    if (size > INPUT_CAP) @trap();
    const input = input_buf[0..size];

    pending_commit_result = invalid_input;
    if (size == 0) return 0;

    var i: usize = 0;
    var steps: usize = 0;
    while (i < input.len and steps < INPUT_CAP) : (steps += 1) {
        if (input[i] == 0) {
            pending_commit_result = invalid_input + @as(i64, @intCast(i));
            return 0;
        }
        i += utf8Length(input, i) orelse @trap();
    }
    if (i != input.len) @trap();
    pending_commit_result = 0;
    return @intCast(size);
}

/// Close the render transaction. This function does not trap.
export fn commit() i64 {
    const result = if (pending_commit_result == no_render)
        invalid_input
    else
        pending_commit_result;
    pending_commit_result = no_render;
    return result;
}

test "accepted names remain in the input buffer" {
    const value = "items[0].名前 😀";
    @memcpy(input_buf[0..value.len], value);

    try std.testing.expectEqual(value.len, render(value.len));
    try std.testing.expectEqualStrings(value, input_buf[0..value.len]);
    try std.testing.expectEqual(@as(i64, 0), commit());
}

test "NUL rejects with an offset and the instance recovers" {
    const invalid = "item\x00name";
    @memcpy(input_buf[0..invalid.len], invalid);

    try std.testing.expectEqual(@as(u32, 0), render(invalid.len));
    try std.testing.expectEqual(invalid_input + 4, commit());

    const valid = "email";
    @memcpy(input_buf[0..valid.len], valid);
    try std.testing.expectEqual(valid.len, render(valid.len));
    try std.testing.expectEqualStrings(valid, input_buf[0..valid.len]);
    try std.testing.expectEqual(@as(i64, 0), commit());
}
