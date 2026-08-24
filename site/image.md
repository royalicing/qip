<title>Image content components</title>

# Image content components

These components accept an `image/*` MIME type. Common web and camera formats come first. Download a `.wasm` file and run it with [`qipx run`](/docs/qipx), or use the [recipe finder](/recipes) to connect compatible decoders, transforms, and encoders.

## JPEG (`image/jpeg`)

- [`jpeg-strip-gps-exif.wasm`](/components/image/jpeg/jpeg-strip-gps-exif.wasm) removes GPS coordinates from EXIF metadata without decoding the image.
- [`jpeg-to-bmp-b8g8r8a8-srgb.wasm`](/components/image/jpeg/jpeg-to-bmp-b8g8r8a8-srgb.wasm) decodes JPEG to an 8-bit sRGB BMP image.
- [`jpeg-to-ktx2-r8g8b8a8-srgb.wasm`](/components/image/jpeg/jpeg-to-ktx2-r8g8b8a8-srgb.wasm) decodes JPEG to an 8-bit sRGB KTX2 image.

Related tool: [JPEG location stripper](/jpeg-location-stripper).

## PNG (`image/png`)

- [`png-to-bmp-b8g8r8a8-srgb.wasm`](/components/image/png/png-to-bmp-b8g8r8a8-srgb.wasm) decodes PNG to an 8-bit sRGB BMP image.
- [`png-to-bmp-b8g8r8a8-srgb-simd.wasm`](/components/image/png/png-to-bmp-b8g8r8a8-srgb-simd.wasm) provides the SIMD PNG-to-BMP decoder.
- [`png-to-ktx2-r8g8b8a8-srgb.wasm`](/components/image/png/png-to-ktx2-r8g8b8a8-srgb.wasm) decodes PNG to an 8-bit sRGB KTX2 image.

Related tools: [favicon generator](/favicon) and [image compressor](/image-compress).

## WebP (`image/webp`)

- [`webp-to-bmp-b8g8r8a8-srgb.wasm`](/components/image/webp/webp-to-bmp-b8g8r8a8-srgb.wasm) decodes static WebP to an 8-bit sRGB BMP image.
- [`webp-to-ktx2-r8g8b8a8-srgb.wasm`](/components/image/webp/webp-to-ktx2-r8g8b8a8-srgb.wasm) decodes static WebP to an 8-bit sRGB KTX2 image.

Related tool: [WebP to PNG or BMP](/webp-to-png).

## SVG (`image/svg+xml`)

- [`svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm`](/components/image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm) rasterizes the supported SVG subset to BMP.
- [`svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm`](/components/image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm) rasterizes the supported SVG subset to KTX2.
- [`svg-recolor-current-color.wasm`](/components/image/svg+xml/svg-recolor-current-color.wasm) replaces supported `currentColor` uses with a supplied color.
- [`svg-to-data-uri.wasm`](/components/image/svg+xml/svg-to-data-uri.wasm) percent-encodes SVG bytes as a data URI.

Related tools: [SVG data URI](/svg-data-uri), [QR code maker](/qr), and [Open Graph image maker](/og-image).

## GIF (`image/gif`)

- [`gifsicle-optimize.wasm`](/components/image/gif/gifsicle-optimize.wasm) optimizes a GIF while preserving its image data and animation.

## AVIF (`image/avif`)

- [`avif-to-ktx2-r8g8b8a8-srgb.wasm`](/components/image/avif/avif-to-ktx2-r8g8b8a8-srgb.wasm) decodes AVIF to an 8-bit sRGB KTX2 image.

Related tool: [image compressor](/image-compress).

## BMP (`image/bmp`)

### Color and size

- [`bmp-b8g8r8a8-icc-to-srgb.wasm`](/components/image/bmp/bmp-b8g8r8a8-icc-to-srgb.wasm) converts supported embedded ICC color profiles to sRGB.
- [`bmp-color-palette.wasm`](/components/image/bmp/bmp-color-palette.wasm) returns a representative color palette as JSON.
- [`bmp-double.wasm`](/components/image/bmp/bmp-double.wasm) doubles the image dimensions with the C scaler.
- [`bmp-double2.wasm`](/components/image/bmp/bmp-double2.wasm) doubles the image dimensions with the Zig scaler.
- [`bmp-double-simd.wasm`](/components/image/bmp/bmp-double-simd.wasm) doubles the image dimensions with the SIMD scaler.

### Encode

