# `qip comply`

`qip comply` checks that a Content component satisfies QIP's Content Component ABI, strict wasm profile, and checks against optional Compliance oracles.

A Compliance oracle is like a portable test suite packaged as Wasm, but with a narrower job than a normal unit-test framework. It is an executable specification for a Content component. It owns its memory, imports a small `qip` oracle bridge, and declares cases such as "this input must produce these bytes" or "this input must trap". The host runs those cases against the implementation and owns failure reporting.

Use Compliance oracles for behavior that should be reusable across implementations: preserve empty input, reject invalid UTF-8, normalize phone numbers, or accept exactly the Luhn-valid account numbers. Do not use them as a wrapper around `qip run` or as a replacement for local unit tests that are easier to read in the implementation's source language.

The implementation and Compliance oracle can be written in different languages. Use the best tool for each side: a Content component can stay small and fast in Zig, C, Odin, or another Wasm-targeting language, while the oracle can use a language with a convenient standard library for parsing fixtures, generating cases, or embedding a corpus. This separation also helps review. A bug is less likely to hide when the implementation and oracle do not share the same parser, helper library, or code-generation path.

Small oracles are often easiest to audit in WebAssembly text (`.wat`) because the bridge is small and memory offsets are explicit. Larger suites can use a higher-level language when they need parsing, embedded fixtures, generated cases, or a large corpus.

## Why A Separate Oracle

Think of `qip comply` as double-entry accounting for component behavior. The
implementation and the Compliance oracle are written separately, then you check
that the two agree.

That separation is useful because it reduces implementation bias. When possible,
derive the Compliance oracle from a trusted specification, published examples, or a
small independent oracle. For new behavior, writing the Compliance oracle first can
serve the same role as test-driven development: it forces the contract to exist
before implementation details start shaping the tests.

Note if both the implementation and the oracle are copied from the
same mistaken code path, they can still agree on wrong behavior.

## Oracles As Portable Assets

A Compliance oracle is useful even when the implementation is not a QIP
component. The oracle is a Wasm module with a small host bridge, so another
runtime can instantiate it and bind the bridge to a local implementation written
in JavaScript, Go, Rust, Python, or another language.

For example, a JavaScript test can import `compliance/luhn.comply.wasm`, provide
`must_render_exactly` and `must_trap` imports, and route each declared case to a
plain JS `luhn(input)` function. The JS code does not need to become Wasm or
export the QIP Content ABI. It only needs an adapter that turns an input byte
slice into output bytes or a trap-like failure. This lets the same oracle guide a
native implementation, a QIP component, and a browser implementation without
copying the case corpus into each test suite.

This use is still double-entry accounting. The oracle should stay independent
from the implementation. If the JS implementation and the oracle share the same
normalization helper, parser, or generated table, they can still agree on the
same bug.

## Command

