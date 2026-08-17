//! Conformance oracle for baseline JPEG -> BMP (32-bit BGRA) decoders.
//!
//! Fixture JPEGs live in jpeg-to-bmp-bgra32-fixtures/ beside this file,
//! encoded with cjpeg (libjpeg-turbo). Each expected BMP was produced by
//! decoding with djpeg's default ("fancy" triangle-filter upsampling) —
//! an oracle independent of the implementation — and packing the result as
//! BITMAPINFOHEADER, 32-bit BGRA, bottom-up, alpha 255.
//!
//! Fixtures include solid colors (DC-only blocks), grayscale, unsubsampled
//! 4:4:4, and genuinely varying chroma under 4:2:0, 4:2:2, and vertical-only
//! 1x2 subsampling, so all three fancy-upsampling shapes (horizontal-only,
//! vertical-only, and both) are exercised against real interpolated output,
//! not just chroma-constant images. Malformed and progressive streams must
//! produce empty output; interleaving them between valid cases also checks
//! that a rejected input leaves no state behind on the reused implementation
//! instance.

extern "qip" fn must_render_exactly(
    ordinal: u64,
    input_ptr: u32,
    input_len: u32,
    expected_ptr: u32,
    expected_len: u32,
) i32;

const solid_gray_jpg = @embedFile("jpeg-to-bmp-bgra32-fixtures/solid-8x8-grayscale.jpg");
const solid_gray_bmp = @embedFile("jpeg-to-bmp-bgra32-fixtures/solid-8x8-grayscale.expected.bmp");
const red_420_jpg = @embedFile("jpeg-to-bmp-bgra32-fixtures/red-16x16-420.jpg");
const red_420_bmp = @embedFile("jpeg-to-bmp-bgra32-fixtures/red-16x16-420.expected.bmp");
const teal_422_jpg = @embedFile("jpeg-to-bmp-bgra32-fixtures/teal-16x16-422.jpg");
const teal_422_bmp = @embedFile("jpeg-to-bmp-bgra32-fixtures/teal-16x16-422.expected.bmp");
const gradient_gray_jpg = @embedFile("jpeg-to-bmp-bgra32-fixtures/gradient-32x32-grayscale.jpg");
const gradient_gray_bmp = @embedFile("jpeg-to-bmp-bgra32-fixtures/gradient-32x32-grayscale.expected.bmp");
const gradient_444_jpg = @embedFile("jpeg-to-bmp-bgra32-fixtures/gradient-16x16-444.jpg");
const gradient_444_bmp = @embedFile("jpeg-to-bmp-bgra32-fixtures/gradient-16x16-444.expected.bmp");
const gradient_rst_jpg = @embedFile("jpeg-to-bmp-bgra32-fixtures/gradient-33x17-444-rst1.jpg");
const gradient_rst_bmp = @embedFile("jpeg-to-bmp-bgra32-fixtures/gradient-33x17-444-rst1.expected.bmp");
const gray_420_jpg = @embedFile("jpeg-to-bmp-bgra32-fixtures/gray-gradient-21x13-420.jpg");
const gray_420_bmp = @embedFile("jpeg-to-bmp-bgra32-fixtures/gray-gradient-21x13-420.expected.bmp");
const color_420_jpg = @embedFile("jpeg-to-bmp-bgra32-fixtures/color-gradient-23x19-420.jpg");
const color_420_bmp = @embedFile("jpeg-to-bmp-bgra32-fixtures/color-gradient-23x19-420.expected.bmp");
const color_422_jpg = @embedFile("jpeg-to-bmp-bgra32-fixtures/color-gradient-25x11-422.jpg");
const color_422_bmp = @embedFile("jpeg-to-bmp-bgra32-fixtures/color-gradient-25x11-422.expected.bmp");
const color_1x2_jpg = @embedFile("jpeg-to-bmp-bgra32-fixtures/color-gradient-12x10-1x2.jpg");
const color_1x2_bmp = @embedFile("jpeg-to-bmp-bgra32-fixtures/color-gradient-12x10-1x2.expected.bmp");
const not_a_jpeg = @embedFile("jpeg-to-bmp-bgra32-fixtures/invalid-not-a-jpeg.bin");
const truncated = @embedFile("jpeg-to-bmp-bgra32-fixtures/invalid-truncated.bin");
const progressive = @embedFile("jpeg-to-bmp-bgra32-fixtures/invalid-progressive.jpg");

inline fn expectDecode(comptime ordinal: u64, comptime jpg: []const u8, comptime bmp: []const u8) void {
    _ = must_render_exactly(
        ordinal,
        @intCast(@intFromPtr(jpg.ptr)),
        @intCast(jpg.len),
        @intCast(@intFromPtr(bmp.ptr)),
        @intCast(bmp.len),
    );
}

inline fn expectEmpty(comptime ordinal: u64, comptime input: []const u8) void {
    _ = must_render_exactly(
        ordinal,
        @intCast(@intFromPtr(input.ptr)),
        @intCast(input.len),
        @intCast(@intFromPtr(input.ptr)),
        0,
    );
}

export fn comply() i32 {
    expectDecode(0, solid_gray_jpg, solid_gray_bmp);
    expectEmpty(1, not_a_jpeg);
    expectDecode(2, red_420_jpg, red_420_bmp);
    expectDecode(3, teal_422_jpg, teal_422_bmp);
    expectEmpty(4, truncated);
    expectDecode(5, gradient_gray_jpg, gradient_gray_bmp);
    expectDecode(6, gradient_444_jpg, gradient_444_bmp);
    expectEmpty(7, progressive);
    expectDecode(8, gradient_rst_jpg, gradient_rst_bmp);
    expectDecode(9, gray_420_jpg, gray_420_bmp);
    expectDecode(10, color_420_jpg, color_420_bmp);
    expectDecode(11, color_422_jpg, color_422_bmp);
    expectDecode(12, color_1x2_jpg, color_1x2_bmp);
    expectEmpty(13, not_a_jpeg[0..0]);
    return 14;
}
