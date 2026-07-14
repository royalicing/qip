# `qip comply`

`qip comply` is for turning a QIP component contract into an executable conformance check.

A comply module is a small conformance suite. It is not the implementation's own unit test suite, and it is not a wrapper around `qip run`. Current Compliance components drive the implementation through the host-owned `qip` bridge; legacy checkers import the implementation as `impl`. Both report whether the implementation obeys a reusable contract.

Use comply modules for behavior that more than one component may need to satisfy: "preserve empty input", "reject invalid UTF-8", "normalize phone numbers", or "accept exactly the Luhn-valid account numbers".

We usually write small comply modules in WebAssembly text (`.wat`) because the host contract is tiny and the memory layout is explicit. Larger spec suites can be written in a higher-level language when the checker needs parsing, embedded fixtures, or a large corpus.

## Why A Separate Checker

Think of `qip comply` as double-entry accounting for component behavior. The
implementation and the comply module are written separately, then you check
that the two agree.

That separation is useful because it reduces implementation bias. When possible,
derive the comply module from a trusted specification, published examples, or a
small independent oracle. For new behavior, writing the comply module first can
serve the same role as test-driven development: it forces the contract to exist
before implementation details start shaping the tests.

Note if both the implementation and the checker are copied from the
same mistaken code path, they can still agree on wrong behavior.

## Command

```bash
qip comply <impl.wasm> [--with <check.wasm> ...] [-v|--verbose] [--timeout-ms <ms>]
```

## Examples In This Repo

```bash
# Expects that modules/utf8/e164.wasm produces normalized phone numbers, and preserves empty input.
qip comply modules/utf8/e164.wasm --with compliance/e164.comply.wasm --with compliance/preserve-empty.wasm

# Expects that modules/utf8/utf8-must-be-valid.wasm traps when provided a range of invalid UTF-8, and also accepts whitespace or empty strings untouched.
qip comply modules/utf8/utf8-must-be-valid.wasm --with compliance/trap-invalid-utf8.wasm --with compliance/preserve-empty.wasm --with compliance/preserve-whitespace.wasm

# Expects that modules/utf8/luhn.wasm accepts normalized Luhn-valid input and traps on invalid input.
qip comply modules/utf8/luhn.wasm --with compliance/luhn.comply.wasm
```

## What It Does

1. Base validation (always):

- requires `memory` export
- detects component kind as `render`, `tile`, or `render+tile`
- validates required ABI shape for the detected kind

2. Static qip contract checks (always, when qip exports are present):

- checks exported qip contract functions such as `input_ptr`, `output_ptr`, and capacity exports
- function exports must be vanilla sequences: no calls, no loops, no dynamic control flow
- checks exported qip contract globals are constant init expressions with no `global.get` dependency

3. Optional behavior checks (`--with`):

- each check component is executed against the implementation component
- checks run in parallel
- all checks must pass

## Base Contract Rules

`render` component requires:

- `render(i32) -> i32`
- `input_ptr` as exported global or function returning `i32`
- `input_utf8_cap` or `input_bytes_cap` as exported global or function returning `i32`

`tile` component requires:

- `tile_rgba32float_64x64(f32, f32) -> ()`
- `input_ptr` as exported global or function returning `i32`
- `input_bytes_cap` as exported global or function returning `i32`

## Memory Model

### Current bridge components

Current Content Compliance components own their memory and export `comply() -> i32`. They declare cases through imports from the `qip` module rather than importing implementation memory directly:

- `render_must_equal(ordinal, input_ptr, input_size, expected_ptr, expected_size) -> i32`
- `render_must_trap(ordinal, input_ptr, input_size) -> i32`
- `render_examine(ordinal, input_ptr, input_size, output_ptr, output_capacity) -> i32`
- `render_examine_pass(ordinal) -> i32`
- `render_examine_fail(ordinal) -> i32`
- `set_uniform_u32(name_ptr, name_size, value) -> i32`

`set_uniform_u32` lets a compliance component exercise configuration as part of its corpus. The name is a lowercase uniform key such as `currency`; the host calls `uniform_set_currency(i32) -> i32` on the implementation and returns the applied value to the compliance component. The call must happen between cases, not while an examination is open. It does not consume an ordinal or count as a case.

The compliance component remains responsible for changing its own oracle state after selecting an implementation uniform. A formatter checker can therefore select currency `392`, declare its JPY cases, select `840`, and declare its USD cases during one run without exporting a currency uniform itself.

### Legacy shared-memory components

A comply module shares the implementation's linear memory. It usually imports:

- `impl.memory`
- `impl.input_ptr`
- `impl.input_utf8_cap` or `impl.input_bytes_cap`
- `impl.output_ptr`, when it needs to compare output
- `impl.render`

The usual render checker loop is:

1. Call `input_ptr()` and a capacity export.
2. Reserve a scratch area inside the implementation input buffer.
3. Write test input bytes at `input_ptr`.
4. Call `render(input_size)`.
5. Read actual output from `output_ptr()` using the returned size.
6. Compare actual output with the expected bytes.
7. On mismatch, export failure detail pointers so the CLI can print the case.

Keep scratch memory simple. For example, `compliance/luhn.comply.wat` writes input
at `input_ptr` and expected output at `input_ptr + 256`, after first requiring at
least 512 bytes of input capacity. We prefer this style because the memory
contract is visible in three lines and failures are easy to reproduce.

## Check Component ABI

A check component passed with `--with` must:

- import `impl.memory`
- export `positive() -> i32`

