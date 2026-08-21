// Accepts ASCII input unchanged and rejects the first byte above 0x7f.

const INPUT_CAP: usize = 1024 * 1024;
const NO_RENDER: i64 = 1;
const ERROR_BIT: u64 = 1 << 63;
const INVALID_INPUT_BIT: u64 = 1 << 62;

var input_buf: [INPUT_CAP]u8 = undefined;
var pending_commit_result: i64 = NO_RENDER;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

// Accepted output is the input itself. The host can keep using the bytes it
// wrote instead of copying them to a second component buffer.
export fn output_ptr() u32 {
    return input_ptr();
}

export fn output_utf8_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

fn invalidInput(offset: u32) i64 {
    return @bitCast(ERROR_BIT | INVALID_INPUT_BIT | @as(u64, offset));
}

export fn render(input_size: u32) u32 {
    if (pending_commit_result != NO_RENDER) @trap();
    if (input_size > INPUT_CAP) @trap();

    pending_commit_result = invalidInput(0);
    for (input_buf[0..input_size], 0..) |byte, offset| {
        if (byte > 0x7f) {
            pending_commit_result = invalidInput(@intCast(offset));
            return 0;
        }
    }

    pending_commit_result = 0;
    return input_size;
}

// commit never traps. A negative result rejects the provisional render. The
// low 32 bits contain the first invalid input offset when one is known.
export fn commit() i64 {
    const result = if (pending_commit_result == NO_RENDER)
        invalidInput(0)
    else
        pending_commit_result;
    pending_commit_result = NO_RENDER;
    return result;
}

test "accepts ASCII in place" {
    const input = "QIP 123\n";
    @memcpy(input_buf[0..input.len], input);
    try std.testing.expectEqual(@as(u32, input.len), render(input.len));
    try std.testing.expectEqual(@as(i64, 0), commit());
    try std.testing.expectEqualStrings("QIP 123\n", input_buf[0..input.len]);
}

test "rejects at the first non-ASCII byte and recovers" {
    const invalid = "A\xc3\xa9";
    @memcpy(input_buf[0..invalid.len], invalid);
    try std.testing.expectEqual(@as(u32, 0), render(invalid.len));
    const rejected: u64 = @bitCast(commit());
    try std.testing.expect(rejected >> 63 == 1);
    try std.testing.expect(rejected & INVALID_INPUT_BIT != 0);
    try std.testing.expectEqual(@as(u64, 1), rejected & 0xffff_ffff);

    input_buf[0] = 'A';
    try std.testing.expectEqual(@as(u32, 1), render(1));
    try std.testing.expectEqual(@as(i64, 0), commit());
    try std.testing.expectEqualStrings("A", input_buf[0..1]);
}

const std = @import("std");
