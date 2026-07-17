//! Converts PNG (8-bit depth; grayscale, truecolor, palette, and alpha
//! variants; non-interlaced) to BMP (BITMAPINFOHEADER, 32-bit BGRA,
//! bottom-up) so PNGs can flow into every bmp-consuming component.
//!
//! Strict by default: chunk CRCs are verified here, the shared inflater in
//! lib/inflate.zig verifies the zlib header and Adler-32 trailer, and unknown
//! critical chunks are rejected. 16-bit depths, sub-8-bit depths, and Adam7
//! interlacing return 0.

const std = @import("std");
const inflate = @import("lib/inflate.zig");

const INPUT_CAP: usize = 8 * 1024 * 1024;
const IDAT_CAP: usize = INPUT_CAP;
const RAW_CAP: usize = 40 * 1024 * 1024;
const OUTPUT_CAP: usize = 32 * 1024 * 1024 + 64;
const INPUT_CONTENT_TYPE = "image/png";
const OUTPUT_CONTENT_TYPE = "image/bmp";

var input_buf: [INPUT_CAP]u8 = undefined;
var idat_buf: [IDAT_CAP]u8 = undefined;
var raw_buf: [RAW_CAP]u8 = undefined;
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

const CRC_TABLE = blk: {
    @setEvalBranchQuota(10000);
    var t: [256]u32 = undefined;
    for (&t, 0..) |*e, n| {
        var c: u32 = n;
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            c = if (c & 1 != 0) 0xEDB88320 ^ (c >> 1) else c >> 1;
        }
        e.* = c;
    }
    break :blk t;
};

fn crc32(bytes: []const u8) u32 {
    var c: u32 = 0xFFFFFFFF;
    for (bytes) |b| {
        c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >> 8);
    }
    return c ^ 0xFFFFFFFF;
}

