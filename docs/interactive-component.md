# Interactive Component Contract

An Interactive component is a Content component that retains state and accepts
events over time. It uses the [Timed and Eventful Component
Contract](/docs/timed-and-eventful-components): Content rendering creates the
initial presentation, updates advance state, and a later render publishes that
state.

All components in `components/interactive/` use this contract.

Use the [Content Component Contract](/docs/content-component) when each call is
a finite input-to-output transformation and no state must survive for a later
event or time update.

Time does not imply interaction. A Timed component can omit all event exports.
The GIF player is the repository example: its initial `image/gif` render can
reject invalid input, and later updates select frames at their GIF
deadlines. Keyboard and pointer input would add no useful capability, so the
player stops at Timed. Eventful applications and games add the event functions
defined below.

## Required Shape

An Interactive component has the Content memory and output exports, plus:

```text
begin_update_at(now_ms: i64)
finish_update() -> i64
```

It also exports one or more event functions. The common input functions are:

```text
key_event(x11_key: i32, flags: i32) -> i32
pointer_event(button_mask: i32, x_px: i32, y_px: i32) -> i32
```

The component declares its rendered format through Content metadata. Pixel
components in this repository normally return `image/ktx2` with canonical
`ktx2-r8g8b8a8-srgb` data. `<qip-play>` also accepts the repository's narrow
linear and transfer-encoded Display P3 RGBA32F profiles. An Interactive
component can instead render HTML, terminal data, or another declared format.

## Lifecycle

Initialize and present the component as Content at time zero:

```text
set any presentation-uniform overrides
render(input_size)
```

Open each later update with a positive, strictly increasing time:

```text
begin_update_at(now_ms)
set any update-uniform overrides
send zero or more events
next_wake_at_ms = finish_update()
```

Scheduled work due at `now_ms` runs before events in that update. Event
functions called outside an update trap. Rendering while an update is open
also traps. These failures identify a host or component defect; they are not
correctable user input.

`finish_update()` returns an absolute time:

- A value equal to `now_ms` requests no wake.
- A value greater than `now_ms` requests an update at or after that time.

The wake is advisory. A host can update earlier to deliver an event or later
after a background-tab pause. The component decides whether to replay fixed
steps, cap catch-up work, or fast-forward its own state.

Updates do not publish output. Only `render` may change the output buffer. A
host can therefore process events while hidden, keep reading the last rendered
bytes, and render the latest state when presentation is needed.

An omitted uniform uses its authored default. `finish_update` resets update
uniforms. `render` resets presentation uniforms, so an override never leaks
into a later execution.

See [Timed and Eventful Component
Contract](/docs/timed-and-eventful-components) for the complete state machines,
fixed-timestep choices, initialization failure, and uniform ordering.

## Event Semantics

Keyboard input uses X11 keysyms. `flags` is a bit field:

- Bit 0: key down (`1`) or key up (`0`).
- Bit 1: repeat.
- Bit 2: shift.
- Bit 3: control.
- Bit 4: alt.
- Bit 5: meta.

Common keysyms include Left `0xFF51`, Up `0xFF52`, Right `0xFF53`, Down
`0xFF54`, Escape `0xFF1B`, Enter `0xFF0D`, Tab `0xFF09`, and Backspace
`0xFF08`. Pass printable Unicode or ASCII code points directly.

Pointer input follows the Remote Framebuffer button-state model:

- Bit 0 (`1`): primary button.
- Bit 1 (`2`): middle button.
- Bit 2 (`4`): secondary button.

Coordinates are integer pixels in the current rendered presentation. When the
pointer leaves the surface, send a zero button mask and coordinates `-1, -1`
inside an update.

A host which loses keyboard or pointer focus must release input that it
previously reported as held. Queue key-up events for held keys and a zero-mask
pointer event before the next update. Otherwise a game can continue moving or
dragging after its view loses focus.

An event returns `1` when it applies a change and `0` when it is ignored. The
return value helps a host avoid an unnecessary presentation render. It does not
open, finish, or reject the update.

For pointer-heavy interfaces, compare semantic targets instead of raw movement.
For example, two coordinates inside the same unchanged button can produce one
accepted entry event followed by ignored moves.

## Host Loop

A host owns event queues and presentation policy. A typical visible loop is:

1. Call `render(input_size)` once to initialize and present time zero.
2. Perform a bootstrap update at the first positive time to discover a wake.
3. Queue native events until the host can open an update.
4. Open an update at the chosen event or wake time, set all update uniforms,
   deliver the queued events, and call `finish_update()`.
5. If a new presentation is needed, set all presentation uniforms and call
   `render(0)`.
6. Schedule the next host callback from the returned wake and pending events.

Give an event its own update when its exact native timestamp affects behavior,
such as double-click recognition. Several events can share one update when
coalescing them to one time is correct for that interface.

## Browser Presentation

`<qip-play>` decodes KTX2 output and scales the resulting canvas. A page can
set `canvas-width` and `canvas-height`, or the
`--qip-play-canvas-width` and `--qip-play-canvas-height` CSS properties.
Attributes take precedence.

Pointer coordinates are converted from the displayed canvas box to rendered
pixel coordinates. This permits a high-resolution rendered image to use a
smaller CSS presentation size.

For linear Display P3 RGBA32F output, `<qip-play>` first tries a float16 linear
Display P3 canvas. It then tries transfer-encoded float16 Display P3. If the
browser does not expose either canvas, the host reuses an 8-bit `ImageData` and
tone maps the pixels to Display P3 or sRGB. The stats line reports both the
component output profile and the canvas profile. A change in dimensions or
profile replaces the canvas and its context because those context settings are
immutable.

Add `debug` to `<qip-play>` to report output comparisons and unchanged renders.
The comparison scans the complete output, so keep it disabled for normal use.

`<qip-play max-memory="67108864">` rejects a module whose declared memory
minimum or maximum exceeds that cap. A module without a declared maximum is
also rejected. `memory.grow` is rejected unless `allow-memory-grow` is present
with `max-memory`.

See [Testing Interactive
Components](/docs/testing-interactive-components) for direct Wasm, host-loop,
output, and browser tests.
