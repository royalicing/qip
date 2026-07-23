# A Lightweight Language For Strict-Profile QIP Components

Design notes from a conversation about a new, minimal language that compiles
only to wasm and cannot express a program outside the QIP strict profile.
Nothing here is built; this is a sketch to react to.

## Goal

Make the strict profile ([Hard Limits](../docs/hard-limits.md),
[Provable Loops](../docs/provable-loops.md)) the *type system* rather than a
property you verify after the fact with Zig plus discipline. If it compiles,
it passes `wasm-strict-profile` and `wasm-bounded-loops`. The external wasm
gate stays the trust anchor either way — a compiler bug can't smuggle a
violation past `qip score` — but for a compliant program the compiler's
guarantee should make the gate a formality, not a source of surprise
failures late in the build.

Secondary goal: easy to parse. Keyword-led statements, one declaration per
line, no macros, no operator overloading, define-before-use. LL(1)-ish, a
few hundred lines of recursive descent. This also matters for the drafts on
agentic verification — a language other tools can parse easily is a language
agents can reason about reliably.

## One restriction per profile rule

| Profile rule | Language consequence |
|---|---|
| No ambient imports | No import/FFI mechanism in the general language. The only outside world is the input buffer, declared uniforms, and (for comply components only, see below) the `impl`/`qip` bridge. |
| Declared max memory, no `memory.grow` | No heap, no allocator, no `new`. Every array is a module-level buffer with a compile-time-constant size. The compiler sums buffer sizes and emits `initial == max` memory — fixed memory by construction, not by remembering a linker flag. |
| No indirect calls | No function pointers, no closures-as-values, no dynamic dispatch. Calls are by name. Generics, if any, monomorphize to direct calls. |
| No recursion | Compiler rejects any cycle in the call graph. Cheap to check because there are no indirect calls to obscure it; define-before-use makes acyclicity nearly syntactic. |
| No atomics / shared memory | Nothing to remove — the language has no concurrency model at all. |
| Fixed-bound loops | No general `while`. See below. |

## Loops: only the shapes the verifier already accepts

Rather than offering a general loop and hoping the optimizer preserves a
provable shape (see the LLVM canonicalization failures in Provable Loops,
where the "obvious" fix compiled to an unprovable `i = m` copy), the
language only offers loop forms that compile straight to accepted counter
shapes:

1. **`for i in 0..n`** / **`for b in slice`** — the bound is evaluated once
   into a hidden local before the loop; the induction variable is a
   binding, not an assignable variable, so it cannot be written a second
   way inside the body. Covers most content transforms.
2. **`loop budget n { ... }`** — the general escape hatch. Arbitrary
   `break`/`continue` and arbitrary cursor movement inside, but the
   construct itself emits the monotonic fuel decrement and traps (or runs
   an `else` clause) on exhaustion. This is the fuel idiom from Provable
   Loops made mandatory syntax, so sentinel scans, variable-stride parsers,
   and work-stack loops all fit without the author needing to know the
   verifier's pattern-matching rules.
3. Possibly a built-in fixed-capacity `stack[N] of T` type with trapping
   push/pop, so the recursion-to-explicit-stack transform documented for
   the JSON prettifier example is the idiomatic shape rather than a manual
   migration.

Net effect: the language is deliberately not Turing-complete. Every program
terminates by construction. Anything that genuinely needs unbounded work
belongs in a metered tier, not this one — consistent with the "when not to
bother" section of Provable Loops.

## Codegen: own the backend, don't sit on an optimizer

Emit wasm directly rather than going through LLVM. The provable-loops
failures are the reason: an optimizing backend can rewrite a provably-bounded
loop into a shape the verifier rejects, and the whole point of this language
is that compiling successfully should imply passing. Owning codegen also
keeps the toolchain small, which matches the "lightweight" goal.

This trades away LLVM's optimizations, which fits [[prefer-measured-naive-over-clever]]:
emit boring, predictable code, then `qip bench` it. Strict-tier components
are small transforms where predictable codegen beats clever codegen anyway.

