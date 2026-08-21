//! SVG rasterizer with canonical top-down RGBA8 sRGB KTX2 output.

pub const SVG_OUTPUT_KTX2 = true;

comptime {
    _ = @import("lib/svg-rasterize.zig");
}
