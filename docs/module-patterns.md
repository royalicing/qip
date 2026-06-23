# QIP Component Patterns

This is a practical cookbook for writing QIP components.

It also includes the error semantics for deciding whether to return a value, return empty output, or trap.
Default recommendation: trap on invalid input or overflow for transformation components.
For validator-style components that should compose in pipelines, prefer assertion pass-through: return input unchanged on success, trap on failure.

## Choose A Pattern

Use this quick mapping:

- Validate and keep data flowing (preferred): assertion pass-through (`render` validates, returns input unchanged, traps on failure).
- Validate and emit only pass/fail (terminal): return a small UTF-8 or byte status payload.
- Normalize text: UTF-8 input/output buffers.
- Transform binary: bytes input/output buffers.
- Preferred: hard reject invalid input/overflow with trap.
- Optional: soft reject invalid input by returning `0` output length when empty output is explicitly meaningful.

## Pattern 1: Assertion Pass-through Validator (Preferred)

Use when you want to assert invariants in a chain without changing payload bytes.

Exports:

- `input_ptr`
- `input_utf8_cap` or `input_bytes_cap`
- `output_ptr`
- matching output cap (`output_utf8_cap` for UTF-8, `output_bytes_cap` for bytes)
- `render(input_size) -> output_size`

Semantics:

- On success, return input unchanged and set `output_size == input_size`.
- On validation failure, trap.
- Prefer `output_ptr == input_ptr` if no rewrite is needed.

Host behavior:

- Downstream components receive the original data when validation passes.
- Pipeline aborts on trap when validation fails.

Good for:

- broken-link checks over WARC/HTML
- schema/assertion checks that must preserve input for later stages
- safety gates before expensive transforms

## Pattern 2: Status Validator (Terminal Output)

Use when you only need a small pass/fail or status value and do not intend to keep piping the original payload.

Exports:

- `input_ptr`
- `input_utf8_cap` or `input_bytes_cap`
- `output_ptr`
- `output_utf8_cap` or `output_bytes_cap`
- `render(input_size) -> output_size`

Host behavior:

- The returned status is ordinary UTF-8 text or bytes.
- In a chain, downstream modules receive the status payload, not the original input. Treat this pattern as terminal unless that is intentional.

Good for:

- checks like "valid/invalid", "count", "score", "bitmask".

## Pattern 3: Normalizer (UTF-8 -> UTF-8)

Use when you rewrite text and return text.

Exports:

- `input_ptr`
- `input_utf8_cap`
- `output_ptr`
- `output_utf8_cap`
- `render(input_size) -> output_size`

Host behavior:

- Input is bounded by `input_utf8_cap`.
- Return value is interpreted as output byte length.
- Host checks `output_size <= output_utf8_cap`.

Good for:

- e164 canonicalization
- trimming
- case conversion

## Pattern 4: Binary Transformer (Bytes -> Bytes)

Use for non-text payloads.

Exports:

- `input_ptr`
- `input_bytes_cap`
- `output_ptr`
- `output_bytes_cap`
- `render(input_size) -> output_size`

Host behavior matches Pattern 3, but no UTF-8 assumptions.

Good for:

- image/container transforms
- compression/decompression steps

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

Use return values to signal non-fatal failure when that behavior is intentional.

Common options:

- return `0` bytes
- return a small status payload such as `ok`, `invalid`, or an error code

Host treats this as successful execution unless a bound/contract check failed.

### Empty Output Semantics

If output buffers are exported and `render` returns `0`, output is empty.

- In chains, downstream stage receives empty input bytes.
- This is often useful for filter/drop behavior.

### Choosing Trap vs Soft Failure

Default to trap, especially for normalizers/transformers where silent drops risk data loss.

Prefer trap when:

- input is malformed and should abort the pipeline
- a safety invariant is violated
- partial output would be misleading
- preserving source data is more important than availability
- output would otherwise be silently truncated
- validator modules are intended to compose with downstream stages (use assertion pass-through)

Prefer soft failure when:

- invalid input is expected and non-exceptional
- you want to continue pipeline execution
- empty output or status code is meaningful

## Implementation Checklist

- Pick one pattern first; do not mix semantics accidentally.
- Keep pointer/cap units consistent; content input and output capacities are byte counts.
- Validate input length and trap on overflow.
- Ensure `render` returns the number of output bytes.
- For validator modules in chains, default to assertion pass-through (`output_ptr == input_ptr`, return unchanged size, trap on failure).
- Add tests for malformed input and oversized input.
- Reuse one instance in tests for an invalid render followed by a valid render. A trap does not reset Wasm memory or globals, so this catches components that leave persistent state poisoned after rejecting bad input.
