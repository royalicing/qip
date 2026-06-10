# Formats and Encodings

`qip` intentionally chooses old, boring, open formats:

- Simpler parsing and fewer edge cases.
- Broad ecosystem of existing tooling.
- Easier for coding agents to generate correct implementations.
- Likely to still work in 10+ years.
- Reduced lock-in to proprietary systems.

For qip's one-input/one-output component model, stable interchange formats make QIP components more reusable.

## Preferred formats

Current formats directly supported by a qip command or supported by this repo’s modules in `modules/`:

- `application/warc`: website snapshots
- `application/x-tar`: directory archive as one input/output blob
- `image/bmp`: simple uncompressed raster interchange
- `image/svg+xml`: vector graphics that work great with LLMs
- `image/x-icon`
- `image/gif`
- `text/markdown`
- `text/html`
- `text/javascript`
- `text/x-c`
- `application/vnd.sqlite3`
- `application/xml`

Examples:

- `qip router warc ...` emits `application/warc`
- `modules/image/svg+xml/svg-rasterize.wasm` maps `image/svg+xml -> image/bmp`
- `modules/application/warc/warc-to-static-tar-no-trailing-slash.wasm` maps `application/warc -> application/x-tar`

Tradeoffs:

- BMP is larger than PNG/JPEG on disk, but excellent as an internal interchange format because it is straightforward to parse and transform.
- Tar is uncompressed; in the future we might pair it with compression.

## Encodings

Formats and encodings are at different layers:

- Formats are container/file semantics (`image/svg+xml`, `application/warc`, `image/bmp`).
- Encodings are byte/value representations used within processing stages.

`qip` currently supports these encodings:

- `UTF-8` for text pipelines (`input_utf8_cap` / `output_utf8_cap`)
- `RGBA32Float` for image filter tiles in `qip image` (`tile_rgba32float_64x64`)
- `RGBA8 sRGB` for interactive frame output (`docs/interactive`)

Why these defaults:

- UTF-8 is the default, broadly interoperable text encoding. It is much easier to process than alternatives like UTF-16.
- RGBA32Float preserves precision during chained image transforms and maps cleanly to GPU/shader-style workflows.
- RGBA8 sRGB is the practical interop default for event-driven UI frames, especially for canvas-style rendering paths.

## Quick Decision Guide

If you need:

- One file that represents many files: use `application/x-tar`
- A snapshot of routed web output: use `application/warc`
- Vector graphics interchange: use `image/svg+xml`
- Simple raster interchange between components: use `image/bmp`
- General text transforms: use `UTF-8` components in `modules/utf8/`
- Image filter pipelines: use `RGBA32Float` via `qip image`

## When not to use these defaults

- Use richer app-specific formats only when their extra semantics are required.
- Keep component boundaries on simple formats, then adapt at ingress/egress.
- Use PNG/JPEG/WebP at system edges where compression is the priority.
