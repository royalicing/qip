# Formats and Encodings

`qip` intentionally chooses old & boring open formats:

- Simpler parsing and fewer edge cases.
- Broad ecosystem of existing tooling.
- Easier for coding agents to generate correct implementations.
- Likely to still work in 10+ years.
- Reduced lock-in to proprietary systems.

For qip's one-input/one-output component model, stable interchange formats make QIP components more reusable.

## Preferred formats

Current formats directly supported by a qip command or supported by this repo’s modules in `components/`:

- `application/warc`: website snapshots
- `application/x-tar`: directory archive as one input/output blob
- `application/zip`: compressed directory archive for broad tool compatibility
- `application/x-www-form-urlencoded`: small named UTF-8 form fields
- `image/bmp`: simple uncompressed raster interchange
- `image/ktx2`: canonical RGBA8 sRGB images and linear RGBA32F working images
- `image/jp2`: JPEG 2000 still images
- `image/svg+xml`: vector graphics that work great with LLMs
- `image/x-icon`
- `image/gif`
- `font/ttf`: SFNT fonts with TrueType `glyf` outlines
- `text/markdown`
- `text/html`
- `text/javascript`
- `text/x-c`
- `text/x-swift`
- `text/x-zig`
- `application/vnd.sqlite3`
- `application/xml`

Examples:

- `qip router warc ...` emits `application/warc`
- `components/image/svg+xml/svg-rasterize-to-bmp-b8g8r8a8-srgb.wasm` maps `image/svg+xml -> image/bmp`
- `components/image/jp2/jp2-to-bmp-b8g8r8a8-srgb.wasm` maps `image/jp2 -> image/bmp`
- `components/image/bmp/bmp-b8g8r8a8-icc-to-srgb.wasm` maps profiled `image/bmp -> image/bmp` and removes the source ICC profile
- `components/image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-rgba32float.wasm` maps 8-bit sRGB BGRA `image/bmp -> image/ktx2`
- `components/image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-r8g8b8a8-srgb.wasm` maps BMP BGRA bytes to canonical sRGB RGBA `image/ktx2`
- `components/image/ktx2/ktx2-r8g8b8a8-srgb-to-ktx2-rgba32float.wasm` maps canonical 8-bit sRGB KTX2 to linear RGBA32F KTX2
- `components/image/ktx2/ktx2-rgba32float-to-ktx2-r8g8b8a8-srgb.wasm` maps linear RGBA32F KTX2 to canonical 8-bit sRGB KTX2
- `components/image/webp/webp-to-ktx2-r8g8b8a8-srgb.wasm` decodes WebP directly to canonical 8-bit sRGB KTX2
- `components/image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-webp-lossless.wasm` encodes RGBA8 or BGRA8 sRGB KTX2 directly as lossless WebP
- `components/image/ktx2/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm` encodes canonical KTX2 directly as lossy WebP
- `components/image/png/png-to-ktx2-r8g8b8a8-srgb.wasm` decodes PNG directly to canonical 8-bit sRGB KTX2
- `components/image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-png.wasm` encodes RGBA8 or BGRA8 sRGB KTX2 directly as PNG
- `components/image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-avif-lossy.wasm` encodes RGBA8 or BGRA8 sRGB KTX2 directly as lossy AVIF
- `components/image/avif/avif-to-ktx2-r8g8b8a8-srgb.wasm` decodes a still AVIF directly to canonical 8-bit sRGB KTX2
- `components/image/jpeg/jpeg-to-ktx2-r8g8b8a8-srgb.wasm` decodes JPEG directly to canonical 8-bit sRGB KTX2
- `components/image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-jpeg-lossy.wasm` encodes RGBA8 or BGRA8 sRGB KTX2 directly as JPEG
- `components/image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm` rasterizes SVG directly to canonical 8-bit sRGB KTX2
- `components/image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-b8g8r8a8-srgb.wasm` wraps sRGB BGRA bytes as `VK_FORMAT_B8G8R8A8_SRGB image/ktx2`
- `components/image/ktx2/ktx2-rgba32float-look-warm-fade.wasm` applies a LUT in place to linear RGBA32F `image/ktx2`
- `components/image/ktx2/ktx2-rgba32float-to-bmp-b8g8r8a8-srgb.wasm` maps linear RGBA32F `image/ktx2 -> image/bmp`
- `components/image/ktx2/ktx2-b8g8r8a8-srgb-to-bmp-b8g8r8a8-srgb.wasm` unwraps sRGB BGRA KTX2 pixels as `image/bmp`
- `components/font/ttf/ttf-to-svg-paths-csv.wasm` maps `font/ttf -> text/csv`
- `components/font/ttf/ttf-to-svg-path-defs.wasm` maps `font/ttf -> image/svg+xml`
- `components/application/warc/warc-to-static-tar-no-trailing-slash.wasm` maps `application/warc -> application/x-tar`
- `components/application/x-tar/tar-to-zip.wasm` maps `application/x-tar -> application/zip`
- `components/application/zip/zip-to-tar.wasm` maps `application/zip -> application/x-tar`
- `components/text/text-to-og-image-svg-inter.wasm` maps `application/x-www-form-urlencoded -> image/svg+xml`
- `components/text/text-to-og-image-svg-dejavu-sans-mono.wasm` maps `application/x-www-form-urlencoded -> image/svg+xml`
- `components/application/zip/zip-list-entries-csv.wasm` maps `application/zip -> text/csv`
- `components/application/zip/zip-list-files-csv.wasm` maps `application/zip -> text/csv`
- `components/application/zip/zip-extract-file.wasm` maps one regular ZIP entry to `application/octet-stream`; select it with `?file_index=N`