## The ABI as a language construct

Instead of hand-writing `input_ptr` / `output_utf8_cap` / `render` exports
(see [Zig Components](../docs/zig-components.md)), the component declaration
is front matter and the compiler generates the exports and sizes the
buffers, rejecting a program whose declared buffer use exceeds its declared
capacities:

```
component text.transform
input  utf8  cap 64K
output utf8  cap 64K

buf counts: [256]u32

fn render(input: bytes) -> bytes {
    for b in input {
        counts[b] += 1     # bounds-checked; trap on OOB
    }
    ...
}
```

Different component kinds (`text.transform`, `rgba.filter`, the two comply
kinds below) are just different declared signatures the compiler knows how
to lower.

## Semantics details

- Bounds-checked indexing that traps — no raw pointers, only slices over the
  static buffers. Start with runtime checks (measured-naive); a
  Wuffs-style "prove the check away" pass is later optimization work, not a
  v1 requirement.
- Explicit arithmetic: `+` traps on overflow, `+%` wraps, matching Zig and
  mapping 1:1 to wasm.
- Trap is the only failure mode at the component boundary — "fail loudly,
  not wrongly," per Provable Loops' fuel-exhaustion guidance.
- Floats either excluded from v1 or NaN-canonicalized, since NaN bit
  patterns are wasm's one remaining determinism leak.

## Inline tests

Ported from Zig's `test` blocks, and better-behaved here because of the
restrictions above:

- Hermetic by construction. No filesystem, clock, network, or allocator
  means nothing to mock and nothing flaky.
- Total. Test code obeys the same bounded-loop and acyclic-call-graph rules
  as everything else, so the suite provably terminates and the compiler can
  report its worst-case cost.
- Verified as an artifact, not interpreted from source: `qlc test foo.q`
  compiles a test build to wasm (each `test` block becomes a driver case)
  and runs it under the qip runtime, so the semantics tested are the
  semantics shipped.

```
test "empty input is preserved" {
    let out = render("")
    expect out == ""
}

test "trailing spaces trimmed" {
    expect render("abc  ") == "abc"
}
```

`render` is callable from tests because the boundary buffers are static —
the harness writes the input buffer, calls the export, reads the output
buffer, the same loop a comply module runs by hand today. `expect` traps
with the test name and ordinal on failure. Test blocks are stripped from
the production artifact, so they cost nothing against the memory budget.

Tests need one addition to the "no ambient imports" language: a
compile-time **`embed`** declaration for fixture files (`@embedFile`
equivalent). Fine under the profile since embedding happens at build time
and the artifact still imports nothing at runtime. This also covers the
casegen workflow — generated fixture files become embedded tables instead
of a separate imported fixtures module.

## Comply modules as declared component kinds

Comply modules are the deliberate, already-documented exception to "no
imports" ([Hard Limits](../docs/hard-limits.md), [qip comply](../docs/comply.md)).
Rather than opening a general import mechanism, each comply protocol in the
repo becomes its own declared component kind, and the compiler emits exactly
the allowlisted imports and required exports for that kind — nothing else
is reachable from language code.

**Classic `--with` checkers.** The kind declaration gives typed access to
the implementation and generates the `impl.*` imports plus
`positive()`/`negative()`:

```
comply component "trim-preserves-empty"

positive {
    expect impl.render("") == ""
    expect impl.render(" a ") == "a"
}

negative {
    must_trap impl.render("\xFF\xFE")
}
```

The manual scratch-memory choreography `comply.md` describes — check
capacity is at least 512 bytes, write input at `input_ptr`, expected output
at `input_ptr + 256`, compare — is exactly the kind of protocol a compiler
should own instead of an author re-deriving per module. The language
exposes `impl.render(bytes) -> bytes` as a plain call; the compiler emits
the capacity check, buffer writes, and comparison, and wires `must_trap` to
the host's `qip.render_must_trap`. Bugs like scratch-region overlap or a
missing capacity check stop being things an author can get wrong.

