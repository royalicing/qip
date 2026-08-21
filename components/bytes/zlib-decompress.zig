//! zlib decompression using the shared engine in lib/inflate.zig, which
//! validates the header FCHECK/FDICT bits, Huffman tree shapes, and the
//! Adler-32 trailer, and rejects trailing bytes for strict one-stream
//! semantics.

const std = @import("std");
const inflate = @import("lib/inflate.zig");

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = 16 * 1024 * 1024;
const NO_RENDER: i64 = 1;
const ERROR_BIT: u64 = 1 << 63;

// TODO(content-commit): distinguish malformed input from output exhaustion and
// report useful input progress when the inflater exposes it.

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var pending_commit_result: i64 = NO_RENDER;

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

export fn render(input_size_in: u32) u32 {
    if (pending_commit_result != NO_RENDER) @trap();
    if (input_size_in > INPUT_CAP) @trap();

    pending_commit_result = @bitCast(ERROR_BIT);
    const input_size: usize = @intCast(input_size_in);
    const out_len = inflate.inflateZlib(input_buf[0..input_size], &output_buf) orelse return 0;
    pending_commit_result = 0;
    return @as(u32, @intCast(out_len));
}

// commit never traps. The generic negative result currently covers both an
// invalid zlib stream and output exhaustion.
export fn commit() i64 {
    const result = if (pending_commit_result == NO_RENDER)
        @as(i64, @bitCast(ERROR_BIT))
    else
        pending_commit_result;
    pending_commit_result = NO_RENDER;
    return result;
}

test "decompresses valid zlib bytes" {
    const compressed = [_]u8{
        0x78, 0x9c, 0x01, 0x0c, 0x00, 0xf3, 0xff,
        'H',  'e',  'l',  'l',  'o',  ' ',  'w',
        'o',  'r',  'l',  'd',  '\n',
        0x1c, 0xf2, 0x04, 0x47,
    };

    @memcpy(input_buf[0..compressed.len], &compressed);
    const written = render(@intCast(compressed.len));

    try std.testing.expectEqual(@as(u32, 12), written);
    try std.testing.expectEqual(@as(i64, 0), commit());
    try std.testing.expectEqualStrings("Hello world\n", output_buf[0..written]);
}

test "accepts a valid empty stream" {
    const compressed = [_]u8{ 0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01 };
    @memcpy(input_buf[0..compressed.len], &compressed);
    try std.testing.expectEqual(@as(u32, 0), render(compressed.len));
    try std.testing.expectEqual(@as(i64, 0), commit());
}

test "rejects trailing bytes" {
    const compressed_with_trailing = [_]u8{
        0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    };

    @memcpy(input_buf[0..compressed_with_trailing.len], &compressed_with_trailing);
    try std.testing.expectEqual(@as(u32, 0), render(@intCast(compressed_with_trailing.len)));
    try std.testing.expect(commit() < 0);
}

test "rejects invalid header and recovers" {
    const bad = [_]u8{ 0x78, 0x00, 0x00, 0x00, 0x00, 0x00 };
    @memcpy(input_buf[0..bad.len], &bad);
    try std.testing.expectEqual(@as(u32, 0), render(@intCast(bad.len)));
    try std.testing.expect(commit() < 0);

    const empty = [_]u8{ 0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01 };
    @memcpy(input_buf[0..empty.len], &empty);
    try std.testing.expectEqual(@as(u32, 0), render(empty.len));
    try std.testing.expectEqual(@as(i64, 0), commit());
}

test "rejects corrupted Adler-32 trailer" {
    const compressed = [_]u8{
        0x78, 0x9c, 0x01, 0x0c, 0x00, 0xf3, 0xff,
        'H',  'e',  'l',  'l',  'o',  ' ',  'w',
        'o',  'r',  'l',  'd',  '\n',
        0x1c, 0xf2, 0x04, 0x48, // last byte off by one
    };
    @memcpy(input_buf[0..compressed.len], &compressed);
    try std.testing.expectEqual(@as(u32, 0), render(@intCast(compressed.len)));
    try std.testing.expect(commit() < 0);
}

test "rejects FDICT preset dictionary streams" {
    // CMF 0x78, FLG 0x20 (FDICT set): 0x7820 % 31 == 0 so the header
    // passes the mod-31 check and rejection is down to the FDICT bit.
    const bad = [_]u8{ 0x78, 0x20, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00 };
    @memcpy(input_buf[0..bad.len], &bad);
    try std.testing.expectEqual(@as(u32, 0), render(@intCast(bad.len)));
    try std.testing.expect(commit() < 0);
}

test "handles a trailing empty stored block with exactly-full output" {
    // Go's NoCompression zlib streams end with an empty final stored block.
    const data = "abcdefgh";
    const compressed = [_]u8{
        0x78, 0x01,
        0x00, 0x08, 0x00, 0xf7, 0xff, // stored block, 8 bytes
        'a',  'b',  'c',  'd',  'e',  'f', 'g', 'h',
        0x01, 0x00, 0x00, 0xff, 0xff, // final empty stored block
        0x0e, 0x00, 0x03, 0x25, // adler32("abcdefgh")
    };
    @memcpy(input_buf[0..compressed.len], &compressed);
    const written = render(@intCast(compressed.len));
    try std.testing.expectEqual(@as(u32, data.len), written);
    try std.testing.expectEqual(@as(i64, 0), commit());
    try std.testing.expectEqualStrings(data, output_buf[0..written]);
}
