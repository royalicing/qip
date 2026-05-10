# Interactive ABI

This ABI is for stateful, event-driven modules that render an output frame. We prefer a small host/module contract over protocol complexity: send key and pointer events directly, advance state with `tick`, then pull pixels with `render_output`.

The design goal is practical interoperability: browser and native hosts can adapt input to this ABI, and modules stay tiny.

## Core Contract

Required exports:

- `memory`
- `output_ptr() -> i32`
- `output_bytes_cap() -> i32`
- `key_event(x11_key: i32, flags: i32) -> i32`
- `pointer_event(button_mask: i32, x_px: i32, y_px: i32) -> i32`
- `tick(now_ms: i32) -> i32`
- `render_output() -> i32`

### Output Format

- Pixel format is fixed: RGBA8 bytes in memory order `[R, G, B, A]`.
- Output is row-major, top-left origin, tightly packed.
- Total bytes for a full frame: `render_width_px * render_height_px * 4`.

Little-endian note:

- Hosts that view pixels as `u32` will see each pixel as `0xAABBGGRR` on little-endian systems.
- For portability, treat output as byte-addressed RGBA8, not host-endian `u32` values.

### Event Semantics

`key_event(...)`:

- `x11_key` uses X11 keysym values (aligned with RFB `KeyEvent` semantics).
- `flags` is a bitfield:
  - `bit 0`: key down (`1`) / key up (`0`)
  - `bit 1`: repeat
  - `bit 2`: shift
  - `bit 3`: ctrl
  - `bit 4`: alt
  - `bit 5`: meta
- Return `1` when accepted, `0` when ignored.

`pointer_event(...)`:

- `button_mask` follows RFB-style pointer button mask semantics.
- `x_px` and `y_px` are integer pixel coordinates in current render space.
- Return `1` when accepted, `0` when ignored.

### Tick + Render Flow

We intentionally split simulation from rendering.

- `tick(now_ms)` advances state.
- `render_output()` writes/returns output bytes from current state.

`tick(now_ms)` return value:

- `0`: no visual change (host may skip `render_output()`)
- `1`: output changed (host should call `render_output()`)

This dirty bit pattern is common in interactive systems and helps avoid unnecessary redraw work.

Time source requirements:

- `now_ms` should be monotonic time in milliseconds.
- Hosts should call `tick(0)` first, then pass elapsed milliseconds since that start tick.
- Do not use wall-clock time for simulation.

## Sizing Variants

Use the same core ABI for both variants.

## Static Size Variant

Module decides size at instantiation and keeps it fixed.

Additional required exports:

- `render_width_px() -> i32`
- `render_height_px() -> i32`

Rules:

- Size does not change during instance lifetime.
- Host validates `output_bytes_cap() >= render_width_px()*render_height_px()*4`.

## Dynamic Size Variant

Host/user can request size changes within declared limits.

Additional required exports:

- `render_width_px() -> i32`
- `render_height_px() -> i32`
- `render_max_width_px() -> i32`
- `render_max_height_px() -> i32`
- `render_resize(width_px: i32, height_px: i32) -> i32`

Rules:

- `render_resize(...)` returns `1` on success, `0` on rejection.
- Rejection should be used for out-of-range or unsupported sizes.
- Width/height getters must reflect current active size.
- Host validates capacity after resize using current size.

## Host Loop Pattern

Typical host flow:

1. Deliver input as it arrives via `key_event(...)` / `pointer_event(...)`.
2. On frame callback (for example `requestAnimationFrame`), call `tick(now_ms)`.
3. If `tick` returns `1`, call `render_output()` and read `output_ptr()` bytes.

This gives low-latency input handling while keeping frame scheduling host-driven.

## Why This Shape

Claim: this ABI is a better default than embedding a full protocol stream.

Reason:

- It keeps wasm modules free of packet parsing logic.
- It aligns with familiar game/UI separation (`tick` then render).
- It composes with multiple hosts (browser/native) by adapting input at the edge.

Tradeoff:

- You lose protocol-level extensibility in v1.
- If batching or replay is needed later, add an optional batched event API in a future version without breaking this core.