**Bridge-style declare-cases modules** (the newer shape used by
`compliance/unicode-17-lowercase.comply.zig`: component owns its own
memory, imports `qip.render_must_equal` / `qip.render_examine*`, tracks
ordinals itself):

```
comply cases "unicode-17-lowercase"
uniform seed: u32 = 17

cases {
    for c in embed_cases("fixtures/lowercase.cases") {
        must_equal(c.input, oracle(c.input))
    }
    var rng = xorshift32(seed)
    repeat 64 times {
        let input = gen_biased(rng)   # sigma-biased generator, in-language
        must_equal(input, oracle(input))
    }
}
```

Ordinal bookkeeping (manual `ordinal += 1` in the Zig version) becomes
compiler-managed. A seeded-PRNG builtin belongs in the prelude, since
deterministic fuzzing is the only randomness the model should permit at
all.

Comply modules still obey the strict profile otherwise — bounded loops, no
recursion, fixed memory, declared maximums. That suggests a natural
companion on the verifier side: a **comply profile**, the strict profile
with the import allowlist widened to exactly `impl.*` and the `qip.*`
bridge, shippable as a third gate component alongside
`wasm-strict-profile` and `wasm-bounded-loops` so comply artifacts get the
same artifact-level check as normal components.

### Where tests and comply modules meet

An inline `test` and a comply case are both "(input, expected) against the
public ABI." That suggests the compiler could **export a component's
inline tests as a `.comply.wasm`** directly. Cases get written once; in dev
they run as the fast inline suite, and the same cases become a contract
artifact `qip comply` can run against a different implementation of the
same interface — a rewrite, a size-optimized version, next year's spec
update.

Caveat, straight from `comply.md`'s double-entry-accounting framing: tests
exported from an implementation's own source carry that implementation's
biases. Promotion-to-comply is a convenience tier, not a substitute for
independently authored comply modules like the UCD-oracle ones — those
should stay hand-written under the `comply cases` kind above, derived from
the spec rather than from the implementation being checked.

## Ideas from Jai

Jonathan Blow's Jai is unreleased/beta with no fixed public spec, so treat
this as a set of ideas to adapt, not syntax to copy. Several fit this
language unusually well because Jai's whole ethos — explicitness, no hidden
control flow, no hidden allocation — is a milder version of what the strict
profile already forces here.

**Compile-time execution folds `tools/casegen` into the compiler.** Jai's
`#run` executes arbitrary code at compile time and bakes the result into
the binary — used in Jai itself to generate lookup tables, parse data
files, even run the compiler's own tests. That maps directly onto a problem
this repo already has: `compliance/unicode-17-lowercase.comply.zig` imports
a separately generated `unicode-17-lowercase-fixtures.zig`, produced ahead
of time by `tools/casegen` from UCD data. A `#run`-equivalent lets that
become in-language:

```
const lowercase_table = #run generate_from_ucd(embed("UnicodeData.txt"))
```

This doesn't weaken "no ambient imports" — `#run` executes on the host
during compilation, with the host's full capabilities, and only its
*output bytes* are baked into the artifact. The artifact itself still
imports nothing at runtime. It does mean the compiler needs a safe-enough
host-side interpreter for the subset of the language used at compile time,
which is new work, but it replaces an external generator script plus a
"do not edit, regenerate with casegen" file with one buildable artifact.

**Compile-time `#assert` for capacity math.** The lowercase comply module
has a load-bearing comment: `// Worst-case growth is 1.5x; give the oracle
and examine buffers 3x slack.` That's an invariant a comment can't enforce.
Jai's `#assert` (or C11 `static_assert`) checked at compile time turns it
into something the compiler verifies on every build:

```
buf expected_buf: [MAX_INPUT * 3]u8
#assert MAX_INPUT * 3 >= MAX_INPUT * 1.5   # oracle growth bound, with slack
```

Cheap to add, and it directly prevents the class of bug where someone
changes `MAX_INPUT` and forgets the buffers sized off it.

