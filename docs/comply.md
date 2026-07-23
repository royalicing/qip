# `qip comply`

`qip comply` is for turning a QIP component contract into an executable conformance check.

A comply module is a small conformance suite. It is not the implementation's own unit test suite, and it is not a wrapper around `qip run`. Compliance components drive the implementation through the host-owned `qip` bridge and report whether it obeys a reusable contract.

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
qip comply <impl.wasm> [--with <check.wasm> ...] [--declarative-checkers] [--seed <n>] [-v|--verbose]
```

## Examples In This Repo

```bash
# Expects that components/utf8/e164.wasm produces normalized phone numbers, and preserves empty input.
qip comply components/utf8/e164.wasm --with compliance/e164.comply.wasm

# Expects that components/utf8/utf8-must-be-valid.wasm traps when provided a range of invalid UTF-8, and also accepts whitespace or empty strings untouched.
qip comply components/utf8/utf8-must-be-valid.wasm --with compliance/trap-invalid-utf8.wasm --with compliance/preserve-empty.wasm --with compliance/preserve-whitespace.wasm

# Expects that components/utf8/luhn.wasm accepts normalized Luhn-valid input and traps on invalid input.
qip comply components/utf8/luhn.wasm --with compliance/luhn.comply.wasm
```

## What It Does

1. Base validation (always):

- requires `memory` export
- detects component kind as `render`, `tile`, or `render+tile`
- validates required ABI shape for the detected kind

2. Static qip contract checks (always, when qip exports are present):

- checks exported qip contract functions such as `input_ptr`, `output_ptr`, and capacity exports
- function exports must be vanilla sequences: no calls, no loops, no dynamic control flow

3. Optional behavior checks (`--with`):

- each check component is executed against the implementation component
- checks run in parallel
- all checks must pass

## Base Contract Rules

`render` component requires:

- `render(i32) -> i32`
- `input_ptr() -> i32` as an exported function
- `input_utf8_cap() -> i32` or `input_bytes_cap() -> i32`

`tile` component requires:

- `tile_rgba32float_64x64(f32, f32) -> ()`
- `input_ptr() -> i32` as an exported function
- `input_bytes_cap() -> i32`

## Memory Model

Content Compliance components own their memory and export `comply() -> i32`. They declare cases through imports from the `qip` module rather than importing implementation memory directly:

- `render_must_equal(ordinal, input_ptr, input_size, expected_ptr, expected_size) -> i32`
- `render_must_trap(ordinal, input_ptr, input_size) -> i32`
- `render_examine(ordinal, input_ptr, input_size, output_ptr, output_capacity) -> i32`
- `render_examine_pass(ordinal) -> i32`
- `render_examine_fail(ordinal) -> i32`
- `set_uniform_u32(name_ptr, name_size, value) -> i32`

`set_uniform_u32` lets a compliance component exercise configuration as part of its corpus. The name is a lowercase uniform key such as `currency`; the host calls `uniform_set_currency(i32) -> i32` on the implementation and returns the applied value to the compliance component. The call must happen between cases, not while an examination is open. It does not consume an ordinal or count as a case.

The compliance component remains responsible for changing its own oracle state after selecting an implementation uniform. A formatter checker can therefore select currency `392`, declare its JPY cases, select `840`, and declare its USD cases during one run without exporting a currency uniform itself.

Every oracle call has a sequential `u64` ordinal starting at zero. `comply()`
returns the number of declared cases. Separate `--with` components run against
independent implementation instances and may run in parallel, so a checker must
carry its own fixtures and setup.

The bridge owns failure reporting. It retains the failing ordinal and copies the
declared input, expected output, and actual output while the case is live. A
Compliance component therefore needs no failure-detail exports.

## Keep Checkers Obvious

A comply module is an executable specification, so clarity is more valuable
than reuse. Prefer repeated cases and small self-contained checkers over shared
helpers, configurable frameworks, or inheritance-like extension points. A
reader should be able to inspect a checker and see which inputs are declared
and what each one requires.

Treat branches in a checker as a source of risk. Most fixture checks should be
a straight list of `render_must_equal` or `render_must_trap` calls. When an
external corpus requires a small parser or a generated oracle, keep that logic
mechanical, assert the exact number of cases it declares, and keep the trusted
source fixture beside the checker. Do not remove repetition merely to make the
checker DRY: duplicated specification code is often easier to audit than a
general abstraction that can skip or reinterpret cases.

### Declarative Checkers

Use `--declarative-checkers` when a checker should declare cases without making
runtime decisions. It requires one `comply` function containing only constants,
direct oracle calls, drops, and its final `end`:

```bash
qip comply impl.wasm --with check.wasm --declarative-checkers
```

The validation inspects the final Wasm, not the source language. It permits one
defined `comply` function containing only integer constants, direct calls to
host imports, dropped call results, and the final function end. It rejects
branches, conditionals, selects, loops, local helper calls, indirect calls,
memory instructions, and other executable operations. The checker may export
only `memory` and `comply`.

This is intentionally narrower than ordinary Content Compliance. Generated or
property-based checkers need control flow and should not use this option. A
declarative fixture checker instead declares every case as an unconditional
oracle call. The host records failures and verifies that the constant returned
by `comply()` matches the number of cases it observed.

The CommonMark checkers parse their checked-in text fixtures at Zig comptime.
That parser can branch because it does not become part of the Wasm. An
`inline for` emits the resulting cases as a flat sequence of calls, and the
declarative-checker validation verifies that the compiler preserved that shape.

This rule applies to the checker supplied with `--with`, not to the
implementation being tested. See [Hard Limits](/docs/hard-limits) for the
central map of artifact, runtime, and checker validation.

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

The CommonMark checker declares all 655 examples from the checked-in 0.31.2
corpus. `commonmark-0.31.2-gfm.wasm` repeats that core corpus, then declares the
22 enabled extension cases extracted from `github/cmark-gfm`. GitHub's two
disabled task-list examples are not treated as executable requirements.

GFM enables its extensions for every document. Its autolink extension changes
the output of four otherwise-valid CommonMark examples containing bare URLs or
email addresses. The GFM checker therefore reads
`gfm-commonmark-spec-0.31.2.txt`: a copy of the official 0.31.2 corpus with only
those four expected outputs changed. Keeping that difference in the fixture
lets the checker remain a flat list of assertions without feature branches.

The tradeoff is complexity. A table check is easier to review, but it can miss
whole classes of bugs. A generated checker covers more space, but it must contain
an independent oracle that is simpler than the implementation under test. If the
checker re-implements the same complicated algorithm, you have two places
to hide the same mistake.

## Luhn As A Pattern

The Luhn comply module shows the bridge pattern for an algorithmic checker:

- It owns its scratch memory, split into input and expected-output regions, and
  passes those ranges to the host bridge.
- It has a small independent oracle, `$make_valid_case`, which computes a valid
  check digit from generated prefixes.
- It varies length, seed, and formatting style, so a small loop covers many
  cases without a large fixture table.
- It declares accepted cases with `qip.render_must_equal` and rejected cases
  with `qip.render_must_trap`, using one sequential ordinal space.

That pattern generalizes well. For a validator, generate known-good values,
assert the normalized output, then perturb one property at a time and assert
rejection. For a formatter, generate representative inputs and assert stable
canonical output. For a parser, carry a corpus and include failure messages that
identify the source case.

## Minimal WAT Example

```wat
(module
  (import "qip" "render_must_equal"
    (func $render_must_equal (param i64 i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 0) "hello")

  (func (export "comply") (result i32)
    (drop
      (call $render_must_equal
        (i64.const 0)
        (i32.const 0) (i32.const 5)
        (i32.const 0) (i32.const 5)))
    (i32.const 1))
)
```

## Negative Trap Example

```wat
(module
  (import "qip" "render_must_trap"
    (func $render_must_trap (param i64 i32 i32) (result i32)))
  (memory (export "memory") 1)

  (func (export "comply") (result i32)
    (drop
      (call $render_must_trap
        (i64.const 0) (i32.const 0) (i32.const 0)))
    (i32.const 1))
)
```

## Authoring Workflow

1. Start with the behavior sentence: "This component accepts X, normalizes to Y,
   and rejects Z."
2. Pick the strategy: fixture, table, generated oracle, mutation, or corpus.
3. Keep input, expected output, and examination buffers in checker-owned memory.
4. Give each oracle call its next sequential ordinal.
5. Build the implementation and compliance module.
6. Run `qip comply impl.wasm --with compliance.wasm`.
7. Add the command to `make -j test` coverage when the contract should protect
   the repo permanently.

## When Not To Use It

Do not reach for `qip comply` when a plain snapshot or unit test would explain
the behavior better. Compliance modules are best when the contract should be
portable across implementations, when a component must reject invalid input in a
specific way, or when the checker itself can be a useful executable spec.
