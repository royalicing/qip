# Image Tiling Protocol (RGBA Filters)

This document describes the RGBA tiling protocol used by `qip image` (Go) and `image.html` (browser). It is intended for implementing future WebAssembly filter modules.

## Overview

- Filters operate on **tiles** of size **64x64** pixels.
- Pixel data is provided as **RGBA float32** values in `[0, 1]`.
- Filters run **in-place**: they read from the input tile buffer and write results back to it.
- The host may optionally provide a **halo** (extra border pixels) when a filter exports a halo function.

## Required Exports

Every RGBA filter module must export:

- `memory` (linear memory)
- `input_ptr` (global or function) -> byte offset into `memory`
- `input_bytes_cap` (global or function) -> capacity in bytes of the input buffer
- `tile_rgba_f32_64x64(x: f32, y: f32)` (function)

### Optional Exports

- `uniform_set_width_and_height(width: f32, height: f32)`
  - Called once per image before processing.
- `calculate_halo_px() -> i32`
  - If present, host enables halo mode and requests the halo size in pixels.
  - Returned value must be **>= 0**. Negative values are treated as 0 by the host.

## Tile Buffer Layout

The tile buffer is a **row-major** array of float32 RGBA values:

```
index = ((row * tileSpan) + col) * 4
R = buffer[index + 0]
G = buffer[index + 1]
B = buffer[index + 2]
A = buffer[index + 3]
```

- `tileSpan` is **64** when no halo is used.
- If halo is enabled, `tileSpan = 64 + 2 * halo`.
- The host writes the input tile into `memory` at `input_ptr`.
- The filter reads/writes in place in that buffer.

## Coordinates and Halo

- The host calls `tile_rgba_f32_64x64(x, y)` once per tile.
- `x` and `y` are the **top-left pixel coordinates** of the **64x64 core** tile in the original image.
- If halo is used, the host passes **`x - halo`** and **`y - halo`** so that absolute pixel math remains consistent with the expanded buffer.

Halo usage:

- Halo tiles are filled by the host using **edge clamping** (replicate the nearest pixel beyond image boundaries).
- Filters that read neighbors (blur, edge detection, etc.) should export `calculate_halo_px` and handle `tileSpan > 64`.
- The host writes back **only the 64x64 core** (center of the tile) to the output.

## Capacity Requirements

Modules must size `memory` and `input_bytes_cap` to hold the largest tile they expect.

- Required bytes: `tileSpan * tileSpan * 4 * 4`
- Example: `halo=6 -> tileSpan=76 -> bytes=76*76*16=92416`

If the module uses internal scratch buffers, allocate enough memory and place them beyond the input buffer to avoid overlap.

## Precision Pipeline

- The host uses float32 throughout the pipeline when **any** stage requests a halo.
- Without halo, the host currently uses a per-tile pipeline that writes results back to bytes between stages.

## Alpha Handling

- Alpha is always provided.
- Unless the filter explicitly modifies alpha, it should preserve it.

## Reference Implementation Notes

- `main.go` (Go) and `image.html` (browser) implement the host pipeline.
- `gaussian-blur.wat` shows a halo-aware filter with dynamic tile span and scratch buffers.
- `unsharp-mask.wat` shows a halo-aware filter that copies original data into scratch, blurs, then sharpens.
