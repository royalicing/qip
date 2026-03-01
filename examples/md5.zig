const INPUT_CAP: usize = 64 * 1024;
const OUTPUT_CAP: usize = 32; // hex-encoded 128-bit digest

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

export fn output_utf8_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

// MD5 per-round constants derived from abs(sin(i+1)) * 2^32.
const K: [64]u32 = .{
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
    0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
    0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
    0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
    0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
    0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
    0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
    0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
    0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
};

// Left-rotate amounts for each of the 64 rounds.
const S: [64]u5 = .{
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
};

fn rotl32(x: u32, n: u5) u32 {
    return (x << n) | (x >> (32 - n));
}

fn readU32LE(b: []const u8, off: usize) u32 {
    return @as(u32, b[off]) |
        (@as(u32, b[off + 1]) << 8) |
        (@as(u32, b[off + 2]) << 16) |
        (@as(u32, b[off + 3]) << 24);
}

fn writeU32LE(b: []u8, off: usize, v: u32) void {
    b[off]     = @intCast(v & 0xff);
    b[off + 1] = @intCast((v >> 8) & 0xff);
    b[off + 2] = @intCast((v >> 16) & 0xff);
    b[off + 3] = @intCast((v >> 24) & 0xff);
}

/// Processes a single 512-bit (64-byte) block updating state [a, b, c, d].
fn processBlock(state: *[4]u32, block: []const u8) void {
    var M: [16]u32 = undefined;
    for (0..16) |i| M[i] = readU32LE(block, i * 4);

    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];

    for (0..64) |i| {
        var F: u32 = undefined;
        var g: usize = undefined;
        if (i < 16) {
            F = (b & c) | (~b & d);
            g = i;
        } else if (i < 32) {
            F = (d & b) | (~d & c);
            g = (5 * i + 1) % 16;
        } else if (i < 48) {
            F = b ^ c ^ d;
            g = (3 * i + 5) % 16;
        } else {
            F = c ^ (b | ~d);
            g = (7 * i) % 16;
        }
        F = F +% a +% K[i] +% M[g];
        a = d;
        d = c;
        c = b;
        b = b +% rotl32(F, S[i]);
    }

    state[0] +%= a;
    state[1] +%= b;
    state[2] +%= c;
    state[3] +%= d;
}

const HEX = "0123456789abcdef";

/// Computes the MD5 digest of `data` and writes 32 hex chars into `out`.
fn md5Hex(data: []const u8, out: []u8) void {
    var state: [4]u32 = .{ 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476 };

    // Process all complete 64-byte blocks.
    const full_blocks = data.len / 64;
    for (0..full_blocks) |bi| processBlock(&state, data[bi * 64 ..][0..64]);

    // Build the padded final block(s).
    const remainder = data.len % 64;
    var pad: [128]u8 = [_]u8{0} ** 128;
    @memcpy(pad[0..remainder], data[full_blocks * 64 ..][0..remainder]);
    pad[remainder] = 0x80;

    // Bit length as 64-bit LE integer appended at byte 56 or 120.
    const bit_len: u64 = @as(u64, data.len) * 8;
    const len_off: usize = if (remainder < 56) 56 else 120;
    pad[len_off]     = @intCast(bit_len & 0xff);
    pad[len_off + 1] = @intCast((bit_len >> 8) & 0xff);
    pad[len_off + 2] = @intCast((bit_len >> 16) & 0xff);
    pad[len_off + 3] = @intCast((bit_len >> 24) & 0xff);
    pad[len_off + 4] = @intCast((bit_len >> 32) & 0xff);
    pad[len_off + 5] = @intCast((bit_len >> 40) & 0xff);
    pad[len_off + 6] = @intCast((bit_len >> 48) & 0xff);
    pad[len_off + 7] = @intCast((bit_len >> 56) & 0xff);

    const pad_blocks: usize = if (remainder < 56) 1 else 2;
    for (0..pad_blocks) |pi| processBlock(&state, pad[pi * 64 ..][0..64]);

    // Serialise digest as 32 lower-case hex characters.
    var digest: [16]u8 = undefined;
    for (0..4) |i| writeU32LE(&digest, i * 4, state[i]);
    for (0..16) |i| {
        out[i * 2]     = HEX[digest[i] >> 4];
        out[i * 2 + 1] = HEX[digest[i] & 0xf];
    }
}

export fn run(input_size: u32) u32 {
    const n: usize = @min(@as(usize, @intCast(input_size)), INPUT_CAP);
    md5Hex(input_buf[0..n], &output_buf);
    return OUTPUT_CAP;
}

const testing = @import("std").testing;

test "md5 empty string" {
    md5Hex("", &output_buf);
    try testing.expectEqualStrings("d41d8cd98f00b204e9800998ecf8427e", &output_buf);
}

test "md5 abc" {
    md5Hex("abc", &output_buf);
    try testing.expectEqualStrings("900150983cd24fb0d6963f7d28e17f72", &output_buf);
}

test "md5 hello world" {
    md5Hex("hello world", &output_buf);
    try testing.expectEqualStrings("5eb63bbbe01eeed093cb22bb8f5acdc3", &output_buf);
}

test "md5 54-byte message (single padding block)" {
    md5Hex("The quick brown fox jumps over the lazy dog", &output_buf);
    try testing.expectEqualStrings("9e107d9d372bb6826bd81d3542a419d6", &output_buf);
}

test "md5 55-byte boundary (two padding blocks)" {
    md5Hex("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &output_buf); // 55 a's
    try testing.expectEqualStrings("ca9d0a4578fb36b940d7bbbfd8e25bbe", &output_buf);
}
