# Timed And Eventful Component Contract

This experimental contract extends a Content component with retained state,
time, and then events. It keeps input acceptance, state updates, and
presentation as separate operations:

```text
Content                 render input -> output
Fallible Content        render input -> accepted output or rejection
Timed                    begin_update_at -> finish_update
Eventful                 Timed + key, pointer, or other events
Presentation             uniforms -> render current state
```

A component first initializes as Content at time zero. After initialization,
it rests as a presentation component. `begin_update_at` temporarily opens its
Timed or Eventful behavior. `finish_update` returns it to the resting state.
The component can then render the updated state, or remain unrendered while it
is hidden.

All 44 components in `components/interactive/` implement this revision.
Calculator and Tic-Tac-Toe are event-driven applications without scheduled
wakes. Spreadsheet and TextEdit add semantic caret deadlines. Snake, Side
Scroller, Peon Gold, and Vertical Shooter run bounded fixed-step simulations.
God Rays is Timed but has no event exports.

`components/interactive/gif-player.wasm` is a Timed component with fallible
Content initialization. It declares `image/gif` input, validates and indexes
the complete animation before `render` accepts it, and renders canonical KTX2.
This up-front work means a later update cannot discover a malformed frame and
need a failure path. The player accepts GIF87a and GIF89a files up to 4 MiB,
256 frames, 2048 pixels in either dimension, and 1,048,576 logical-screen
pixels. It supports global and local color tables, transparency, interlacing,
disposal methods 0 through 3, and Netscape loop counts. Frame delays below 20
ms use 20 ms to prevent a zero-delay animation from requesting continuous
updates. It rejects the GIF Plain Text rendering extension because silently
skipping that block would change the animation.

## Initialization Has Two Alternatives

An infallible initialization does not export
`failure_modes_per_input_offset`. Its state machine is:

```text
initializing
  `-- uniforms -> render(input_size) --> ready
```

If `render` returns, the returned output is valid and initialization is
complete. A trap means that the host broke a precondition or the component
failed unexpectedly. The host discards that instance.

A component which can reject allowed source input exports
`failure_modes_per_input_offset`. It uses this initialization state machine:

```text
initializing
  |-- uniforms -> render accepts --> ready
  `-- uniforms -> render rejects --> initializing
```

The host reads output only after `render` accepts. Rejection is for correctable
source input, such as a validator finding
malformed data inside its declared input domain. It is not for key presses,
pointer actions, or host lifecycle mistakes.

The component makes the acceptance decision before `render` returns. Both
alternatives converge on `ready` after successful initialization.

Initialization occurs once per instance. This revision does not use
`begin_update_at(0)` for reset. A host creates a fresh instance when it needs a
clean reset. A future dedicated reset capability can add source replacement
without overloading the time API.

## Timed Update State Machine

A Timed component exports:

```text
begin_update_at(now_ms: i64)
finish_update() -> i64
```

An Eventful component also exports one or more event functions, such as:

```text
key_event(x11_key: i32, flags: i32) -> i32
pointer_event(button_mask: i32, x_px: i32, y_px: i32) -> i32
```

After either initialization path reaches `ready`, all Timed and Eventful
components use one state machine:

```text
ready
  `-- begin_update_at(now_ms) --> receiving_update_uniforms

receiving_update_uniforms
  |-- uniform_set_* ----------> receiving_update_uniforms
  |-- first event ------------> receiving_events
  `-- finish_update ----------> ready

receiving_events
  |-- event ------------------> receiving_events
  `-- finish_update ----------> ready
```

Uniform setters are optional overrides. Call them before the first event when
an update needs values other than the authored defaults. `finish_update` resets
all update uniforms to their defaults, including setters the host omitted. A
component can receive an event immediately after `begin_update_at` when it does
not need an override.

`now_ms` must be positive and strictly greater than the preceding finished
update time. Calling `begin_update_at` while an update is open, sending an event
while no update is open, setting a uniform after the first event, rendering
while an update is open, or calling `finish_update` without an open update is a
host contract violation and traps.

`finish_update` does not reject a conforming update. Normal UI and game events
apply directly to component state. An event returns `1` when it applies a
change and `0` when it is ignored. The component does not need a rollback
snapshot when every conforming update is infallible.

The `finish_update` result is an absolute time in the same monotonic timeline:

```text
result == now_ms  no scheduled wake
result > now_ms   request an update at or after result
```

A result before `now_ms` violates the component contract. The requested wake
is advisory. A host may update earlier for an event or later because the
component was hidden or the process was busy.

## Advance Time Before Events

Update uniforms can affect simulation, so `begin_update_at` cannot always do
all time advancement immediately. A component can advance lazily once per
update:

```text
ensure_advanced():
  use authored defaults plus this update's overrides
  if this update has not advanced:
    advance_to(update_time)
    mark this update advanced
