# AGENTS Notes (Codex Sessions)

## Project Context

- `qip` has two distinct execution paths:
  - **Text/Binary**: runs WASM modules via `run` for text or raw byte processing.
  - **Image**: runs RGBA tiling filters via `qip image` and `image.html`.
- Notes below cover **Text/Binary** briefly, then **Image** in more detail.

## Text/Binary

- Entry point: modules export `run(input_size)` and read input from `input_ptr`.
- Capacity comes from `input_utf8_cap` or `input_bytes_cap` (global or function).
- Outputs are read from `output_ptr` with one of `output_utf8_cap`, `output_bytes_cap`, or `output_i32_cap`.

## Image

- `image.html` is a browser demo for RGBA filters.
- RGBA filters live in `examples/rgba/*.wat` with compiled `*.wasm`.

### Tiling + Halo

- Tile size is **64x64**.
- Filters may export `calculate_halo_px()` for halo padding.
- Host-side behavior:
  - If any stage returns halo > 0, the pipeline switches to a float32 full-image buffer for all stages.
  - Halo tiles use edge clamping and pass `x - halo`, `y - halo` to the module.
- See `IMAGE.md` for the full protocol.

### image.html State Management

- There is a **working state** (`workingState`) kept in memory.
- UI changes update `workingState` and **commit** to the URL hash (history replace).
- Hash parsing only happens on `hashchange` (back/forward/manual edits).
- Filters are not removed when unchecked; enabled flag is stored in the hash.

### Recent Filters Added

- `find-edges`, `cutout`, `color-halftone`, `gaussian-blur`, `unsharp-mask`
- `gaussian-blur` and `unsharp-mask` are halo-aware and use dynamic tile spans.

### Gotchas

- If a filter exports `calculate_halo_px`, its WAT must handle tile spans > 64 (row stride changes).
- `input_bytes_cap` must cover expanded tiles and scratch buffers.
- Make sure new filters are added to `image.html`:
  - menu button
  - template
  - `FILTER_DEFS`

## Tests

We have snapshots in `test/latest.txt` that are matched against `test/expected.txt`. When updating the tests within `Makefile` please run `make test` and verify all the tests pass.

## Optimization

When implementing a common algorithm, benchmark against other implementations. For example Go stdlib has many, so does Python, and Zig has a few. Or use what CLIs are installed. When looking at making a performance improvement, be sure to benchmark before and after to measure what the improvement was. You can use `qip bench` to benchmark the module. For big changes I’m ok with cloning the module, this way we can compare the before and after more easily.