**Baked polymorphism, not generics-via-indirection.** Jai's `proc :: (x: $T)`
generic procedures are instantiated per call-site type at compile time —
no vtable, no boxing, no indirect call. That's the only kind of generics
compatible with "no indirect calls" from the profile table above, so it's
worth adopting as the concrete model rather than inventing one: a generic
`fn max(a: $T, b: $T) -> T` monomorphizes into one direct-call function per
`T` actually used, same as Jai, same as Zig's `comptime`.

**Multiple return values instead of exceptions, trap reserved for the
boundary.** Jai has no exceptions; a fallible procedure returns `(value,
success: bool)` and the caller checks it. Worth using for *internal*
fallibility — a number parser, a table lookup — so a recoverable "this
substring isn't a valid integer" doesn't have to trap the whole component.
Trap stays reserved for actual contract violations: capacity overflow, fuel
exhaustion, malformed input past the point the format says is impossible.
That's a slightly more precise version of the "trap is the only failure
mode" line from the semantics section above — trap is for the boundary
contract, `(value, ok)` is for ordinary control flow inside it.

**`defer` for push/pop discipline.** No heap means no destructors to run,
but `defer` still earns its keep around the explicit `stack[N] of T` from
the loop section: pairing a push with `defer pop()` keeps the recursion-to-
loop migration from Provable Loops honest, the same way `defer` keeps
Jai's manual arena allocations balanced without RAII.

**Deliberate divergence: don't strip bounds checks in release.** Jai checks
array bounds in debug builds and strips the checks in release for speed.
This language should not do that — the trap-on-OOB checks are part of the
strict-profile safety story, not a debug convenience, so they stay in every
build regardless of optimization level. If a specific component's bounds
checks turn out to matter for performance, that's a `qip bench` question
([[prefer-measured-naive-over-clever]]), not a default to flip globally.

**One-line validation of the parsing goal.** Jai's compiler avoids header
files and forward-declaration order dependencies in favor of a simpler,
faster, single-pass-feeling model — different mechanism than this
language's define-before-use rule, but the same instinct: a language and
compiler that get out of the way of iteration speed. Worth citing as
existing precedent that the "easy to parse" goal isn't just this project's
own preference.

## Certified `qip score` at build time, for free

Because the call graph is a DAG and every loop's bound is chosen by the
compiler rather than pattern-matched after optimization, the compiler can
compute at build time what the [Verifier Roadmap](verifier-roadmap.md)
describes as Tier 3 for the external checker: max memory (exact), max call
depth (exact), and max instructions per `render` at declared input
capacity. The build output can *be* the `qip score` manifest, rather than
something a separate static pass has to reconstruct from a binary that may
or may not have preserved provable shapes through optimization.

## Prior art to study before building anything

- **Wuffs** (Google) — no allocation, no FFI, bounds proven at compile
  time. Targets C, and does not require termination, so the loop story
  differs.
- **eBPF verifier** — the bounded-loop evidence rules already borrow its
  spirit; worth re-reading the verifier's loop-bound proof directly.
- **Total languages** (Dafny and similar) — for the termination-checking
  discipline generally, though those aim at proof, not at a tiny
  single-target compiler.
- **Jai** (Jonathan Blow, unreleased/beta) — compile-time execution,
  baked polymorphism, and no-hidden-control-flow ethos; see "Ideas from
  Jai" above for specifics.

The combination that looks novel here: total + first-order + static memory
+ wasm as the only target + an external artifact verifier as the actual
trust anchor rather than the compiler. Keeping trust in the `.wasm` gate
instead of the compiler is the part worth preserving even as the rest of
this design changes.

## Biggest known cost

No standard library. Every component starts from bytes and integers, so
common helpers (UTF-8 decode, integer formatting, the sigma-biased fuzz
generator shape used in the Unicode comply module) need to ship as language
builtins or a small audited prelude. That prelude is probably the largest
real chunk of work in this design, bigger than the compiler frontend or the
wasm backend.