fn readU32BE(data: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, data[off..][0..4], .big);
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = @abs(p - @as(i32, a));
    const pb = @abs(p - @as(i32, b));
    const pc = @abs(p - @as(i32, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

const Header = struct {
    width: u32,
    height: u32,
    color_type: u8,
    channels: usize,
};

export fn render(input_size_in: u32) u32 {
    const input_size: usize = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    const input = input_buf[0..input_size];

    const sig = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
    if (input.len < sig.len + 12 or !std.mem.eql(u8, input[0..8], &sig)) return 0;

    var header: ?Header = null;
    var palette: []const u8 = &.{};
    var trns: []const u8 = &.{};
    var idat_len: usize = 0;
    var seen_iend = false;

    var pos: usize = 8;
    while (pos + 12 <= input.len) {
        const chunk_len: usize = readU32BE(input, pos);
        if (pos + 12 + chunk_len > input.len) return 0;
        const chunk_type = input[pos + 4 .. pos + 8];
        const data = input[pos + 8 .. pos + 8 + chunk_len];
        const stored_crc = readU32BE(input, pos + 8 + chunk_len);
        if (crc32(input[pos + 4 .. pos + 8 + chunk_len]) != stored_crc) return 0;

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (header != null or chunk_len != 13) return 0;
            const color_type = data[9];
            const channels: usize = switch (color_type) {
                0, 3 => 1,
                2 => 3,
                4 => 2,
                6 => 4,
                else => return 0,
            };
            // 8-bit depth, deflate compression, standard filtering,
            // no interlacing.
            if (data[8] != 8 or data[10] != 0 or data[11] != 0 or data[12] != 0) return 0;
            header = .{
                .width = readU32BE(data, 0),
                .height = readU32BE(data, 4),
                .color_type = color_type,
                .channels = channels,
            };
        } else if (std.mem.eql(u8, chunk_type, "PLTE")) {
            if (chunk_len == 0 or chunk_len > 768 or chunk_len % 3 != 0) return 0;
            palette = data;
        } else if (std.mem.eql(u8, chunk_type, "tRNS")) {
            trns = data;
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            if (idat_len + chunk_len > IDAT_CAP) return 0;
            @memcpy(idat_buf[idat_len..][0..chunk_len], data);
            idat_len += chunk_len;
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            if (chunk_len != 0 or pos + 12 != input.len) return 0;
            seen_iend = true;
        } else if (chunk_type[0] & 0x20 == 0) {
            // Unknown critical chunk.
            return 0;
        }

        pos += 12 + chunk_len;
    }

    const h = header orelse return 0;
    if (!seen_iend or idat_len == 0) return 0;
    if (h.width == 0 or h.height == 0) return 0;
    if (h.color_type == 3 and palette.len == 0) return 0;

    const width: u64 = h.width;
    const height: u64 = h.height;
    const row_bytes: u64 = width * h.channels;
    const raw_len: u64 = (1 + row_bytes) * height;
    if (raw_len > RAW_CAP) return 0;

    const out_stride: u64 = width * 4;
    const out_total: u64 = 54 + out_stride * height;
    if (out_total > OUTPUT_CAP) return 0;

    const inflated = inflate.inflateZlib(idat_buf[0..idat_len], raw_buf[0..@intCast(raw_len)]) orelse return 0;
    if (inflated != raw_len) return 0;

    // Undo per-scanline filters in place.
    const rb: usize = @intCast(row_bytes);
    const bpp = h.channels;
    var prior: []const u8 = &.{};
    var y: u64 = 0;
    while (y < height) : (y += 1) {
        const line_start: usize = @intCast(y * (1 + row_bytes));
        const filter = raw_buf[line_start];
        if (filter > 4) return 0;
        const line = raw_buf[line_start + 1 ..][0..rb];
        var i: usize = 0;
        while (i < rb) : (i += 1) {
            const a = if (i >= bpp) line[i - bpp] else 0;
            const b = if (prior.len != 0) prior[i] else 0;
            const c = if (i >= bpp and prior.len != 0) prior[i - bpp] else 0;
            line[i] = switch (filter) {
                0 => line[i],
                1 => line[i] +% a,
                2 => line[i] +% b,
                3 => line[i] +% @as(u8, @intCast((@as(u16, a) + @as(u16, b)) >> 1)),
                else => line[i] +% paeth(a, b, c),
            };
        }
        prior = line;
    }

    // BMP header: BITMAPINFOHEADER, 32-bit BGRA, bottom-up.
    @memset(output_buf[0..54], 0);
    output_buf[0] = 'B';
    output_buf[1] = 'M';
    std.mem.writeInt(u32, output_buf[2..6], @intCast(out_total), .little);
    std.mem.writeInt(u32, output_buf[10..14], 54, .little);
    std.mem.writeInt(u32, output_buf[14..18], 40, .little);
    std.mem.writeInt(i32, output_buf[18..22], @intCast(width), .little);
    std.mem.writeInt(i32, output_buf[22..26], @intCast(height), .little);
    std.mem.writeInt(u16, output_buf[26..28], 1, .little);
    std.mem.writeInt(u16, output_buf[28..30], 32, .little);
    std.mem.writeInt(u32, output_buf[34..38], @intCast(out_stride * height), .little);
    std.mem.writeInt(u32, output_buf[38..42], 2835, .little);
    std.mem.writeInt(u32, output_buf[42..46], 2835, .little);

    y = 0;
    while (y < height) : (y += 1) {
        const line = raw_buf[@intCast(y * (1 + row_bytes) + 1)..][0..rb];
        const dst_row: usize = @intCast(54 + (height - 1 - y) * out_stride);
        var x: usize = 0;
        while (x < h.width) : (x += 1) {
            const dst = dst_row + x * 4;
            switch (h.color_type) {
                0 => {
                    const g = line[x];
                    output_buf[dst] = g;
                    output_buf[dst + 1] = g;
                    output_buf[dst + 2] = g;
                    output_buf[dst + 3] = 255;
                },
                4 => {
                    const g = line[x * 2];
                    output_buf[dst] = g;
                    output_buf[dst + 1] = g;
                    output_buf[dst + 2] = g;
                    output_buf[dst + 3] = line[x * 2 + 1];
                },
                2 => {
                    output_buf[dst] = line[x * 3 + 2];
                    output_buf[dst + 1] = line[x * 3 + 1];
                    output_buf[dst + 2] = line[x * 3];
                    output_buf[dst + 3] = 255;
                },
                6 => {
                    output_buf[dst] = line[x * 4 + 2];
                    output_buf[dst + 1] = line[x * 4 + 1];
                    output_buf[dst + 2] = line[x * 4];
                    output_buf[dst + 3] = line[x * 4 + 3];
                },
                else => {
                    const idx: usize = line[x];
                    if (idx * 3 + 3 > palette.len) return 0;
                    output_buf[dst] = palette[idx * 3 + 2];
                    output_buf[dst + 1] = palette[idx * 3 + 1];
                    output_buf[dst + 2] = palette[idx * 3];
                    output_buf[dst + 3] = if (idx < trns.len) trns[idx] else 255;
                },
            }
        }
    }

    return @as(u32, @intCast(out_total));
}

test "crc32 matches the PNG check value" {
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32("123456789"));
}
