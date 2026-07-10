# QIP Component Contract

There are four types of QIP components:

- `Content`: receive input of any type and render output of any type
- `Interactive`: receive user events and render pixels in a loop
- `Tile`: receive a 64x64 tile of pixels and output another 64x64 tile
- `Form`: receive multiple user input and output optional errors and a final result of any type

## `Content` contract

- `memory`
- Input:
  - `input_ptr(): i32` — the offset within `memory` the host will write input to.
  - Either `input_utf8_cap(): i32` or `input_bytes_cap(): i32` — the maximum bytes the host can write as input.
  - Optional `input_content_type_ptr(): i32` and `input_content_type_size(): i32` — the MIME type of the input e.g. `text/markdown`.
- Output:
  - `output_ptr(): i32` — the offset within `memory` the module will write output to, which the host will then read. The host _must_ call the `render()` function first before calling `output_ptr()`.
  - Either `output_utf8_cap(): i32` or `output_bytes_cap(): i32` — the maximum bytes the `render()` function can return.
  - Optional `output_content_type_ptr(): i32` and `output_content_type_size(): i32` — the MIME type of the output e.g. `text/html`.
- `render(input_size: i32): i32` — transforms the input into output, returning the number of bytes output.

Hosts may call `render(...)` more than once on the same component instance. Each call is a new render request using the bytes currently written at `input_ptr()` and the component's current uniform state.

Component authors should make repeated renders deliberate:

- Treat `input_ptr()` memory as host-owned input for the duration of each call.
- Return the byte length for the current output, not a cumulative length.
- Expect `output_ptr()` to be read after each successful `render(...)`.
- Keep any internal cache or scratch state consistent when input bytes or uniforms change between calls.
- Trap on invalid input or output overflow rather than preserving a stale previous output.

This allows browser hosts to keep one module instance alive and render many inputs through it. It also allows wrappers to set uniforms immediately before each render without reinstantiating the component.

### Content-Type Metadata (Optional)

Content components may optionally export content-type metadata for friendlier composition and host `Content-Type` selection.

- `input_content_type_ptr` / `input_content_type_size`
- `output_content_type_ptr` / `output_content_type_size`

Rules:

- These exports are optional. Omit them when content type is unknown or intentionally generic.
- Export exactly one MIME type value when present.
- Do not use media ranges (for example, `text/*` or `*/*`).
- Do not use comma-separated MIME lists.
- Omit input content type for components that accept any UTF-8 text regardless of media type (for example: plain text, HTML, XML).
- Omit output content type for generic raw bytes unless the module guarantees a specific media type.
- Do not export `text/plain` for generic UTF-8 components; `input_utf8_cap` / `output_utf8_cap` already imply plain UTF-8 text.
- Export content type when the module knows it exactly (for example: `text/javascript`, `text/html`, `image/bmp`).
- Export only the lowercase media type value. Do not include whitespace, media ranges, comma-separated lists, or parameters such as `charset=utf-8`; UTF-8 is already implied by `input_utf8_cap` / `output_utf8_cap`.
- Hosts compare content type strings exactly. They do not trim, lowercase, or strip parameters.
- If the host/caller provides an initial content type, treat it as authoritative for composition.
- For direct user ingress in `qip run` (stdin or `-i` file bytes), there is currently no separate content-type channel; trust user intent for the first stage.

### Content-Type Composition

These are the composition rules for QIP component pipelines:

- The pipeline starts with an optional initial content type from the caller/host context.
- For direct user ingress in `qip run`, when initial content type is absent, the first component is allowed by user intent (stdin/`-i` is trusted as the expected type).
- If a component exports `input_content_type_ptr`/`input_content_type_size`, the incoming content type must exactly match that MIME type.
- If a component does not export input content type and uses `input_utf8_cap`, it is treated as a generic UTF-8 transform and may compose with any UTF-8 pipeline input.
- If a component does not export input content type and uses `input_bytes_cap`, it is treated as a generic bytes transform and may compose with any bytes pipeline input.
- If a component exports `output_content_type_ptr`/`output_content_type_size`, that MIME type becomes the pipeline content type for downstream stages.
- If a component does not export output content type and uses `output_utf8_cap`, the existing pipeline content type is preserved when the component also reads UTF-8 input (`input_utf8_cap`). When it reads bytes (`input_bytes_cap`), its output is new text and the pipeline content type becomes unspecified.
- If a component does not export output content type and uses `output_bytes_cap`, the existing pipeline content type is preserved.

### Memory Recommendations

- Keep input and output buffers disjoint unless overlap is an intentional and tested optimization.
- Validate `input_size` and trap on out-of-bounds assumptions drifting between host and component.
- Reserve explicit scratch space if needed.
- For Zig components, compile with `--max-memory=<bytes>` so the Wasm memory has an explicit maximum. See [Writing QIP Components In Zig](/docs/zig-components) and [Hard Limits](/docs/hard-limits).
- Preferred for data-preserving transforms: trap on invalid input/overflow so bad data does not silently become empty output.
- Prefer trapping over silent truncation when output buffers overfill.
- Use `return 0` only when empty output is an intentional, non-error result.

## `Interactive` contract

- `memory`
- `render(input_size: i32): i32` must accept `0` and return the frame byte count.
- Events:
  - Optional `key_event(x11_key: i32, flags: i32, now_ms: i64)`
  - Optional `pointer_event(button_mask: i32, x_px: i32, y_px: i32, now_ms: i64)`
  - `tick(now_ms: i64): i64` returns the timestamp when to call `tick()` next, or `0`.