- [`bmp-b8g8r8a8-srgb-to-avif-lossy.wasm`](/components/image/bmp/bmp-b8g8r8a8-srgb-to-avif-lossy.wasm) encodes lossy AVIF.
- [`bmp-b8g8r8a8-srgb-to-jpeg-lossy.wasm`](/components/image/bmp/bmp-b8g8r8a8-srgb-to-jpeg-lossy.wasm) encodes lossy JPEG.
- [`bmp-b8g8r8a8-srgb-to-webp-lossless.wasm`](/components/image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossless.wasm) encodes exact lossless WebP.
- [`bmp-b8g8r8a8-srgb-to-webp-lossy.wasm`](/components/image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy.wasm) encodes lossy WebP with alpha.
- [`bmp-b8g8r8a8-srgb-to-webp-lossy-opaque.wasm`](/components/image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy-opaque.wasm) encodes lossy WebP without alpha.
- [`bmp-to-ico.wasm`](/components/image/bmp/bmp-to-ico.wasm) creates an ICO favicon.
- [`bmp-to-png.wasm`](/components/image/bmp/bmp-to-png.wasm) encodes PNG.

### Convert to KTX2

- [`bmp-b8g8r8a8-srgb-to-ktx2-b8g8r8a8-srgb.wasm`](/components/image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-b8g8r8a8-srgb.wasm) stores 8-bit BGRA sRGB pixels.
- [`bmp-b8g8r8a8-srgb-to-ktx2-r8g8b8a8-srgb.wasm`](/components/image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-r8g8b8a8-srgb.wasm) stores 8-bit RGBA sRGB pixels.
- [`bmp-b8g8r8a8-srgb-to-ktx2-rgba32float.wasm`](/components/image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-rgba32float.wasm) stores 32-bit floating-point RGBA pixels.

Related tools: [image color palette](/image-color-palette), [favicon generator](/favicon), [BMP to WebP](/webp), and [image compressor](/image-compress).

## KTX2 (`image/ktx2`)

### Decode and encode

- [`ktx2-b8g8r8a8-srgb-to-bmp-b8g8r8a8-srgb.wasm`](/components/image/ktx2/ktx2-b8g8r8a8-srgb-to-bmp-b8g8r8a8-srgb.wasm) converts 8-bit BGRA sRGB KTX2 to BMP.
- [`ktx2-r8g8b8a8-srgb-to-bmp-b8g8r8a8-srgb.wasm`](/components/image/ktx2/ktx2-r8g8b8a8-srgb-to-bmp-b8g8r8a8-srgb.wasm) converts 8-bit RGBA sRGB KTX2 to BMP.
- [`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-avif-lossy.wasm`](/components/image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-avif-lossy.wasm) encodes lossy AVIF.
- [`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jpeg-lossy.wasm`](/components/image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jpeg-lossy.wasm) encodes lossy JPEG.
- [`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-png.wasm`](/components/image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-png.wasm) encodes PNG.
- [`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-webp-lossless.wasm`](/components/image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-webp-lossless.wasm) encodes exact lossless WebP.
- [`ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm`](/components/image/ktx2/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm) encodes lossy WebP.

### Floating-point pipeline

- [`ktx2-r8g8b8a8-srgb-to-ktx2-rgba32float.wasm`](/components/image/ktx2/ktx2-r8g8b8a8-srgb-to-ktx2-rgba32float.wasm) converts 8-bit sRGB pixels to 32-bit floating-point RGBA pixels.
- [`ktx2-rgba32float-look-warm-fade.wasm`](/components/image/ktx2/ktx2-rgba32float-look-warm-fade.wasm) applies the warm-fade color look.
- [`ktx2-rgba32float-to-bmp-b8g8r8a8-srgb.wasm`](/components/image/ktx2/ktx2-rgba32float-to-bmp-b8g8r8a8-srgb.wasm) converts floating-point RGBA pixels to an 8-bit sRGB BMP image.
- [`ktx2-rgba32float-to-ktx2-r8g8b8a8-srgb.wasm`](/components/image/ktx2/ktx2-rgba32float-to-ktx2-r8g8b8a8-srgb.wasm) converts floating-point RGBA pixels to 8-bit sRGB KTX2.

## JPEG 2000 (`image/jp2`)

- [`jp2-to-bmp-b8g8r8a8-srgb.wasm`](/components/image/jp2/jp2-to-bmp-b8g8r8a8-srgb.wasm) decodes JPEG 2000 to an 8-bit sRGB BMP image.

Looking for source formats and markup instead? See the [text content components](/text).