```bash
qip comply [options] <file-or-dir> [...]

Options:
  --with <oracle.wasm>             Run a Compliance oracle (repeatable)
  --seed <n>                      Call uniform_set_seed(u32) on each oracle
  --max-memory <bytes>            Reject implementation memory above bytes
  --straight-line-oracles         Require each --with oracle to use straight-line oracle calls
  -v, --verbose                   Print detailed validation logs
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
- validates the Content component ABI shape

2. Static qip contract checks (always, when qip exports are present):

- checks exported qip contract functions such as `input_ptr`, `output_ptr`, and capacity exports
- function exports must be vanilla sequences: no calls, no loops, no dynamic control flow

3. Optional behavior checks (`--with`):

- each Compliance oracle is executed against the implementation component
- directory inputs are walked in sorted order and duplicate paths are removed
- repeated `--with` oracles run in sorted order
- all checks must pass

## Base Contract Rules

A Content component requires:

- `render(i32) -> i32`
- `input_ptr() -> i32` as an exported function
- `input_utf8_cap() -> i32` or `input_bytes_cap() -> i32`
- `output_ptr() -> i32` as an exported function
- `output_utf8_cap() -> i32` or `output_bytes_cap() -> i32`

## Assertions

Content Compliance oracles own their memory and export `comply() -> i32`. They declare cases through imports from the `qip` module rather than importing implementation memory directly:

- `must_render_exactly(ordinal, input_ptr, input_size, expected_ptr, expected_size) -> i32`
- `must_trap(ordinal, input_ptr, input_size) -> i32`
- `must_render_into(ordinal, input_ptr, input_size, output_ptr, output_capacity) -> i32`
- `must_render_into_emit_error(ordinal, message_ptr, message_size) -> i32`
- `must_render_into_finish(ordinal, error_count) -> i32`
- `set_uniform_u32(name_ptr, name_size, value) -> i32`

`set_uniform_u32` lets a Compliance oracle exercise configuration as part of its corpus. The name is a valid uniform key such as `currency` or `font_size`: 1 to 63 characters, starts with `[a-z]`, continues with `[a-z0-9_]*`, does not end with `_`, and does not contain `__`. The host calls `uniform_set_currency(i32) -> i32` on the implementation and returns the applied value to the Compliance oracle. The call must happen between cases, not while a must_render_into case is open. It does not consume an ordinal or count as a case.

The Compliance oracle remains responsible for changing its own oracle state after selecting an implementation uniform. A formatter oracle can therefore select currency `392`, declare its JPY cases, select `840`, and declare its USD cases during one run without exporting a currency uniform itself.

Every oracle call has a sequential `u64` ordinal starting at zero. `comply()`
returns the number of declared cases. Separate `--with` oracles run against
independent implementation instances, so an oracle must carry its own fixtures
and setup.

The bridge owns failure reporting. It retains the failing ordinal and copies the
declared input, expected output, and actual output while the case is live. A
Compliance oracle therefore needs no failure-detail exports.

## Choose The Narrowest Oracle Call

Most oracles should use `must_render_exactly` or `must_trap`. These calls
make the case easy to audit: the oracle gives the host input bytes and either
an exact expected output or an expected trap. The host runs the implementation,
compares the result, and records a failure with the ordinal.

Use `must_render_into` only when the expected output cannot be written as a small
fixture or generated expected byte string. It is for procedural checks over the
actual output, such as validating that a large generated file has consistent
internal structure, that a compressed output can be decoded, or that several
acceptable encodings satisfy the same invariant.

`must_render_into` opens one case. The oracle passes an input buffer and an
output buffer it owns. The host runs the implementation and copies the actual
output into the oracle buffer when it fits. The return value is:

- `>= 0`: the number of output bytes copied;
- `-1`: the implementation trapped or the bridge detected an invalid pointer;
- `-2`: the implementation output was larger than `output_capacity`.

After inspecting the copied output, the oracle can emit zero or more UTF-8
error diagnostics with `must_render_into_emit_error(ordinal, message_ptr,
message_size)`, then must close the same ordinal with
`must_render_into_finish(ordinal, error_count)`. The `error_count` is
double-entry bookkeeping: it must match the number of emitted errors. Zero means
pass; a positive count means fail. If `must_render_into` returns `-1` or `-2`,
the oracle must emit at least one error and finish with a positive
`error_count`. The oracle must not open another case, declare a
`must_render_exactly`/`must_trap` case, or set a uniform while a
must_render_into case is open. The host reports a protocol violation if
`comply()` returns with an
must_render_into case still open.

Prefer a normal expected-output case when the oracle can build expected bytes
without duplicating the implementation. `must_render_into` gives the oracle more
control flow, so it can also hide mistakes. Keep must_render_into logic small, name
the invariant in a source comment, and make a failing must_render_into case mean one clear
contract failure.

## Keep Oracles Obvious

A Compliance oracle is an executable specification, so clarity is more valuable
than reuse. Prefer repeated cases and small self-contained oracles over shared
helpers, configurable frameworks, or inheritance-like extension points. A
reader should be able to inspect an oracle and see which inputs are declared
and what each one requires.

Treat branches in an oracle as a source of risk. Most fixture checks should be
a straight list of `must_render_exactly` or `must_trap` calls. When an
external corpus requires a small parser or a generated oracle, keep that logic
mechanical, assert the exact number of cases it declares, and keep the trusted
source fixture beside the oracle. Do not remove repetition merely to make the
oracle DRY: duplicated specification code is often easier to audit than a
general abstraction that can skip or reinterpret cases.

### Straight-Line Oracles

Use `--straight-line-oracles` when an oracle should declare cases without making
runtime decisions. It requires one `comply` function containing only constants,
direct oracle calls, drops, and its final `end`:

```bash
qip comply impl.wasm --with oracle.wasm --straight-line-oracles
```

The validation inspects the final Wasm, not the source language. It permits one
defined `comply` function containing only integer constants, direct calls to
host imports, dropped call results, and the final function end. It rejects
branches, conditionals, selects, loops, local helper calls, indirect calls,
memory instructions, and other executable operations. The oracle may export
only `memory` and `comply`.

This is intentionally narrower than ordinary Content Compliance. Generated or
property-based oracles need control flow and should not use this option. A
straight-line fixture oracle instead declares every case as an unconditional
oracle call. The host records failures and verifies that the constant returned
by `comply()` matches the number of cases it observed.

The CommonMark oracles parse their checked-in text fixtures at Zig comptime.
That parser can branch because it does not become part of the Wasm. An
`inline for` emits the resulting cases as a flat sequence of calls, and the
straight-line oracle validation verifies that the compiler preserved that shape.

This rule applies to the oracle supplied with `--with`, not to the
implementation being tested. See [Hard Limits](/docs/hard-limits) for the
central map of artifact, runtime, and oracle validation.

### Fixture Archives

A future `--with` input can be a TAR fixture archive for straight-line cases
that do not need Wasm oracle logic. This keeps binary inputs and outputs in a
portable format and makes cases easy to inspect with `tar -tf`.

Use one directory per case:

```text
000000_must_render_exactly/input
000000_must_render_exactly/expected
000001_must_trap/input
000002_must_render_exactly__currency.u32=392__font_size.u32=48/input
000002_must_render_exactly__currency.u32=392__font_size.u32=48/expected
```

Case directory grammar:

```text
<ordinal>_<assertion>(__<uniform>)*
```

- `<ordinal>` is a zero-padded decimal case number, contiguous from `000000`.
- `<assertion>` is `must_render_exactly` or `must_trap`.
- `<uniform>` is `<key>.<type>=<value>`.
- `<key>` is a QIP uniform key: 1 to 63 characters, starts with `[a-z]`,
  continues with `[a-z0-9_]*`, does not end with `_`, and does not contain
  `__`.
- `<type>` starts with `u32`. Add `i64`, `f32`, or `f64` only when hosts agree
  on filename-safe value syntax for those types.
- Uniform clauses are explicit per case. They do not inherit from parent
  directories or earlier cases.
- Uniform clauses are sorted by key in canonical archives. Duplicate keys in one
  case are invalid.

A `must_render_exactly` case contains exactly:

```text
input
expected
```

The host renders `input` and compares the output bytes with `expected`.

A `must_trap` case contains exactly:

```text
input
```

The host renders `input` and requires a trap. Unknown entries are errors, not
comments. Archive readers sort paths lexicographically before validation, so TAR
entry order does not affect the result.

## Authoring Strategies

Choose the smallest oracle shape that teaches the contract.

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
  The CommonMark oracle embeds the upstream spec examples and runs them as a
  conformance corpus.

The CommonMark oracle declares all 655 examples from the checked-in 0.31.2
corpus. `commonmark-0.31.2-gfm.wasm` repeats that core corpus, then declares the
22 enabled extension cases extracted from `github/cmark-gfm`. GitHub's two
disabled task-list examples are not treated as executable requirements.

GFM enables its extensions for every document. Its autolink extension changes
the output of four otherwise-valid CommonMark examples containing bare URLs or
email addresses. The GFM oracle therefore reads
`gfm-commonmark-spec-0.31.2.txt`: a copy of the official 0.31.2 corpus with only
those four expected outputs changed. Keeping that difference in the fixture
lets the oracle remain a flat list of assertions without feature branches.

The tradeoff is complexity. A table check is easier to review, but it can miss
whole classes of bugs. A generated oracle covers more space, but it must contain
an independent oracle that is simpler than the implementation under test. If the
oracle re-implements the same complicated algorithm, you have two places
to hide the same mistake.

## Luhn As A Pattern

The Luhn Compliance oracle shows the bridge pattern for an algorithmic oracle:

- It owns its scratch memory, split into input and expected-output regions, and
  passes those ranges to the host bridge.
- It has a small independent oracle, `$make_valid_case`, which computes a valid
  check digit from generated prefixes.
- It varies length, seed, and formatting style, so a small loop covers many
  cases without a large fixture table.
- It declares accepted cases with `qip.must_render_exactly` and rejected cases
  with `qip.must_trap`, using one sequential ordinal space.

That pattern generalizes well. For a validator, generate known-good values,
assert the normalized output, then perturb one property at a time and assert
rejection. For a formatter, generate representative inputs and assert stable
canonical output. For a parser, carry a corpus and include failure messages that
identify the source case.

## Minimal WAT Example

```wat
(module
  (import "qip" "must_render_exactly"
    (func $must_render_exactly (param i64 i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 0) "hello")

  (func (export "comply") (result i32)
    (drop
      (call $must_render_exactly
        (i64.const 0)
        (i32.const 0) (i32.const 5)
        (i32.const 0) (i32.const 5)))
    (i32.const 1))
)
```

## Negative Trap Example

```wat
(module
  (import "qip" "must_trap"
    (func $must_trap (param i64 i32 i32) (result i32)))
  (memory (export "memory") 1)

  (func (export "comply") (result i32)
    (drop
      (call $must_trap
        (i64.const 0) (i32.const 0) (i32.const 0)))
    (i32.const 1))
)
```

## Authoring Workflow

1. Start with the behavior sentence: "This component accepts X, normalizes to Y,
   and rejects Z."
2. Pick the strategy: fixture, table, generated oracle, mutation, or corpus.
3. Keep input, expected output, and must_render_into buffers in oracle-owned memory.
4. Give each oracle call its next sequential ordinal.
5. Build the implementation and compliance module.
6. Run `qip comply impl.wasm --with compliance.wasm`.
7. Add the command to `make -j test` coverage when the contract should protect
   the repo permanently.

## When Not To Use It

Do not reach for `qip comply` when a plain snapshot or unit test would explain
the behavior better. Compliance modules are best when the contract should be
portable across implementations, when a component must reject invalid input in a
specific way, or when the oracle itself can be a useful executable spec.
