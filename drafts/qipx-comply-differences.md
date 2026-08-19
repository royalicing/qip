# Go `qip comply` vs JS `qipx comply` Differences For `./components`

Checked with:

```sh
./qip comply ./components > /tmp/go-comply-components.out 2>/tmp/go-comply-components.err
node npm/qipx/qipx.mjs comply ./components > /tmp/js-comply-components.out 2>/tmp/js-comply-components.err
```

Both commands currently agree on the high-level result:

```text
exit code: 1
stdout lines: 224
stderr lines: 0
pass=155 fail=67 total=222
```

The stdout is not byte-identical. There are 44 differing component lines.

## 1. Go Fails, JS Passes

### `components/image/jpeg/jpeg-strip-gps-exif.wasm`

Go:

```text
FAIL components/image/jpeg/jpeg-strip-gps-exif.wasm: comply: static qip contract checks failed
```

JS:

```text
PASS components/image/jpeg/jpeg-strip-gps-exif.wasm
```

Likely cause: Go runs static qip contract checks that `qipx` does not fully implement yet.

## 2. Go Passes, JS Fails

### `components/multipart/form-data/form-data-to-tar.wasm`

Go:

```text
PASS components/multipart/form-data/form-data-to-tar.wasm
```

JS:

```text
FAIL components/multipart/form-data/form-data-to-tar.wasm: invalid components/multipart/form-data/form-data-to-tar.wasm input content type: multipart/form-data;boundary=uuid-00000000-0000-0000-0000-000000000000
```

Likely cause: JS content-type validation rejects MIME parameters. Go currently accepts this content type.

Decision needed: decide whether QIP content types can include MIME parameters such as `multipart/form-data;boundary=...`, then align Go and JS.

## 3. Both Fail, But Diagnostics Differ

The Interactive components fail in both implementations. Go reports missing `input_ptr`; JS reports missing or ambiguous input capacity first.

Go pattern:

```text
FAIL <path>: <path> must export input_ptr
```

JS pattern:

```text
FAIL <path>: <path> must export exactly one input capacity: input_utf8_cap or input_bytes_cap
```

Affected components:

```text
components/interactive/aces-up.wasm
components/interactive/browser-security.wasm
components/interactive/calculator.wasm
components/interactive/cover-flow-lofi.wasm
components/interactive/cover-flow.wasm
components/interactive/dock-magnification.wasm
components/interactive/formula-1-map.wasm
components/interactive/gameboy-camera.wasm
components/interactive/god-rays-optimized.wasm
components/interactive/god-rays.wasm
components/interactive/graph-calculator.wasm
components/interactive/ieee-754-floats.wasm
components/interactive/layout-systems.wasm
components/interactive/liars-dice.wasm
components/interactive/macos9-desktop.wasm
components/interactive/macosx-leopard-desktop.wasm
components/interactive/mandelbrot.wasm
components/interactive/openai-anthropic-arr.wasm
components/interactive/org_planner.wasm
components/interactive/page-load-waterfall.wasm
components/interactive/paint.wasm
components/interactive/peon-gold.wasm
components/interactive/perlin-noise.wasm
components/interactive/photo-light-table.wasm
components/interactive/ps2-menu.wasm
components/interactive/render-counts.wasm
components/interactive/shadow-rendering.wasm
components/interactive/shutterstock-earnings.wasm
components/interactive/side-scroller-platformer.wasm
components/interactive/snake.wasm
components/interactive/spreadsheet.wasm
components/interactive/sudoku.wasm
components/interactive/tetris.wasm
components/interactive/textedit.wasm
components/interactive/tic-tac-toe-sun-moon.wasm
components/interactive/tile-world-12x12.wasm
components/interactive/vector-editor.wasm
components/interactive/vertical-shooter.wasm
components/interactive/web-mechanics.wasm
components/interactive/webos-card-view.wasm
components/interactive/windows95-desktop.wasm
components/interactive/xbox-dashboard.wasm
```

Likely cause: Content ABI validation order differs. Go checks `input_ptr` before input capacity. JS checks input capacity before `input_ptr`.

## Likely Parity Fixes

1. Add Go-equivalent static qip contract checks to `qipx`, or make Go omit that check from the default directory-summary contract if JS should stay intentionally smaller.
2. Decide the QIP rule for content-type parameters, then align Go and JS validation.
3. Align JS Content ABI validation order with Go:
   - `memory`
   - `render`
   - `input_ptr`
   - exactly one input capacity
   - `output_ptr`
   - exactly one output capacity