- Output:
  - `output_ptr(): i32` allow frame pixel bytes to be read.
  - `output_rgba8_srgb_bytes(): i32` is the exact frame byte count.
  - `render_width_px(): i32`
  - `render_height_px(): i32`
  - It is expected that: `output_rgba8_srgb_bytes == render_width_px * render_height_px * 4`.

### Pixel format

- `rgba8_srgb` in byte order `[R, G, B, A]`.
- Colorspace is sRGB with 2.2 gamma.
- Top-left origin, row-major.
- Tight rows with no padding: `stride = width * 4`.
- Alpha is straight/unassociated.

### Input events

- Event handlers return `1` when visible state changed and a frame should be rendered.
- Event handlers return `0` when no render is needed, such as pointer movement without hover effects.
- For static output, `tick` may return `0`.

## `Tile` contract

- `memory`
- `input_ptr(): i32`
- `tile_rgba32float_64x64(f32 tile_x, f32 tile_y)`
- Optional: `calculate_halo_px(): i32`
- Optional: `uniform_set_width_and_height(width: f32, height: f32)`

Use `Tile` for `qip image` filter pipelines.

Required:

- `input_ptr`, `input_bytes_cap`, `tile_rgba32float_64x64`

Optional:

- `uniform_set_width_and_height(f32, f32)`
- `calculate_halo_px() -> i32`

Tile memory:

`tile_bytes = tile_span * tile_span * 4 channels * 4 bytes(float32)`

Where:

- `tile_span = 64` without halo
- `tile_span = 64 + 2 * halo` with halo

If any stage reports `halo > 0`, host uses the full-image float32 pipeline for all stages in the contiguous tile block.

See also: `IMAGE.md`.

## `Form` contract

- See [docs/form_abi.md](/docs/form_abi) for the full required export list.

Export style notes:

- Pointer/size values may be exported as zero-arg functions returning `i32` or as `i32` globals.
- Function-style exports are preferred, including in `.wat`; global-style remains supported for legacy components.

## Contract Detection

Detecting which contract a wasm module conforms to is a deterministic process of checking exports.

1. `qip run` with exactly one component tries `Interactive` first-frame handling first.
2. If that does not match, normal pipeline building starts.
3. During pipeline building, any component exporting `tile_rgba32float_64x64` is classified as `Tile`.
4. Non-tile components are classified as `Content`.
5. `qip form` uses the `Form` contract path.

Example:

- A component with `tile_rgba32float_64x64` is treated as `Tile` in pipeline composition, even if it also exports `render(...)`.

## Optional Uniforms (`uniform_set_<key>`)

Components may export uniform setter functions and callers can pass values via query args.

Uniform export contract:

- Name must be `uniform_set_<key>` where `<key>` matches the query key.
- Setter must accept exactly one parameter.
- Supported parameter types are: `i32`, `i64`, `f32`, `f64`. `i32` is treated as unsigned, if you want a signed integer use `i64`.
- Setter should return the clamped/applied value.
- Image components may also export `uniform_set_width_and_height(f32, f32)`; this is host-managed and not set via query args.

Host behavior:

- Uniforms are applied after module instantiation and before `render(...)` (or before tile execution in image mode).
- Hosts may call uniform setters again before later `render(...)` calls on the same instance.
- If a query key is provided but the component does not export `uniform_set_<key>`, execution fails.
- If parsing fails for the expected numeric type, execution fails.
- For integer uniforms, hexadecimal is accepted only when prefixed with `0x` (or `0X`) and is parsed as an unsigned bit pattern.
- Uniform keys are applied in sorted key order; do not rely on setter call order for dependent state changes.

CLI syntax:

- Put uniform query args immediately after the component path.
- In shells quote the full query arg so `&` is not treated as a command separator.
- `qip run ... module.wasm '?key=value'`
- `qip run ... module.wasm '?width=900&height=400&font_size=48'`
- `qip image ... module.wasm '?key=value&other=1.5'`

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

## Form Set Contract

Use `Form` for prompt-driven workflows in `qip form`.

Form logic should stay explicit and host-cooperative so prompt progression and validation behave predictably across CLI and web hosts.

For required exports and flow details, see [docs/form_abi.md](/docs/form_abi).

## Intersections

`Content` and `Interactive`:

- They share `render(...)`, but target different host paths.
- In single-component `qip run`, matching `Play` exports are handled as play first-frame output.

`Content` and `Tile`:

- If `tile_rgba32float_64x64` is exported, pipeline classification treats the component as `Tile`.
- Keep combined `Content+Tile` components only when you intentionally want tile classification.

## Hard Limits

This interface is the first layer of compatibility. A component should not assume unbounded
memory, long-running execution, host imports, filesystem access, network access,
or a larger runtime around it. See [Hard Limits](/docs/hard-limits) for the
runtime limits component authors should keep in mind after implementing the QIP
interface.

## Future Direction: Numeric Arrays And Tensors

QIP used to allow exporting `output_i32_cap`, but we removed it from the current alpha.

The potential approach is array-shaped data: byte histograms, RGB histograms, line-offset tables, batched CRC results, image masks, label matrices, and quantized spectra. Those outputs are naturally numeric collections, not strings of bytes that happen to contain numbers.

When we revisit this, we should separate three concerns:

- Element type: `i32`, `u8`, `f32`, or a SIMD lane type.
- Logical shape: rank and dimensions, such as `[256]`, `[3, 256]`, or `[height, width, bands]`.
- Physical layout: dense row-major by default, with room for strides, row alignment, tiling, or planar/interleaved choices later.

Mojo is useful prior art here because it treats scalar numerics as one-lane SIMD values while keeping tensor shape separate from memory layout. That points to a better QIP design than a one-off `i32[]`: start with SIMD-aware element types, then make shape and layout explicit enough for hosts and compilers to optimize without guessing.
