//! Compares two concatenated, uncompressed BGRA32 BMP files and emits RGB
//! PSNR/SSIM as JSON. SSIM matches FFmpeg's 8-bit approximation: overlapping
//! 8x8 windows at four-pixel intervals with uniform rather than Gaussian
//! weights. Invoke with: cat reference.bmp candidate.bmp | qip run <module>.

const std = @import("std");

const INPUT_CAP: usize = 128 * 1024 * 1024;
const OUTPUT_CAP: usize = 1024;
const INPUT_CONTENT_TYPE = "application/vnd.qip.bmp-pair";
const OUTPUT_CONTENT_TYPE = "application/json";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return @intCast(INPUT_CAP);
}

export fn output_ptr() u32 {
    return @intCast(@intFromPtr(&output_buf));
}

export fn output_utf8_cap() u32 {
    return @intCast(OUTPUT_CAP);
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return @intCast(INPUT_CONTENT_TYPE.len);
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return @intCast(OUTPUT_CONTENT_TYPE.len);
}

const Bmp = struct {
    bytes: []const u8,
    pixels: usize,
    width: usize,
    height: usize,
    stride: usize,
    top_down: bool,

    fn row(self: Bmp, y: usize) []const u8 {
        const file_y = if (self.top_down) y else self.height - 1 - y;
        const start = self.pixels + file_y * self.stride;
        return self.bytes[start .. start + self.width * 4];
    }
};