```

The first event or `finish_update` calls this operation. Scheduled work due at
time `T` runs before events delivered by `begin_update_at(T)`. The event then
affects later simulation steps. This ordering gives a precise result at a time
boundary and does not require timestamp arguments on every event.

A host which needs the native event time can give that event its own update:

```js
component.begin_update_at(eventTimeMS);
setUpdateUniformOverrides(component);
component.key_event(keysym, flags);
const nextWakeAtMS = component.finish_update();
```

The host queues events in host memory when it cannot call the component. Event
functions called outside an update trap; they do not inspect or queue input.

## Presentation Is Separate

When the component is `ready`, the host can present committed state:

```text
set any presentation-uniform overrides
output_size = render(0)
```

`render(0)` does not advance time or process events. It writes output and
resets presentation uniforms. Calling it again with the same uniforms and
committed state produces the same bytes. This lets a host recreate a purged CPU
or GPU copy without creating an artificial state boundary.

Only `render` can modify the output buffer. `begin_update_at`, uniforms,
events, and `finish_update` leave the preceding output intact. Rendering is not
part of the update state machine, so update scheduling and presentation
scheduling can differ.

The output does not have to contain pixels. Canonical
`ktx2-r8g8b8a8-srgb` is the primary pixel output, but a component can render
HTML, SVG, terminal data, or another declared Content format.

## Starting Animation

The presence of `begin_update_at` declares the Timed capability. After Content
initialization, a host performs one bootstrap update at its first positive
time:

```js
component.begin_update_at(1n);
setUpdateUniformOverrides(component);
const nextWakeAtMS = component.finish_update();
```

An animating component returns its first future wake. A dormant component
returns the bootstrap time. An event can start animation later by returning a
future wake from its update. This avoids a fixed `desired_hz` export, which
would confuse simulation rate with presentation rate and cannot express
state-dependent deadlines.

## Fixed-Timestep Simulation

`next_wake_at_ms` can expose a component's next fixed-step boundary without
putting the timestep policy in the ABI. A component retains its next boundary,
processes every due boundary up to the update time, and returns the next one.
It may instead fast-forward semantic state when individual missed steps do not
affect the result.

The repository simulator compares several policies:

```sh
node tools/fixed-timestep-simulator.mjs
```

For one simulated second, fixed 10 ms integration produced identical position
and velocity under regular and irregular host updates. Variable-delta
integration produced different values. Delivering an event in its own 455 ms
update also produced identical final state under both host schedules.

A late host creates a separate choice. Exact catch-up after a five-second gap
ran 500 ten-millisecond steps in one update. Catch-up capped at eight ran eight
steps, dropped 492 missed steps, and requested the next wake ten milliseconds
after the resumed time. Exact catch-up preserves the simulated history but can
cause a spiral of death. Bounded catch-up limits work but gives up equivalence
with an uninterrupted run.

For a game, a long suspension should pause play instead of silently dropping
simulation steps. The component anchors its clock at the late update time,
requests no wake, and waits for a deliberate key-down or primary click to
resume. Keep the suspension threshold separate from the ordinary catch-up
budget: eight 16 ms steps is only 128 ms and can occur during a normal hitch.
Animations which have no gameplay consequences can fast-forward instead.

This follows the fixed-step accumulator described in [Fix Your
Timestep](https://www.gafferongames.com/post/fix_your_timestep/). The contract
does not require one integration method. It provides exact monotonic update
times and wake deadlines so each component can choose its own method.

## Initial Implementations

`components/interactive/calculator.zig` demonstrates the application pattern:

1. `render(0)` initializes and presents the calculator.
2. A bootstrap update returns its own time, so no wake is scheduled.
3. Key and pointer events mutate calculator state inside later updates.
4. `finish_update` closes each update without rejection.
5. A separate `render(0)` presents the result.

`components/interactive/snake.zig` demonstrates the game-loop pattern:

1. `render(0)` initializes and presents the board at time zero.
2. The bootstrap update returns the first 120 ms boundary.
3. Each update advances due fixed steps before applying its events.
4. `finish_update` returns the next boundary, or its update time while paused.
5. Rendering remains independent of simulation updates.

`components/interactive/gif-player.zig` demonstrates capability composition:

1. The host supplies an `image/gif` source to the Content `render` call.
2. `render` rejects malformed or unsupported GIF data without destroying the
   instance, or accepts and returns the decoded first frame.
3. A Content-only host can stop there and use that KTX2 output.
4. A Timed host calls `begin_update_at` and `finish_update` to select later GIF
   frames and receive the next frame deadline.
5. The component exports no events because playback needs time but no user
   interaction.

`site/_elements/qip-play.js` uses these exports for repository Interactive
components. It does not implement superseded alpha ABIs.

## Migration TODO

- [x] Implement infallible initialization and the common update state machine
  in `calculator`, `snake`, `god-rays-optimized`, `tic-tac-toe-sun-moon`,
  `spreadsheet`, and `side-scroller-platformer`.
- [x] Separate `render(0)` from updates and keep output unchanged until render.
- [x] Add browser-host support for initialization, bootstrap updates, events,
  wake scheduling, and separate presentation.
- [x] Test regular and irregular fixed-step schedules, exact event times, late
  wakes, and bounded catch-up.
- [x] Add one Timed component with fallible Content initialization to exercise
  `render(input_size) -> bootstrap update` in a real component.
- [x] Make uniforms optional overrides with authored defaults, so hosts do not
  need to discover or prove complete update and presentation sets.
- [x] Port every repository Interactive component to
  `begin_update_at`/`finish_update`. Remove rollback snapshots where updates
  cannot reject.
- [x] Update hosts, examples, performance tools, and direct tests to use the
  current ABI only.
- [ ] Decide whether a dedicated reset or source-replacement capability is
  needed. Do not use time zero as reset before that decision.
- [ ] Replace bounded backlog dropping in gameplay components with an explicit
  long-suspension pause and resume interaction.
