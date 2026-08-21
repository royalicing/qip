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

fn isAsciiWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0c;
}

export fn render(input_size: u32) u32 {
    const size: usize = @intCast(input_size);
    if (pending_commit_result != no_render) @trap();
    if (size > INPUT_CAP) @trap();

    pending_commit_result = invalid_input;
    if (size == 0) return 0;

    var i: usize = 0;
    while (i < size) : (i += 1) {
        if (isAsciiWhitespace(input_buf[i])) {
            pending_commit_result = invalid_input + @as(i64, @intCast(i));
            return 0;
        }
    }
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

test "accepted IDs remain in the input buffer" {
    const value = "main-content";
    @memcpy(input_buf[0..value.len], value);

    try std.testing.expectEqual(value.len, render(value.len));
    try std.testing.expectEqualStrings(value, input_buf[0..value.len]);
    try std.testing.expectEqual(@as(i64, 0), commit());
}

test "rejection reports the whitespace offset and the instance recovers" {
    const invalid = "main content";
    @memcpy(input_buf[0..invalid.len], invalid);

    try std.testing.expectEqual(@as(u32, 0), render(invalid.len));
    try std.testing.expectEqual(invalid_input + 4, commit());

    const valid = "main:content";
    @memcpy(input_buf[0..valid.len], valid);
    try std.testing.expectEqual(valid.len, render(valid.len));
    try std.testing.expectEqualStrings(valid, input_buf[0..valid.len]);
    try std.testing.expectEqual(@as(i64, 0), commit());
}
