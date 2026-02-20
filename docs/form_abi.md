# Form ABI

This document defines a minimal interactive form ABI for modules that can run in both CLI and web hosts.

Scope:

- Single input per prompt
- No persistence
- No JSON metadata export
- Shared labels/keys between interfaces

## Required Exports

- `memory`
- `input_ptr() -> i32`
- `input_utf8_cap() -> i32`
- `run(input_size: i32) -> i32`
- `output_ptr() -> i32`
- `output_utf8_cap() -> i32`
- `input_key_ptr() -> i32`
- `input_key_size() -> i32`
- `input_label_ptr() -> i32`
- `input_label_size() -> i32`
- `error_message_ptr() -> i32`
- `error_message_size() -> i32`

## Input Buffer

At `input_ptr`:

- UTF-8 bytes for the current input value only.

Host must ensure:

- `input_size <= input_utf8_cap()`
- writes stay in wasm memory bounds

## Prompt/Completion Semantics

For the current prompt, module provides:

- `input_key` (stable field key)
- `input_label` (human-facing label)

Form is complete when:

- `input_key_size() == 0`

When complete, host should treat the form as finished and read final output from `output_ptr`.

## Run Semantics

Host flow:

1. Read current metadata (`input_key`, `input_label`, `error_message`).
2. If `input_key_size() == 0`, form is complete.
3. Otherwise, collect one input value.
4. Write value bytes to `input_ptr`.
5. Call `run(input_size)`.

Module behavior:

- On validation failure:
  - keep internal state unchanged
  - set `error_message_size > 0`
- On success:
  - advance internal state (if any)
  - clear `error_message` (recommended)

`run` return value is UTF-8 output size in `output_ptr`.
Final result is read when form is complete.

## Invariants

Host should enforce:

- all pointer+size reads are within wasm memory bounds
- all sizes are non-negative
- all metadata strings are valid UTF-8
- output size from `run` is non-negative and does not exceed `output_utf8_cap`
