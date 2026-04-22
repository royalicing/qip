# `qip comply`

`qip comply` verifies a given module comply with one or more compliance modules.

For example you could have a module that renders an HTML5 page, and you want to check it produces valid HTML5.

It’s currently recommended that you write these in WebAssembly text (wat) format.

## Command

```bash
qip comply <impl.wasm> [--with <check.wasm> ...] [-v|--verbose] [--timeout-ms <ms>]
```

## Examples In This Repo

```bash
# Expects that the modules/utf8/e164.wasm module produces normalized phone numbers, and preserves empty input.
qip comply modules/utf8/e164.wasm --with compliance/e164.comply.wasm --with compliance/preserve-empty.wasm

# Expects that the modules/utf8/utf8-must-be-valid.wasm module traps when provided a range of invalid UTF-8, and also accepts whitespace or empty strings untouched.
qip comply modules/utf8/utf8-must-be-valid.wasm --with compliance/trap-invalid-utf8.wasm --with compliance/preserve-empty.wasm --with compliance/preserve-whitespace.wasm
```

## What It Does

1. Base validation (always):

- requires `memory` export
- detects module kind as `run`, `tile`, or `run+tile`
- validates required ABI shape for the detected kind

2. Static qip contract checks (always, when qip exports are present):

- checks exported qip contract functions such as `input_ptr`, `output_ptr`, and capacity exports
- function exports must be vanilla sequences: no calls, no loops, no dynamic control flow
- checks exported qip contract globals are constant init expressions with no `global.get` dependency

3. Optional behavior checks (`--with`):

- each check module is executed against the implementation module
- checks run in parallel
- all checks must pass

## Base Contract Rules

`run` module requires:

- `run(i32) -> i32`
- `input_ptr` as exported global or function returning `i32`
- `input_utf8_cap` or `input_bytes_cap` as exported global or function returning `i32`

`tile` module requires:

- `tile_rgba_f32_64x64(f32, f32) -> ()`
- `input_ptr` as exported global or function returning `i32`
- `input_bytes_cap` as exported global or function returning `i32`

## Check Module ABI

A check module passed with `--with` must:

- import `impl.memory`
- export `positive() -> i32`

Optional:

- export `negative() -> i32`

Status convention:

- `> 0` means pass
- `<= 0` means fail

## Positive And Negative Phases

`positive()`:

- runs first
- called against a fresh `impl` instance
- any trap from `impl` causes failure

`negative()`:

- only runs if exported
- runs against a separate fresh `impl` instance
- host provides `qip.run_must_trap(i32) -> i32`
- use `run_must_trap` when trap is expected
- if `negative()` returns `<= 0`, `qip` reports `negative() expected trap`

## Failure Detail Exports (Optional)

If a check fails, `qip comply` tries to print reproducible failure context from optional exports on the check module.

Input detail:

- `failure_input_ptr` / `failure_input_size`

Message detail:

- `failure_message_ptr` / `failure_message_size`

Expected vs actual output detail:

- `failure_expected_output_ptr` / `failure_expected_output_size`
- `failure_actual_output_ptr` / `failure_actual_output_size`

Legacy output detail fallback:

- `failure_output_ptr` / `failure_output_size`

## Minimal WAT Example

```wat
(module
  (import "impl" "memory" (memory 1))
  (import "impl" "run" (func $run (param i32) (result i32)))

  (func (export "positive") (result i32)
    ;; Replace with real checks.
    (drop (call $run (i32.const 0)))
    (i32.const 1))
)
```

## Negative Trap Example

```wat
(module
  (import "impl" "memory" (memory 1))
  (import "qip" "run_must_trap" (func $run_must_trap (param i32) (result i32)))

  (func (export "positive") (result i32)
    (i32.const 1))

  (func (export "negative") (result i32)
    (if (i32.ne (call $run_must_trap (i32.const 0)) (i32.const 1))
      (then (return (i32.const -1))))
    (i32.const 1))
)
```