Tradeoffs:

- BMP is larger than PNG/JPEG on disk, but excellent as an internal interchange format because it is straightforward to parse and transform.
- The repository's narrow KTX2 profiles store one uncompressed
  `VK_FORMAT_R8G8B8A8_SRGB` or `VK_FORMAT_R32G32B32A32_SFLOAT` image. Content
  components can address either payload directly. The float profile costs 16
  bytes per pixel. Neither profile accepts KTX2's compressed, mipmapped, array,
  or cubemap variants. See the
  [profile and components](https://github.com/royalicing/qip/blob/main/components/image/ktx2/README.md).
- Tar is straightforward to process sequentially and preserves Unix archive
  semantics. ZIP is more widely convenient at system boundaries; the
  `tar-to-zip` component uses DEFLATE per entry when it saves space and stores
  already-compressed data unchanged. `zip-to-tar` accepts bounded classic ZIP
  archives, decodes stored or DEFLATE bodies directly into TAR output, and
  uses PAX records for names or metadata that do not fit ustar fields. It
  rejects ZIP64, encrypted and split archives, special file types, and unsafe
  extraction paths.

  The ZIP listing components assign indices from central-directory order.
  `entry_index` counts every explicit archive entry, while `file_index` counts
  only regular files. This keeps `zip-extract-file.wasm -u file_index=0`
  pointed at the first file even when directory or symlink entries precede it.

## Image container names and pixel format names

An image component name describes a container, a pixel layout, and sometimes
a colour interpretation. `bmp-b8g8r8a8-srgb` describes a BMP file whose pixel
array has four 8-bit channels and whose colour channels are treated as sRGB.
By contrast, `B8G8R8A8_SRGB` without a container name is only a Vulkan pixel
format. It does not describe a complete file by itself.

```text
image/bmp: QIP BMP B8G8R8A8 sRGB

+----------------+------------------+-------------------------------+
| BMP file header| DIB header       | pixel array                   |
| "BM", offsets  | size, orientation| [B][G][R][A] [B][G][R][A]... |
+----------------+------------------+-------------------------------+
                                      8   8   8   8 bits = 32 bits

The signed BMP height controls whether rows are stored bottom-up or top-down.
The BMP headers and that row-order rule are part of `bmp-b8g8r8a8-srgb`.
```

```text
image/ktx2: QIP canonical KTX2 RGBA8 sRGB profile

+----------------+-------------+------------------+-----------------------+
| KTX2 header    | level index | DFD + metadata   | level pixel payload   |
| vkFormat = 43  | offset, size| colour + `rd`    | [R][G][B][A] ...      |
+----------------+-------------+------------------+-----------------------+
       |                                                     |
       +-- VK_FORMAT_R8G8B8A8_SRGB names these payload bytes-+

The KTX2 profile fixes rows to top-down, left-to-right (`KTXorientation=rd`).
```

The BMP adapters change the container, reverse bottom-up rows when needed, and
swap the red and blue byte positions:

```text
bmp-b8g8r8a8-srgb             ktx2-r8g8b8a8-srgb
BMP container                KTX2 container
BGRA, 8 bits per channel     VK_FORMAT_R8G8B8A8_SRGB
sRGB colour                  sRGB colour
top-down or bottom-up    --> canonical top-down (`rd`), RGBA
```

The floating-point adapters perform a colour and storage conversion instead:

```text
BMP [B,G,R,A] u8 sRGB  -->  KTX2 [R,G,B,A] f32 linear
     4 bytes per pixel          16 bytes per pixel
```

Use these naming rules for image components:

| Name fragment | It identifies | It does not identify |
| --- | --- | --- |
| `bmp-b8g8r8a8-srgb` | A complete BMP file, four 8-bit channels, and QIP's sRGB interpretation | A headerless pixel buffer |
| `bmp-b8g8r8a8-icc-to-srgb` | A BMP with an explicit source ICC profile that the component converts to sRGB | An already-sRGB input profile |
| `ktx2-r8g8b8a8-srgb` | A complete KTX2 file with QIP's canonical 8-bit sRGB Vulkan payload format | A BMP or a headerless Canvas `ImageData` buffer |
| `ktx2-b8g8r8a8-srgb` | A complete KTX2 file with the named alternate Vulkan payload format | QIP's canonical 8-bit KTX2 profile |
| `ktx2-rgba32float` | A complete KTX2 file with QIP's linear RGBA `f32` working profile | Tile-contract RGBA32Float memory |
| `b8g8r8a8-srgb` | A pixel format: four 8-bit channels and sRGB RGB values | Container headers, dimensions, row orientation, or mip levels |

The `-srgb` suffix records QIP's supported colour interpretation. It does not
claim that ordinary BMP headers identify sRGB reliably. Components that accept
this profile treat unprofiled colour channels as sRGB. A BMP with another
embedded profile must pass through `bmp-b8g8r8a8-icc-to-srgb` first.

The `bmp-` prefix says that the component exchanges a complete BMP file, so
`bmp-b8g8r8a8-srgb` does not imply a raw pixel buffer. `B8G8R8A8` spells out
the channel widths explicitly: four 8-bit channels and 32 bits per pixel.

## Raster conversion limits

Raster format converters use one decoded-image ceiling: 25,000,000 pixels,
with neither dimension above 8192 pixels. A 32-bit BMP at that ceiling needs
100,000,054 bytes including its header. BMP-consuming converters reserve an
additional 64 KiB for larger DIB headers and metadata.

Compressed PNG, JPEG, JPEG 2000, and WebP inputs have a separate 64 MiB byte
cap. That cap does not replace the pixel limit: a small compressed file that
expands beyond 25 MP is rejected before its pixel buffers are written.

These limits cost memory even for small conversions because the modules use
fixed Wasm memories. PNG decoding uses fixed scanline batches and reserves
about 162 MiB; its `simd128` fork uses the same memory with vectorized row
operations. BMP-to-PNG reserves about 332 MiB. It uses dynamic Huffman coding
while its filtered input fits an 8 MiB token buffer, then switches to fixed
Huffman coding for larger images. Both paths are lossless; the large-image path
may produce a larger PNG in exchange for bounded scratch memory.

`image/x-icon` remains a format-specific exception because this repository's
ICO component writes one BMP-backed image and the directory entry represents
at most 256×256 directly.

## Encodings

Formats and encodings are at different layers:

- Formats are container/file semantics (`image/svg+xml`, `application/warc`, `image/bmp`).
- Encodings are byte/value representations used within processing stages.

An exact format is also a component precondition or guarantee. A component
which accepts `image/png` may assume a valid PNG within its documented profile;
it does not have to validate the complete file again before expensive work.
Passing malformed bytes to that component breaks the caller contract and may
trap.

A file extension, HTTP `Content-Type`, or other untrusted label does not prove
that the bytes are valid. Validate at that boundary when later components need
to rely on the format. A pass-through PNG validator can accept arbitrary bytes,
export `failure_modes_per_input_offset`, reject malformed input, and expose the accepted bytes as
`image/png` without changing them:

```text
untrusted bytes -> validate PNG -> valid image/png -> expensive PNG transform
```

This avoids making every downstream PNG component repeat validation. A combined
validate-and-transform component is also valid; it accepts the wider byte
domain and reports malformed input through its `render` result. Recipes must not infer
validation only from a source's claimed MIME type.

`qip` currently supports these encodings:

- `UTF-8` for text pipelines (`input_utf8_cap` / `output_utf8_cap`)
- `RGBA32Float` for image filter tiles in `qip image` (`tile_rgba32float_64x64`)

UTF-8 is a valid subset of raw bytes, so a UTF-8 Content output may feed a
raw-bytes Content input. The reverse is rejected because arbitrary bytes are
not guaranteed to be valid UTF-8.

Hosts validate arbitrary bytes when they enter the UTF-8 domain. Components
with `input_utf8_cap` may then process the input as valid UTF-8 without checking
the encoding again. A successful `output_utf8_cap` result preserves the
guarantee for later UTF-8 stages. Debug and Compliance hosts may rescan output
to detect a broken component, but normal pipeline execution does not require a
scan between known-valid components.

RGBA32Float tiles are not a subtype of Content bytes even though their storage
lives in Wasm linear memory. A mixed run pipeline crosses that boundary only
through the host's explicit image bridge: `image/bmp` raw bytes are decoded to
RGBA32Float tiles for a contiguous Tile group, then encoded back to
`image/bmp` raw bytes for the next Content step.
- `RGBA8 sRGB` for interactive frame output ([Interactive Component Contract](/docs/interactive-component))

Why these defaults:

- UTF-8 is the default, broadly interoperable text encoding. It is much easier to process than alternatives like UTF-16.
- RGBA32Float preserves precision during chained image transforms and maps cleanly to GPU/shader-style workflows.
- RGBA8 sRGB is the practical interop default for event-driven UI frames, especially for canvas-style rendering paths.

## Quick Decision Guide

If you need:

- One file that represents many files: use `application/x-tar`
- A compressed archive for download or desktop tools: use `application/zip`
- A snapshot of routed web output: use `application/warc`
- Vector graphics interchange: use `image/svg+xml`
- Simple raster interchange between components: use `image/bmp`
- General 8-bit sRGB Content images: use the repository's narrow `image/ktx2` `VK_FORMAT_R8G8B8A8_SRGB` profile
- Chained Content image transforms that need linear floating-point pixels: use the repository's narrow `image/ktx2` RGBA32F profile
- General text transforms: use `UTF-8` components in `components/text/`
- Image filter pipelines: use `RGBA32Float` via `qip image`

## When not to use these defaults

- Use richer app-specific formats only when their extra semantics are required.
- Keep component boundaries on simple formats, then adapt at ingress/egress.
- Use PNG/JPEG/WebP at system edges where compression is the priority.
