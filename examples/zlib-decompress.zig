const std = @import("std");

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = 16 * 1024 * 1024;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

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

export fn run(input_size_in: u32) u32 {
    const input_size: usize = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);

    var in: std.Io.Reader = .fixed(input_buf[0..input_size]);
    var decompress: std.compress.flate.Decompress = .init(&in, .zlib, &.{});
    var out_writer: std.Io.Writer = .fixed(output_buf[0..OUTPUT_CAP]);

    const out_len = decompress.reader.streamRemaining(&out_writer) catch return 0;

    // Reject trailing bytes so callers get strict one-stream semantics.
    var trailing: [1]u8 = undefined;
    if ((in.readSliceShort(&trailing) catch return 0) != 0) return 0;

    return @as(u32, @intCast(out_len));
}

test "decompresses valid zlib bytes" {
    const compressed = [_]u8{
        0x78,
        0x9c,
        0x01,
        0x0c,
        0x00,
        0xf3,
        0xff,
        'H',
        'e',
        'l',
        'l',
        'o',
        ' ',
        'w',
        'o',
        'r',
        'l',
        'd',
        '\n',
        0x1c,
        0xf2,
        0x04,
        0x47,
    };

    @memcpy(input_buf[0..compressed.len], &compressed);
    const written = run(@intCast(compressed.len));

    try std.testing.expectEqual(@as(u32, 12), written);
    try std.testing.expectEqualStrings("Hello world\n", output_buf[0..written]);
}

test "rejects trailing bytes" {
    const compressed_with_trailing = [_]u8{
        0x78,
        0x9c,
        0x03,
        0x00,
        0x00,
        0x00,
        0x00,
        0x01,
        0x00,
    };

    @memcpy(input_buf[0..compressed_with_trailing.len], &compressed_with_trailing);
    try std.testing.expectEqual(@as(u32, 0), run(@intCast(compressed_with_trailing.len)));
}

test "rejects invalid header" {
    const bad = [_]u8{ 0x78, 0x00, 0x00 };
    @memcpy(input_buf[0..bad.len], &bad);
    try std.testing.expectEqual(@as(u32, 0), run(@intCast(bad.len)));
}
