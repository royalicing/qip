# Module Contract Guide

This guide documents the contract `qip` expects for modules, and how it passes input in and reads output back.

## Quick Model

- A `.wasm` module file can be tiny, while instances’ initial linear memory can be much larger.
- WebAssembly memory is broken into multiple pages, where each page is `64 KiB` each.
- `qip` writes input into module memory, calls `render`, then reads output from module memory.

## Render Mode Contract

In `qip run`, modules can export pointer/cap values as either:

- zero-arg functions returning `i32` (common with Zig & C), or
- `i32` globals (common with `.wat`)

`qip` accepts both styles.

Required input exports:

- `input_ptr`
- one of `input_utf8_cap` or `input_bytes_cap`

Optional output exports:

- `output_ptr`
- one of `output_utf8_cap`, `output_bytes_cap`, or `output_i32_cap`

Required function:

- `render(input_size) -> output_size`

If `output_ptr` + output cap are not exported, `qip` falls back to printing `Ran: <run_return_value>`.

### Optional Uniforms (`uniform_set_<key>`)

Modules may export uniform setter functions and callers can pass values via query args.

Uniform export contract:

- Name must be `uniform_set_<key>` where `<key>` matches the query key.
- Setter must accept exactly one parameter.
- Supported parameter types are: `i32`, `i64`, `f32`, `f64`.
- Setter return value is ignored by `qip` (you can still return the clamped/applied value).
- Exception: image modules may also export `uniform_set_width_and_height(f32, f32)`; this is host-managed and not set via query args.

Host behavior:

- Uniforms are applied after module instantiation and before `render(...)` (or before tile execution in image mode).
- If a query key is provided but the module does not export `uniform_set_<key>`, execution fails.
- If parsing fails for the expected numeric type, execution fails.
- Integer uniforms (`i32`, `i64`) parse decimal as signed values by default.
- For integer uniforms, hexadecimal is accepted only when prefixed with `0x` (or `0X`) and is parsed as an unsigned bit pattern.
- Uniform keys are applied in sorted key order; do not rely on setter call order for dependent state changes.

CLI syntax:

- Put uniform query args immediately after the module path.
- Quote the full query arg in shells so `&` is not treated as a command separator.
- `qip run ... module.wasm '?key=value'`
- `qip run ... module.wasm '?width=900&height=400&font_size=48'`
- `qip image ... module.wasm '?key=value&other=1.5'`
- Multiple query args may follow the same module path and are merged.

Examples:

```bash
# i32 uniform
qip run modules/utf8/text-to-bmp.wasm '?cols=120'

# f32 uniforms
qip image -i in.jpg -o out.png modules/rgba/color-halftone.wasm '?max_radius=2.0&angle_c=0.26'

# packed 32-bit RGBA passed as hexadecimal (0xRRGGBBAA)
qip run modules/image/svg+xml/svg-recolor-current-color.wasm '?color_rgba=0xff5511ff'
```

Zig example:

```zig
var color_rgba: u32 = 0x000000FF;

// For wasm i32 uniforms, qip maps 0x-prefixed values as raw 32-bit bits.
export fn uniform_set_color_rgba(v: u32) u32 {
    color_rgba = v;
    return color_rgba;
}
```

## WebAssembly Module Contract

### `input_utf8_cap` / `input_bytes_cap`

Use `input_utf8_cap` for UTF-8 text input and `input_bytes_cap` for binary input.

### `output_utf8_cap` / `output_bytes_cap` / `output_i32_cap`

Use `output_utf8_cap` for UTF-8 text output, `output_bytes_cap` for binary output, and `output_i32_cap` for `i32[]` output.

If output exports are omitted, the return value of `render` is used as the result.

If output exports are present, the return value of `render` is used as the output size.

### Optional Content Type Metadata

Run modules may optionally export content type metadata for friendlier composition and host `Content-Type` selection.

- `input_content_type_ptr` / `input_content_type_size`
- `output_content_type_ptr` / `output_content_type_size`

Rules:

