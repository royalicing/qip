# Form ABI v0

This document defines a minimal interactive form ABI for modules that can run in both CLI and web hosts.

Scope:

- Single input per step
- No persistence
- No JSON metadata export
- Shared labels/keys between interfaces

## Required Exports

- `memory`
- `input_ptr() -> i32`
- `input_utf8_cap() -> i32`
- `run(input_len: i32) -> i32`
- `output_ptr() -> i32`
- `output_utf8_cap() -> i32`
- `input_step() -> i32`
- `input_max_step() -> i32`
- `input_key_ptr() -> i32`
- `input_key_len() -> i32`
- `input_label_ptr() -> i32`
- `input_label_len() -> i32`
- `error_message_ptr() -> i32`
- `error_message_len() -> i32`

## Input Buffer

At `input_ptr`:

- UTF-8 bytes for the current step value only.

Host must ensure:

- `input_len <= input_utf8_cap()`
- writes stay in wasm memory bounds

## Step Semantics

- `input_step()` is the current zero-based step index.
- `input_max_step()` is the maximum zero-based step index.
- Form is complete when:
  - `input_step() > input_max_step()`

For the current step, module provides:

- `input_key` (stable field key)
- `input_label` (human-facing label)

## Run Semantics

Host flow:

1. Read current step metadata (`input_step`, `input_max_step`, key/label, error).
2. Collect one input value.
3. Write value bytes to `input_ptr`.
4. Call `run(input_len)`.

Module behavior:

- On validation failure:
  - keep `input_step` unchanged
  - set `error_message_len > 0`
- On success:
  - advance step (or move to completion state)
  - clear `error_message` (recommended)

`run` return value is UTF-8 output length in `output_ptr`.
Final result is read when form is complete.

## Invariants

Host should enforce:

- all pointer+len reads are within wasm memory bounds
- all lengths are non-negative
- all metadata strings are valid UTF-8
- output length from `run` is non-negative and does not exceed `output_utf8_cap`
