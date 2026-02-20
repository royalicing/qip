# Module Patterns

This is a practical cookbook for writing `qip` modules.

It also includes the error semantics you need when deciding whether to return a value, return empty output, or trap.

## Choose A Pattern

Use this quick mapping:

- Validate and emit only pass/fail: scalar `run` result, no output buffer exports.
- Normalize text: UTF-8 input/output buffers.
- Transform binary: bytes input/output buffers.
- Emit numeric rows: `output_i32_cap`.
- Hard reject invalid input: trap.
- Soft reject invalid input: return `0` output length (or a sentinel scalar value).

## Pattern 1: Scalar Validator (No Output Buffer)

Use when you only need a status code.

Exports:

- `input_ptr`
- `input_utf8_cap` or `input_bytes_cap`
- `run(input_size) -> i32`

Do not export `output_ptr` or output caps.

Host behavior:

- `qip` prints `Ran: <run_return_value>`.
- In a chain, downstream modules receive empty bytes from this stage. Treat this as terminal unless that is intentional.

Good for:

- checks like "valid/invalid", "count", "score", "bitmask".

## Pattern 2: Normalizer (UTF-8 -> UTF-8)

Use when you rewrite text and return text.

Exports:

- `input_ptr`
- `input_utf8_cap`
- `output_ptr`
- `output_utf8_cap`
- `run(input_size) -> output_size`

Host behavior:

- Input is bounded by `input_utf8_cap`.
- Return value is interpreted as output byte length.
- Host checks `output_size <= output_utf8_cap`.

Good for:

- e164 canonicalization
- trimming
- case conversion

## Pattern 3: Binary Transformer (Bytes -> Bytes)

Use for non-text payloads.

Exports:

- `input_ptr`
- `input_bytes_cap`
- `output_ptr`
- `output_bytes_cap`
- `run(input_size) -> output_size`

Host behavior matches Pattern 2, but no UTF-8 assumptions.

Good for:

- image/container transforms
- compression/decompression steps

## Pattern 4: Numeric Stream (`i32` rows)

Use when you want hex lines from 32-bit values.

Exports:

- `input_ptr`
- `input_utf8_cap` or `input_bytes_cap`
- `output_ptr`
- `output_i32_cap`
- `run(...) -> item_count`

Semantics:

- Return value is number of `i32` items, not bytes.
- Host multiplies count by `4` for memory reads and bounds checks.

## Error Semantics (Merged)

These are the current semantics in `qip`.

### Contract Errors (Host-side)

Execution fails if required exports are missing for the chosen pattern.

Examples:

- missing `input_ptr`
- missing input cap export
- `output_ptr` present but no matching output cap export

### Capacity Errors (Host-side)

Execution fails if:

- input length exceeds declared input capacity
- returned output count exceeds declared output capacity

### Runtime Trap / Call Error (Module-side)

If module execution traps (or function call fails), the stage fails.

- `qip run`: command exits with error
- `qip dev`: request fails with error response (`500`)

Use trap when invalid input should be a hard failure.

### How To Trap

Use these language-specific forms when you want hard failure semantics.

Zig:

```zig
if (invalid_input) @trap();
```

C (Clang/zig cc targeting wasm):

```c
if (invalid_input) __builtin_trap();
```

WAT:

```wasm
;; inside a function
(if (local.get $invalid_input)
  (then
    unreachable
  )
)
```

### Soft Failure (Module-side)

Use return values to signal non-fatal failure.

Common options:

- scalar pattern: return `0` or `-1` sentinel
- buffered output pattern: return `0` bytes/items

Host treats this as successful execution unless a bound/contract check failed.

### Empty Output Semantics

If output buffers are exported and `run` returns `0`, output is empty.

- In chains, downstream stage receives empty input bytes.
- This is often useful for filter/drop behavior.

### Choosing Trap vs Soft Failure

Prefer trap when:

- input is malformed and should abort the pipeline
- a safety invariant is violated
- partial output would be misleading

Prefer soft failure when:

- invalid input is expected and non-exceptional
- you want to continue pipeline execution
- empty output or status code is meaningful

## Implementation Checklist

- Pick one pattern first; do not mix semantics accidentally.
- Keep pointer/cap units consistent (bytes vs `i32` items).
- Clamp input length in module code.
- Ensure `run` return value unit matches exported output cap type.
- Add tests for malformed input and oversized input.