- These exports are optional. Omit them when content type is unknown or intentionally generic.
- Export exactly one MIME type value when present.
- Do not use media ranges (for example, `text/*` or `*/*`).
- Do not use comma-separated MIME lists.
- Omit input content type for modules that accept any UTF-8 text regardless of media type (for example: plain text, HTML, XML).
- Omit output content type for generic raw bytes and `i32[]` outputs unless the module guarantees a specific media type.
- Do not export `text/plain` for generic UTF-8 modules; `input_utf8_cap` / `output_utf8_cap` already imply plain UTF-8 text.
- Export content type when the module knows it exactly (for example: `text/javascript`, `text/html`, `image/bmp`).
- Export only the media type value. Do not append `charset=utf-8`; UTF-8 is already implied by `input_utf8_cap` / `output_utf8_cap`.
- If the host/caller provides an initial content type, treat it as authoritative for composition.
- For direct user ingress in `qip run` (stdin or `-i` file bytes), there is currently no separate content-type channel; trust user intent for the first stage.

### Content Type Composition Semantics

These are the composition rules for render-module pipelines:

- The pipeline starts with an optional initial content type from the caller/host context.
- For direct user ingress in `qip run`, when initial content type is absent, the first module is allowed by user intent (stdin/`-i` is trusted as the expected type).
- If a module exports `input_content_type_ptr`/`input_content_type_size`, the incoming content type must exactly match that MIME type.
- If a module does not export input content type and uses `input_utf8_cap`, it is treated as a generic UTF-8 transform and may compose with any UTF-8 pipeline input.
- If a module does not export input content type and uses `input_bytes_cap`, it is treated as a generic bytes transform and may compose with any bytes pipeline input.
- If a module exports `output_content_type_ptr`/`output_content_type_size`, that MIME type becomes the pipeline content type for downstream stages.
- If a module does not export output content type and uses `output_utf8_cap`, the existing pipeline content type is preserved.
- If a module does not export output content type and uses `output_bytes_cap`, the existing pipeline content type is preserved.
- Generic UTF-8 utility modules (for example, uppercase/trim/rewrite helpers) should usually omit content type metadata so they can run on any UTF-8 text while preserving upstream content type.
- Generic bytes utility modules (for example, `base64-encode.wasm` style byte transforms) should usually omit content type metadata so they can run on any bytes while preserving upstream content type.
- Example: `curl ... | qip run modules/text/html/html-link-extractor.wasm` composes by trusting user-provided stdin for the first stage (`text/html` expected by the module).

## Input/Output Semantics

Input:

- `qip` ensures `len(input) <= input_*_cap`.
- Input bytes are written to memory at `input_ptr`.
- If input is larger than cap, execution fails with `Input is too large`.

Output:

- `render` return value is interpreted as element count.
- For UTF-8 or raw bytes output, element size is `1` byte.
- For `output_i32_cap`, element size is `4` bytes aka `32` bits.
- `qip` checks returned count does not exceed exported output cap.

Capacity units:

- `input_utf8_cap`, `input_bytes_cap`, `output_utf8_cap`, `output_bytes_cap`: bytes.
- `output_i32_cap`: number of `i32` items.

## Memory Layout Recommendations

- Keep input and output buffers disjoint.
- Validate `input_size` and trap on out-of-bounds assumptions drifting between host and module.
- Reserve explicit scratch space if needed.
- Preferred for data-preserving transforms: trap on invalid input/overflow so bad data does not silently become empty output.
- Prefer trapping over silent truncation when output buffers fill.
- Use `return 0` only when empty output is an intentional, non-error result.

## Image Mode Memory

For `qip image` / RGBA filters:

- Required: `input_ptr`, `input_bytes_cap`, `tile_rgba_f32_64x64`.
- Host writes tile data into memory at `input_ptr`.
- Filter runs in-place and host reads back from the same buffer.

Tile byte size:

`tile_bytes = tile_span * tile_span * 4 channels * 4 bytes(float32)`

Where:

- `tile_span = 64` without halo.
- `tile_span = 64 + 2 * halo` with halo.

If any stage exports `calculate_halo_px` with `halo > 0`, host uses the full-image float32 pipeline for all stages in the contiguous image block.

See also: `IMAGE.md`.

## Practical Checklist

- Verify your exported caps match actual writable memory.
- Test both normal and oversized input.
- Check module trap behavior for malformed/oversized input.
