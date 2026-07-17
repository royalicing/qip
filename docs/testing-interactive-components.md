# Testing Interactive Components

Interactive components are easiest to test at three boundaries: the Wasm module, the host loop, and a real browser. Keep each test at the lowest boundary that can prove the behavior. A module test should not need a browser, and every component should not repeat the host's event-queue tests.

## Test The Wasm Contract Directly

Build the component, instantiate it without imports, then call the same exports a host calls:

```sh
make -j components/interactive/sudoku.wasm
node --test test/sudoku-ui.mjs
```

```js
const bytes = await readFile("components/interactive/sudoku.wasm");
const { instance } = await WebAssembly.instantiate(bytes, {});
const game = instance.exports;

game.pointer_event(1, x, y, 0n);
game.pointer_event(0, x, y, 0n);
game.tick(0n);
game.render(0);
```

At this level, check contract behavior rather than browser mechanics:

- Render dimensions and output capacity agree.
- Accepted events return `1`; ignored events return `0`.
- Readonly or out-of-range targets leave state unchanged.
- A meaningful state transition changes the framebuffer.
- Repeating an event over the same semantic target is ignored when it would produce identical pixels.

Copy framebuffer bytes before another Wasm call. A later `render(0)` writes into the same linear-memory region.

## Test Semantic Pointer Targets

Convert raw coordinates into one semantic hit result and use it for hover and click handling. A grid with nested controls might return `{ cell_index, subcell_index }`. Tests can then use a small table of representative coordinates instead of reproducing UI logic through many screenshots.

For a 3x3 target, cover the whole row-major mapping when that mapping is the risky part:

```text
1 2 3
4 5 6
7 8 9
```

Also move twice within one target. The first move should be accepted, while the second should return `0` and leave the framebuffer hash unchanged. This checks the optimization at the module boundary without depending on timing.

## Check Frames Without Large Snapshot Suites

Full framebuffer snapshots are useful for a few stable reference states, but they become expensive when every hover and pressed state gets its own fixture. Prefer focused assertions:

- Sample a stable interior pixel for a background or highlight.
- Count a known color within one cell or control.
- Hash the full frame to prove that ignored input changes nothing.
- Check a small region for a bitmap glyph rather than snapshotting the whole page.

Use exact pixel checks for component-rendered bitmap graphics. Browser text, CSS layout, timing labels, and antialiasing are better checked structurally or in a browser screenshot.

## Test The Host Once

Host tests should cover behavior shared by every component. In this repo, `test/qip-play-debug-stats.mjs` loads the browser runtime in a small DOM shim and checks concerns such as:

- DOM button and key translation.
- Pointer leave behavior.
- Canvas focus and context-menu scoping.
- Event queue ordering.
- Accepted events calling `tick`.
- Ignored events skipping `tick` and rendering.

Do not repeat those assertions in each component test unless the component adds its own state transition at that boundary.

## Verify The Browser Path

Use a real browser for the remaining integration risks:

1. Start the site with `make dev`.
2. Wait for the canvas's intrinsic width and height, not an arbitrary delay.
3. Convert logical render coordinates through `getBoundingClientRect()` before moving or clicking the pointer.
4. Sample `canvas.getContext("2d").getImageData(...)` for one or two important states.
5. Check desktop and narrow viewports when CSS scales the fixed framebuffer.

Repository tests may inspect private counters such as `<qip-play>._renderN` to prove that moving within one semantic hover target does not render again. That counter is host instrumentation, not part of the public component contract.

Take a screenshot when layout or visual hierarchy is under review. Pixel samples establish precise output; the screenshot catches clipping, awkward spacing, and controls that are technically present but visually misplaced.

## Keep The Suite Small

A typical interactive component needs only a few durable tests:

- One initialization and primary-workflow smoke test.
- One test for its highest-risk coordinate or state mapping.
- One ignored-input or readonly boundary.
- A browser check only for behavior that direct Wasm and host tests cannot prove.

Avoid duplicating the same state across full snapshots, Node, browser automation, and host-runtime tests. Keep the assertion at the boundary that owns the behavior.