Optional:

- export `negative() -> i32`

Status convention:

- `> 0` means pass
- `<= 0` means fail

Returning the number of checks that passed is a useful convention. Returning a
negative scenario code is useful on failure. The host only requires the sign, but
humans reading a failure log benefit from stable codes.

## Positive And Negative Phases

`positive()`:

- runs first
- called against a fresh `impl` instance
- any trap from `impl` causes failure

`negative()`:

- only runs if exported
- runs against a separate fresh `impl` instance
- host provides `qip.render_must_trap(i32) -> i32`
- use `render_must_trap` when trap is expected
- if `negative()` returns `<= 0`, `qip` reports `negative() expected trap`

`positive()` and `negative()` run against separate fresh implementation
instances. Separate `--with` modules also run independently and in parallel. A
checker should therefore carry its own fixtures and setup, and should not depend
on state left behind by another checker.

Use `positive()` for inputs the implementation must accept. Use `negative()` for
inputs the implementation must reject by trapping. If invalid input should return
an empty output instead of trapping, keep that in `positive()` and compare the
empty output explicitly.

## Authoring Strategies

Choose the smallest checker shape that teaches the contract.

- Use a **fixture check** when one invariant has one obvious case. `preserve-empty`
  calls `render(0)` and expects zero bytes.
- Use a **table check** when a handful of examples define the behavior.
  `e164.comply.wat` embeds concrete inputs and expected normalized outputs.
- Use a **generated oracle check** when the valid space is large but cheap to
  generate. `luhn.comply.wat` builds many valid numbers, computes their check
  digit, and expects the implementation to normalize them.
- Use a **mutation check** when invalid examples are best made from valid ones.
  Luhn generates a valid number, flips one digit, and requires a trap.
- Use a **corpus/spec check** when the contract is external and example-heavy.
  The CommonMark checker embeds the upstream spec examples and runs them as a
  conformance corpus.

The tradeoff is complexity. A table check is easier to review, but it can miss
whole classes of bugs. A generated checker covers more space, but it must contain
an independent oracle that is simpler than the implementation under test. If the
checker re-implements the same complicated algorithm, you have two places
to hide the same mistake.

## Luhn As A Pattern

The Luhn comply module shows the current pattern for an algorithmic checker:

- It makes the scratch contract explicit: require enough capacity, then split the
  implementation input buffer into input and expected-output regions.
- It exports `failure_input_*`, `failure_expected_output_*`, and
  `failure_actual_output_*`, so failures show the exact bytes that reproduced the
  mismatch.
- It has a small independent oracle, `$make_valid_case`, which computes a valid
  check digit from generated prefixes.
- It varies length, seed, and formatting style, so a small loop covers many
  cases without a large fixture table.
- It separates acceptance from rejection: `positive()` checks valid normalized
  output, while `negative()` uses `qip.render_must_trap` for empty, too-short,
  malformed, and checksum-invalid input.

That pattern generalizes well. For a validator, generate known-good values,
assert the normalized output, then perturb one property at a time and assert
rejection. For a formatter, generate representative inputs and assert stable
canonical output. For a parser, carry a corpus and include failure messages that
identify the source case.

## Failure Detail Exports (Optional)

If a check fails, `qip comply` tries to print reproducible failure context from optional exports on the check component.

Input detail:

- `failure_input_ptr` / `failure_input_size`

Message detail:

- `failure_message_ptr` / `failure_message_size`

Expected vs actual output detail:

- `failure_expected_output_ptr` / `failure_expected_output_size`
- `failure_actual_output_ptr` / `failure_actual_output_size`

Legacy output detail fallback:

- `failure_output_ptr` / `failure_output_size`

Aliases with a `fail_` prefix are also accepted. Prefer the `failure_` names for
new modules.

## Minimal WAT Example

```wat
(module
  (import "impl" "memory" (memory 1))
  (import "impl" "input_ptr" (func $input_ptr (result i32)))
  (import "impl" "render" (func $render (param i32) (result i32)))
  (import "impl" "output_ptr" (func $output_ptr (result i32)))

  (func (export "positive") (result i32)
    ;; Write input at (call $input_ptr), call $render, compare output from
    ;; (call $output_ptr), and return >0 on pass.
    (drop (call $render (i32.const 0)))
    (i32.const 1))
)
```

## Negative Trap Example

```wat
(module
  (import "impl" "memory" (memory 1))
  (import "qip" "render_must_trap" (func $render_must_trap (param i32) (result i32)))

  (func (export "positive") (result i32)
    (i32.const 1))

  (func (export "negative") (result i32)
    (if (i32.ne (call $render_must_trap (i32.const 0)) (i32.const 1))
      (then (return (i32.const -1))))
    (i32.const 1))
)
```

## Authoring Workflow

1. Start with the behavior sentence: "This component accepts X, normalizes to Y,
   and rejects Z."
2. Pick the strategy: fixture, table, generated oracle, mutation, or corpus.
3. Reserve scratch memory and check capacity before writing.
4. Export failure detail before returning a failing status.
5. Build the implementation and compliance module.
6. Run `qip comply impl.wasm --with compliance.wasm`.
7. Add the command to `make -j test` coverage when the contract should protect
   the repo permanently.

## When Not To Use It

Do not reach for `qip comply` when a plain snapshot or unit test would explain
the behavior better. Compliance modules are best when the contract should be
portable across implementations, when a component must reject invalid input in a
specific way, or when the checker itself can be a useful executable spec.
