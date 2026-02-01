# AGENTS Notes (Codex Sessions)

## Project Context

- This repo contains `qip`, a CLI that runs WASM modules for text and image processing.
- `image.html` is a browser demo for RGBA filters.
- RGBA filters live in `examples/rgba/*.wat` with compiled `*.wasm`.

## Tiling + Halo

- Tile size is **64x64**.
- Filters may export `calculate_halo_px()` for halo padding.
- Host-side behavior:
  - If any stage returns halo > 0, the pipeline switches to a float32 full-image buffer for all stages.
  - Halo tiles use edge clamping and pass `x - halo`, `y - halo` to the module.
- See `IMAGE.md` for the full protocol.

## image.html State Management

- There is a **working state** (`workingState`) kept in memory.
- UI changes update `workingState` and **commit** to the URL hash (history replace).
- Hash parsing only happens on `hashchange` (back/forward/manual edits).
- Filters are not removed when unchecked; enabled flag is stored in the hash.

## Recent Filters Added

- `find-edges`, `cutout`, `color-halftone`, `gaussian-blur`, `unsharp-mask`
- `gaussian-blur` and `unsharp-mask` are halo-aware and use dynamic tile spans.

## Gotchas

- If a filter exports `calculate_halo_px`, its WAT must handle tile spans > 64 (row stride changes).
- `input_bytes_cap` must cover expanded tiles and scratch buffers.
- Make sure new filters are added to `image.html`:
  - menu button
  - template
  - `FILTER_DEFS`

