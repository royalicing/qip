# KTX2 image components

KTX2 is the container. Names such as `VK_FORMAT_B8G8R8A8_SRGB` and
`VK_FORMAT_R32G32B32A32_SFLOAT` describe the pixel payload inside that
container. They are not complete interchange formats by themselves. See
[Image container names and pixel format names](../../../docs/formats.md#image-container-names-and-pixel-format-names)
for diagrams of the BMP and KTX2 layers and the repository's naming rules.

QIP uses `VK_FORMAT_R8G8B8A8_SRGB` as its canonical general-purpose 8-bit
Content image. Its top-down RGBA payload matches Canvas `ImageData` channel
order and maps directly to the common WebGL and OpenGL ES RGBA texture path.
Presentation code still queries the platform's preferred canvas format; it can
render this texture into either an RGBA or BGRA surface without a CPU swizzle.

The linear RGBA32F Content components use KTX2 as an intermediate image buffer.
Pixels are four little-endian IEEE 754 `f32` values in linear-light RGBA order.
This gives image transforms a file-shaped boundary without converting working
pixels back to 8-bit sRGB after every component.

The accepted profile is intentionally narrow:

- MIME type: `image/ktx2`
- `vkFormat`: `VK_FORMAT_R32G32B32A32_SFLOAT` (109)
- one 2D image, one mip level, one face, and no array layers
- no supercompression
- BT.709 primaries, linear transfer, and straight alpha in the DFD
- top-to-bottom, left-to-right (`KTXorientation=rd`)
- one tightly packed level at byte offset 224
- at most 25,000,000 pixels and 8192 pixels on either axis

The strict profile keeps parsing small and makes the pixel payload directly
addressable in Wasm memory. It is not a general KTX2 decoder. Files with mip
chains, arrays, cubemaps, compressed texture data, a different data format
descriptor, or different metadata are rejected.

The canonical 8-bit profile has `vkFormat = VK_FORMAT_R8G8B8A8_SRGB` (43), one
2D level, straight alpha, and no supercompression. Its RGB bytes retain sRGB
encoding; alpha remains a linear UNORM byte. The repository retains the
`VK_FORMAT_B8G8R8A8_SRGB` components as an explicit alternate for boundaries
that require BGRA payload bytes. It is not the canonical Content profile.

The canonical KTX2 writers emit `KTXorientation=rd`: rows run from the logical top to
the bottom and pixels run left to right. The KTX specification recommends this
upper-left origin as the preferred default where possible and assumes `rd`
when the key is absent. Canonical profile readers require the explicit `rd`
metadata written by QIP. This keeps in-place RGBA8-to-RGBA32F expansion and
RGBA32F-to-RGBA8 compaction independent of row-order scratch memory.

## Components

`../bmp/bmp-b8g8r8a8-srgb-to-ktx2-rgba32float.wasm` decodes 32-bit uncompressed BMP
BGRA pixels. It converts sRGB colour channels to linear `f32`; alpha remains a
straight normalized value.

`ktx2-rgba32float-look-warm-fade.wasm` applies an authored 17x17x17 LUT with
trilinear interpolation. The look uses a restrained contrast curve, slightly
muted colour, cool shadows, and warm highlights. Its `strength` uniform accepts
0 through 1 and defaults to 1. The component changes the KTX2 pixel payload in
place, preserves alpha and container bytes, and retains excursions outside the
LUT's 0 through 1 domain. The LUT is source code in this repository and is
covered by the repository's Apache-2.0 license.

`ktx2-rgba32float-to-bmp-b8g8r8a8-srgb.wasm` converts linear colour to 8-bit sRGB and
writes an uncompressed, bottom-up BGRA BMP. Converting through both adapters
without an intervening transform reproduces every input channel byte.

`../bmp/bmp-b8g8r8a8-srgb-to-ktx2-r8g8b8a8-srgb.wasm` accepts positive-height
bottom-up and negative-height top-down BMPs. It reverses rows when needed and
swaps BGRA to the canonical top-down RGBA payload.

`ktx2-r8g8b8a8-srgb-to-bmp-b8g8r8a8-srgb.wasm` performs the inverse row and
channel conversion and writes a bottom-up BMP.

`ktx2-r8g8b8a8-srgb-to-ktx2-rgba32float.wasm` converts sRGB colour to linear
`f32`. `ktx2-rgba32float-to-ktx2-r8g8b8a8-srgb.wasm` converts back to sRGB bytes.
Both conversions preserve straight alpha and operate in place because their
KTX2 payloads start at the same byte offset. An RGBA8-to-float-to-RGBA8 round
trip reproduces every channel byte.

`../webp/webp-to-ktx2-r8g8b8a8-srgb.wasm` decodes static WebP directly into
the canonical RGBA payload. It rejects animated WebP and applies the standard
image limits.

`../png/png-to-ktx2-r8g8b8a8-srgb.wasm` decodes supported 8-bit,
non-interlaced PNGs directly into the canonical top-down RGBA payload. It
shares the strict parser and bounded inflater with the PNG-to-BMP component.

`../jpeg/jpeg-to-ktx2-r8g8b8a8-srgb.wasm` decodes JPEG directly into the
canonical payload. `ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jpeg-lossy.wasm`
accepts either strict 8-bit sRGB component order, composites straight alpha
against its configurable background, and encodes JPEG without a BMP boundary.

`../avif/avif-to-ktx2-r8g8b8a8-srgb.wasm` decodes one still AVIF directly
into canonical RGBA. The AVIF encoders record BT.709 primaries, the sRGB
transfer characteristic, and BT.601 matrix coefficients in CICP metadata.

`../svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm` renders SVG directly
into canonical top-down RGBA. It shares the parser and rasterizer with the BMP
component but writes pixels in their final KTX2 order.

`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-png.wasm` accepts either exact sRGB
component order and writes an 8-bit RGBA PNG. RGBA rows pass directly into PNG
filtering; BGRA rows swap red and blue in the encoder's bounded row buffer.

`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-avif-lossy.wasm` passes either payload
order directly to libavif. It preserves alpha and exposes quality, alpha
quality, speed, and chroma-subsampling uniforms.

`ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-webp-lossless.wasm` accepts either exact
sRGB component order with explicit `rd` orientation. It swaps R and B in a
disposable `VK_FORMAT_R8G8B8A8_SRGB` payload; a
`VK_FORMAT_B8G8R8A8_SRGB` payload already has the ARGB word representation
expected by libwebp on little-endian wasm32 and passes through unchanged. The
lossless encoder preserves RGB beneath transparent pixels.

`ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm` accepts only the canonical RGBA8
profile and uses the same in-place swap. Both encoders avoid an image-sized
libwebp import allocation and do not use a BMP component boundary.

`../bmp/bmp-b8g8r8a8-srgb-to-ktx2-b8g8r8a8-srgb.wasm` accepts both positive-height
bottom-up BMP and negative-height top-down BMP. It copies BGRA channel bytes to
a canonical top-down KTX2 payload.

`ktx2-b8g8r8a8-srgb-to-bmp-b8g8r8a8-srgb.wasm` copies the sRGB BGRA bytes back to a
bottom-up BMP. It accepts the common top-down KTX orientation, bottom-up `ru`,
and the specification's implicit top-down orientation. It rejects
`VK_FORMAT_B8G8R8A8_UNORM` because those bytes claim to contain linear colour.

For example:

```sh
./qip run \
  components/image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-rgba32float.wasm \
  components/image/ktx2/ktx2-rgba32float-look-warm-fade.wasm \
  '?strength=0.8' \
  components/image/ktx2/ktx2-rgba32float-to-bmp-b8g8r8a8-srgb.wasm \
  -i input.bmp -o output.bmp
```

To apply the look and write WebP without a BMP intermediate:

```sh
./qip run \
  components/image/webp/webp-to-ktx2-r8g8b8a8-srgb.wasm \
  components/image/ktx2/ktx2-r8g8b8a8-srgb-to-ktx2-rgba32float.wasm \
  components/image/ktx2/ktx2-rgba32float-look-warm-fade.wasm \
  components/image/ktx2/ktx2-rgba32float-to-ktx2-r8g8b8a8-srgb.wasm \
  components/image/ktx2/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm \
  -i input.webp -o output.webp
```

The KTX2 payload costs 16 bytes per pixel. The converters reserve about 512
MiB to hold worst-case input and output buffers. Do not use this profile when
compact storage, network transfer, mipmaps, or direct support from ordinary
image viewers is the main requirement. Use BMP, PNG, JPEG, or WebP at those
boundaries.

The RGBA8 sRGB payload costs 4 bytes per pixel. Use it for general 8-bit image
content and GPU upload, but not between operations that need linear light or
more than 8-bit precision. The RGBA8/float converters share their input and
output buffer and reserve 512 MiB for the 25 MP RGBA32F limit.
