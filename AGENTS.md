# AGENTS Notes (Codex Sessions)

The project uses a `Makefile` for common tasks. Use that and remember to pass `-j` to run in parallel.

## Project Context

- `qip` has two distinct execution paths:
  - **Text/Binary**: runs WASM modules via `run` for text or raw byte processing.
  - **Image**: runs RGBA tiling filters via `qip image` and `image.html`.
- Notes below cover **Text/Binary** briefly, then **Image** in more detail.

## Text/Binary

- Entry point: modules export `run(input_size)` and read input from `input_ptr`.
- Capacity comes from `input_utf8_cap` or `input_bytes_cap` (global or function).
- Outputs are read from `output_ptr` with one of `output_utf8_cap` or `output_bytes_cap`.

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

We have snapshots in `test/latest.txt` that are matched against `test/expected.txt`. When updating the tests within `Makefile` please run `make -j test` and verify all the tests pass.

## Optimization

When implementing a common algorithm, benchmark against other implementations. For example Go stdlib has many, so does Python, and Zig has a few. Or use what CLIs are installed. When looking at making a performance improvement, be sure to benchmark before and after to measure what the improvement was. You can use `qip bench` to benchmark the module. For big changes I’m ok with cloning the module, this way we can compare the before and after more easily.

## Docs Style Guide

Write docs that are engaging, informed, opinionated, and friendly. Avoid rants and avoid dry spec-only prose. See `docs/formats.md` for an example.

- Open with a clear thesis sentence that states a position.
- Use `claim -> reason -> example` structure for key sections.
- Prefer concrete language and direct verbs over abstract wording.
- Include tradeoffs when recommending a default.
- Use practical examples from this repo (commands, module paths, pipelines).
- Keep tone confident and helpful: say "we prefer X because Y".
- Avoid absolutist language unless it is a hard contract requirement.
- Add short "when not to use this" guidance where appropriate.
- Favor small decision rubrics/checklists for fast reader decisions.
- Keep pages skimmable with short sections and tight bullets.
