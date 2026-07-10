//! zlib compression with one final dynamic-Huffman DEFLATE block, using the
//! shared engine in lib/deflate.zig.

const std = @import("std");
const deflate = @import("lib/deflate.zig");

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP + (INPUT_CAP / 8) + 4096;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var token_buf: [INPUT_CAP]u32 = undefined;

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
    const input_size: usize = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    const input = input_buf[0..input_size];

    const written = deflate.compressZlib(input, &output_buf, &token_buf) orelse return 0;
    return @as(u32, @intCast(written));
}

fn decompressZlib(compressed: []const u8, out: []u8) !usize {
    var in: std.Io.Reader = .fixed(compressed);
    var decompress: std.compress.flate.Decompress = .init(&in, .zlib, &.{});
    var out_writer: std.Io.Writer = .fixed(out);

    const n = try decompress.reader.streamRemaining(&out_writer);

    var trailing: [1]u8 = undefined;
    if (try in.readSliceShort(&trailing) != 0) return error.TrailingBytes;
    return n;
}

test "round trips short text" {
    const plain = "dynamic huffman in qip";
    @memcpy(input_buf[0..plain.len], plain);

    const written = render(@intCast(plain.len));
    try std.testing.expect(written > 0);

    // Verify dynamic block type: lower 3 bits should be BFINAL=1,BTYPE=10 => 0b101.
    try std.testing.expectEqual(@as(u8, 0b101), output_buf[2] & 0x07);

    var out: [128]u8 = undefined;
    const n = try decompressZlib(output_buf[0..written], &out);
    try std.testing.expectEqualStrings(plain, out[0..n]);
}

test "round trips empty input" {
    const written = render(0);
    try std.testing.expect(written > 0);

    var out: [1]u8 = undefined;
    const n = try decompressZlib(output_buf[0..written], &out);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "round trips repetitive data" {
    var plain: [65536]u8 = undefined;
    for (&plain, 0..) |*b, i| {
        b.* = if ((i % 64) < 48) 'a' else 'b';
    }
    @memcpy(input_buf[0..plain.len], &plain);

    const written = render(@intCast(plain.len));
    try std.testing.expect(written > 0);

    var out: [65536]u8 = undefined;
    const n = try decompressZlib(output_buf[0..written], &out);
    try std.testing.expectEqual(plain.len, n);
    try std.testing.expectEqualSlices(u8, &plain, out[0..n]);
}

test "length and distance symbol tables match RFC 1951" {
    try std.testing.expectEqual(@as(u16, 257), deflate.encodeLength(3).symbol);
    try std.testing.expectEqual(@as(u16, 283), deflate.encodeLength(226).symbol);
    try std.testing.expectEqual(@as(u16, 284), deflate.encodeLength(227).symbol);
    try std.testing.expectEqual(@as(u16, 284), deflate.encodeLength(257).symbol);
    try std.testing.expectEqual(@as(u16, 285), deflate.encodeLength(258).symbol);
    try std.testing.expectEqual(@as(u8, 0), deflate.encodeLength(258).extra_bits);

    var d: usize = 1;
    while (d <= 32768) : (d += 1) {
        const e = deflate.encodeDistance(d);
        const base = deflate.DIST_BASE[e.symbol];
        try std.testing.expect(d >= base);
        try std.testing.expect(d - base < (@as(usize, 1) << @intCast(e.extra_bits)));
    }
}

test "round trips max-length matches" {
    const plain = [_]u8{'a'} ** 300;
    @memcpy(input_buf[0..plain.len], &plain);

    const written = render(@intCast(plain.len));
    try std.testing.expect(written > 0);

    var out: [512]u8 = undefined;
    const n = try decompressZlib(output_buf[0..written], &out);
    try std.testing.expectEqualSlices(u8, &plain, out[0..n]);
}