fn readU16LE(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32LE(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn parseBmp(bytes: []const u8) ?Bmp {
    if (bytes.len < 54 or bytes[0] != 'B' or bytes[1] != 'M') return null;
    const file_size: usize = readU32LE(bytes, 2);
    const pixel_offset: usize = readU32LE(bytes, 10);
    const dib_size = readU32LE(bytes, 14);
    const width_signed: i32 = @bitCast(readU32LE(bytes, 18));
    const height_signed: i32 = @bitCast(readU32LE(bytes, 22));
    if (file_size < 54 or file_size > bytes.len or dib_size < 40 or pixel_offset < 54 or
        readU16LE(bytes, 26) != 1 or readU16LE(bytes, 28) != 32 or
        readU32LE(bytes, 30) != 0 or width_signed <= 0 or height_signed == 0 or
        height_signed == std.math.minInt(i32)) return null;
    const width: usize = @intCast(width_signed);
    const height: usize = @intCast(if (height_signed < 0) -height_signed else height_signed);
    if (width > 16383 or height > 16383 or width > std.math.maxInt(usize) / 4 / height) return null;
    const stride = width * 4;
    const pixel_bytes = stride * height;
    if (pixel_offset > file_size or pixel_bytes > file_size - pixel_offset) return null;
    return .{
        .bytes = bytes[0..file_size],
        .pixels = pixel_offset,
        .width = width,
        .height = height,
        .stride = stride,
        .top_down = height_signed < 0,
    };
}

fn ssimWindow(a: Bmp, b: Bmp, x0: usize, y0: usize, channel: usize) f64 {
    var sum_a: i64 = 0;
    var sum_b: i64 = 0;
    var sum_sq: i64 = 0;
    var sum_ab: i64 = 0;
    var y = y0;
    while (y < y0 + 8) : (y += 1) {
        const row_a = a.row(y);
        const row_b = b.row(y);
        var x = x0;
        while (x < x0 + 8) : (x += 1) {
            const av: i64 = row_a[x * 4 + channel];
            const bv: i64 = row_b[x * 4 + channel];
            sum_a += av;
            sum_b += bv;
            sum_sq += av * av + bv * bv;
            sum_ab += av * bv;
        }
    }
    // FFmpeg rounds these 8-bit constants to integers.
    const c1: i64 = 416;
    const c2: i64 = 235963;
    const variance = 64 * sum_sq - sum_a * sum_a - sum_b * sum_b;
    const covariance = 64 * sum_ab - sum_a * sum_b;
    const numerator: f64 = @floatFromInt((2 * sum_a * sum_b + c1) * (2 * covariance + c2));
    const denominator: f64 = @floatFromInt((sum_a * sum_a + sum_b * sum_b + c1) * (variance + c2));
    return numerator / denominator;
}

fn psnrFromSse(sse: u64, samples: u64) f64 {
    if (sse == 0) return std.math.inf(f64);
    const mse = @as(f64, @floatFromInt(sse)) / @as(f64, @floatFromInt(samples));
    return 10.0 * @log(65025.0 / mse) / @log(10.0);
}

export fn render(input_size_value: u32) u32 {
    const input_size: usize = @min(@as(usize, input_size_value), INPUT_CAP);
    if (input_size < 108) return 0;
    const first_size: usize = readU32LE(input_buf[0..input_size], 2);
    if (first_size < 54 or first_size > input_size - 54) return 0;
    const first = parseBmp(input_buf[0..first_size]) orelse return 0;
    const second = parseBmp(input_buf[first_size..input_size]) orelse return 0;
    if (first.width != second.width or first.height != second.height or
        first.width < 8 or first.height < 8) return 0;

    var sse_r: u64 = 0;
    var sse_g: u64 = 0;
    var sse_b: u64 = 0;
    var y: usize = 0;
    while (y < first.height) : (y += 1) {
        const a = first.row(y);
        const b = second.row(y);
        var x: usize = 0;
        while (x < first.width) : (x += 1) {
            const base = x * 4;
            const db = @as(i32, a[base]) - @as(i32, b[base]);
            const dg = @as(i32, a[base + 1]) - @as(i32, b[base + 1]);
            const dr = @as(i32, a[base + 2]) - @as(i32, b[base + 2]);
            sse_b += @intCast(db * db);
            sse_g += @intCast(dg * dg);
            sse_r += @intCast(dr * dr);
        }
    }

    var ssim_sum_r: f64 = 0;
    var ssim_sum_g: f64 = 0;
    var ssim_sum_b: f64 = 0;
    var windows: u64 = 0;
    y = 0;
    while (y + 8 <= first.height) : (y += 4) {
        var x: usize = 0;
        while (x + 8 <= first.width) : (x += 4) {
            ssim_sum_b += ssimWindow(first, second, x, y, 0);
            ssim_sum_g += ssimWindow(first, second, x, y, 1);
            ssim_sum_r += ssimWindow(first, second, x, y, 2);
            windows += 1;
        }
    }
    if (windows == 0) return 0;

    const pixels: u64 = @intCast(first.width * first.height);
    const samples = pixels * 3;
    const sse_rgb = sse_r + sse_g + sse_b;
    const mse_rgb = @as(f64, @floatFromInt(sse_rgb)) / @as(f64, @floatFromInt(samples));
    const psnr_rgb = psnrFromSse(sse_rgb, samples);
    const window_count: f64 = @floatFromInt(windows);
    const ssim_r = ssim_sum_r / window_count;
    const ssim_g = ssim_sum_g / window_count;
    const ssim_b = ssim_sum_b / window_count;
    const ssim_rgb = (ssim_r + ssim_g + ssim_b) / 3.0;

    const output = if (sse_rgb == 0)
        std.fmt.bufPrint(&output_buf,
            "{{\"width\":{d},\"height\":{d},\"identical\":true,\"mse_rgb\":{d:.6},\"psnr_rgb_db\":null,\"ssim_r\":{d:.6},\"ssim_g\":{d:.6},\"ssim_b\":{d:.6},\"ssim_rgb\":{d:.6}}}\n",
            .{ first.width, first.height, mse_rgb, ssim_r, ssim_g, ssim_b, ssim_rgb },
        ) catch return 0
    else
        std.fmt.bufPrint(&output_buf,
            "{{\"width\":{d},\"height\":{d},\"identical\":false,\"mse_rgb\":{d:.6},\"psnr_rgb_db\":{d:.6},\"ssim_r\":{d:.6},\"ssim_g\":{d:.6},\"ssim_b\":{d:.6},\"ssim_rgb\":{d:.6}}}\n",
            .{ first.width, first.height, mse_rgb, psnr_rgb, ssim_r, ssim_g, ssim_b, ssim_rgb },
        ) catch return 0;
    return @intCast(output.len);
}
