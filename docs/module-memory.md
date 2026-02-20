# Module Memory Guide

This guide documents the contract `qip` expects for modules, and how it passes input in and reads output back.

## Quick Model

- A `.wasm` module file can be tiny, while instances’ initial linear memory can be much larger.
- WebAssembly memory is broken into multiple pages, where each page is `64 KiB` each.
- `qip` writes input into module memory, calls `run`, then reads output from module memory.

## Run Mode Contract

In `qip run`, modules can export pointer/cap values as either:

- zero-arg functions returning `i32` (common with Zig & C), or
- `i32` globals (common with `.wat`)

`qip` accepts both styles.

Required input exports:

- `input_ptr`
- one of `input_utf8_cap` or `input_bytes_cap`

Optional output exports:

- `output_ptr`
- one of `output_utf8_cap`, `output_bytes_cap`, or `output_i32_cap`

Required function:

- `run(input_size) -> output_size`

If `output_ptr` + output cap are not exported, `qip` falls back to printing `Ran: <run_return_value>`.

## Input/Output Semantics

Input:

- `qip` ensures `len(input) <= input_*_cap`.
- Input bytes are written to memory at `input_ptr`.
- If input is larger than cap, execution fails with `Input is too large`.

Output:

- `run` return value is interpreted as element count.
- For UTF-8 or raw bytes output, element size is `1` byte.
- For `output_i32_cap`, element size is `4` bytes aka `32` bits.
- `qip` checks returned count does not exceed exported output cap.

Capacity units:

- `input_utf8_cap`, `input_bytes_cap`, `output_utf8_cap`, `output_bytes_cap`: bytes.
- `output_i32_cap`: number of `i32` items.

## Memory Layout Recommendations

- Keep input and output buffers disjoint.
- Clamp `input_size` in your module to avoid out-of-bounds when host and module assumptions drift.
- Reserve explicit scratch space if needed.
- Return `0` on invalid/empty output when that fits your module semantics.

## Image Mode Memory

For `qip image` / RGBA filters:

- Required: `input_ptr`, `input_bytes_cap`, `tile_rgba_f32_64x64`.
- Host writes tile data into memory at `input_ptr`.
- Filter runs in-place and host reads back from the same buffer.

Tile byte size:

`tile_bytes = tile_span * tile_span * 4 channels * 4 bytes(float32)`

Where:

- `tile_span = 64` without halo.
- `tile_span = 64 + 2 * halo` with halo.

If any stage exports `calculate_halo_px` with `halo > 0`, host uses the full-image float32 pipeline for all stages in the contiguous image block.

See also: `IMAGE.md`.

## Practical Checklist

- Verify your exported caps match actual writable memory.
- Test both normal and oversized input.
- Check module behavior when `run` returns 0.
