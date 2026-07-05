# Interactive ABI

This ABI is for stateful, event-driven modules that render an output frame. We prefer a small host/module contract over protocol complexity: send key and pointer events directly, advance state with `tick`, then pull pixels with `render(input_size)`.

The design goal is practical interoperability: browser and native hosts can adapt input to this ABI, and modules stay tiny.

## Core Contract

Required exports:

- `memory`
- `output_ptr() -> i32`
- `output_rgba8_srgb_bytes() -> i32`
- `key_event(x11_key: i32, flags: i32, now_ms: i64) -> i32`
- `pointer_event(button_mask: i32, x_px: i32, y_px: i32, now_ms: i64) -> i32`
- `tick(now_ms: i64) -> i64`
- `render(input_size: i32) -> i32`
  - If no input bytes are being passed for this frame, host must pass `0`.
  - The ABI uses one fixed signature to avoid per-runtime export arity/type branching.

### Output Format

- Pixel format is fixed: color component bytes in memory order `[R, G, B, A]`.
- Output is row-major, top-left origin, tightly packed.
- Stride is fixed: `bytes_per_row = render_width_px * 4` (no row padding).
- Alpha is straight (not premultiplied) in module memory.
- Colors are in sRGB colorspace with 2.2 gamma.
- Total bytes for a full frame: `render_width_px * render_height_px * 4`.

Little-endian note:

- Hosts that view pixels as `u32` will see each pixel as `0xAABBGGRR` on little-endian systems.
- For portability, treat output as byte-addressed RGBA8, not host-endian `u32` values.

### Rendering Target Interop

We chose `rgba8_srgb` with `stride = width * 4` for direct compatibility with browser `<canvas>` 2D context’s `putImageData()`, which expects RGBA bytes in that logical order.
- WebGL: ABI bytes map to standard RGBA8 upload paths, e.g. `RGBA + UNSIGNED_BYTE`.
- WebGPU: canvas surface may prefer `bgra8unorm`/`bgra8unorm-srgb`; conversion may happen in the renderer.
- Native runtimes can convert once at the edge, for example they may prefer premultiplied BGRA with aligned stride.

### Event Semantics

`key_event(...)`:

- `x11_key` uses X11 keysym values (aligned with VNC Remote Framebuffer `KeyEvent` semantics).
- `flags` is a bitfield:
  - `bit 0`: key down (`1`) / key up (`0`)
  - `bit 1`: repeat
  - `bit 2`: shift
  - `bit 3`: ctrl
  - `bit 4`: alt
  - `bit 5`: meta
- `now_ms` is monotonic elapsed milliseconds (`i64`) from the same timeline used by `tick(now_ms)`.
- Return `1` when accepted, `0` when ignored.

`pointer_event(...)`:

- `button_mask` uses only the low 3 bits: primary=`1`, middle=`2`, secondary=`4`.
- `x_px` and `y_px` are integer pixel coordinates in current render space.
- `now_ms` is monotonic elapsed milliseconds (`i64`) from the same timeline used by `tick(now_ms)`.
- Return `1` when accepted, `0` when ignored.

### Tick + Render Flow

We intentionally split simulation from rendering.

- `tick(now_ms)` advances state.
- `render(input_size)` writes out output bytes using current state.

`tick(now_ms)` return value:

- `0`: no scheduled wakeup needed
- `>0`: absolute next wake timestamp (`next_wake_at_ms`) in the same monotonic timeline as `now_ms`

Time source requirements:

- `now_ms` should be monotonically-increasing time in milliseconds.
- Hosts should call `tick(0)` first, then pass current monotonic elapsed milliseconds.
- Do not use wall-clock time for simulation as it is likely not monotonic.

## Sizing Variants

Use the same core ABI for both variants.

## Static Size Variant

Module decides size at instantiation and keeps it fixed.

Additional required exports:

- `render_width_px() -> i32`
- `render_height_px() -> i32`

Rules:

- Size does not change during instance lifetime.
- Host validates `output_rgba8_srgb_bytes() == render_width_px()*render_height_px()*4`.

## Host Loop Pattern

Typical host flow:

1. Deliver input as it arrives via `key_event(...)` / `pointer_event(...)`.
2. Call `tick(now_ms)` when input is ready to apply, or when host time reaches `next_wake_at_ms`.
3. Call `render(0)` after each tick that was run, then read `output_ptr()` bytes.
4. Schedule the next host wake from the returned `next_wake_at_ms` (if non-zero) and pending input times.

This gives low-latency input handling while keeping frame scheduling host-driven.

## Browser Presentation

The interactive ABI describes framebuffer pixels, not CSS layout. Browser hosts can scale a fixed framebuffer at presentation time.

For `<qip-play>`, the page can set presentation attributes:

- `canvas-width`: CSS width for the internal canvas.
- `canvas-height`: CSS height for the internal canvas, default `auto`.

The same sizing values can also come from CSS custom properties when a page wants layout to live in stylesheets:

- `--qip-play-canvas-width`: CSS width for the internal canvas.
- `--qip-play-canvas-height`: CSS height for the internal canvas, default `auto`.

Attributes win over CSS custom properties.

`<qip-play>` leaves `image-rendering` at the browser default. That is the better default for high-DPI downscaling, and 1:1 rendering is unaffected.

Pointer events are still converted from the displayed canvas box into render-space pixels. This lets a component render a 2x backing buffer, while the page displays it at a 1x CSS size for high-DPI screens.

For debug instrumentation, add `debug` to `<qip-play>`. In debug mode the host compares each rendered framebuffer with the previous frame, reports `unchanged renders`, and shows the latest exact-compare time. This is opt-in because scanning the framebuffer can be as expensive as, or more expensive than, drawing it to the canvas.

## Why This Shape

This ABI keeps packet parsing out of the Wasm module. Hosts adapt browser or native input at the edge, then modules handle a familiar game/UI loop: receive input events, advance state with `tick`, and render the current frame.
