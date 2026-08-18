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
- `components/image/svg+xml/svg-rasterize.wasm` maps `image/svg+xml -> image/bmp`
- `components/image/jp2/jp2-to-bmp-bgra32.wasm` maps `image/jp2 -> image/bmp`
- `components/image/bmp/bmp-bgra32-icc-to-srgb.wasm` maps profiled `image/bmp -> image/bmp` and removes the source ICC profile
- `components/font/ttf/ttf-to-svg-paths-csv.wasm` maps `font/ttf -> text/csv`
- `components/font/ttf/ttf-to-svg-path-defs.wasm` maps `font/ttf -> image/svg+xml`
- `components/application/warc/warc-to-static-tar-no-trailing-slash.wasm` maps `application/warc -> application/x-tar`
- `components/application/x-tar/tar-to-zip.wasm` maps `application/x-tar -> application/zip`
- `components/application/zip/zip-to-tar.wasm` maps `application/zip -> application/x-tar`
- `components/utf8/text-to-og-image-svg-inter.wasm` maps `application/x-www-form-urlencoded -> image/svg+xml`
- `components/utf8/text-to-og-image-svg-dejavu-sans-mono.wasm` maps `application/x-www-form-urlencoded -> image/svg+xml`
- `components/application/zip/zip-list-entries-csv.wasm` maps `application/zip -> text/csv`
- `components/application/zip/zip-list-files-csv.wasm` maps `application/zip -> text/csv`
- `components/application/zip/zip-extract-file.wasm` maps one regular ZIP entry to `application/octet-stream`; select it with `?file_index=N`

Tradeoffs:

- BMP is larger than PNG/JPEG on disk, but excellent as an internal interchange format because it is straightforward to parse and transform.
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

`qip` currently supports these encodings:

- `UTF-8` for text pipelines (`input_utf8_cap` / `output_utf8_cap`)
- `RGBA32Float` for image filter tiles in `qip image` (`tile_rgba32float_64x64`)

UTF-8 is a valid subset of raw bytes, so a UTF-8 Content output may feed a
raw-bytes Content input. The reverse is rejected because arbitrary bytes are
not guaranteed to be valid UTF-8.

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
- General text transforms: use `UTF-8` components in `components/utf8/`
- Image filter pipelines: use `RGBA32Float` via `qip image`

## When not to use these defaults

- Use richer app-specific formats only when their extra semantics are required.
- Keep component boundaries on simple formats, then adapt at ingress/egress.
- Use PNG/JPEG/WebP at system edges where compression is the priority.
