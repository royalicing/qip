//! Baseline JPEG decoder with canonical top-down RGBA8 sRGB KTX2 output.

pub const JPEG_OUTPUT_KTX2 = true;

comptime {
    _ = @import("jpeg-to-bmp-b8g8r8a8-srgb.zig");
}
