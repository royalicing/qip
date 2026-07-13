# Verifier Roadmap Notes

Design answers for three questions about the wasm verifier stack (`qip score`,
`internal/wasminspect`, `modules/application/wasm/wasm-safety-check.zig`).
Written before implementation; nothing here is built yet.

## Can score report maximum loop iterations?

Yes, in tiers. The pieces the loop verifier already extracts (constant step,
exit bound, direction) are two of the three numbers needed for a trip count.

**Tier 1: constant-bounded loops.** When the counter's init is a constant
stored just before the loop, the step is a constant, and the exit bound is a
constant, the trip count is `ceil((bound - init) / |step|)`. Division shrinks
bound at 32 or 64 iterations of the digit loop. The missing piece is init
tracking (a "last constant stored to local X" note, same window machinery as
update detection). Fuel-guarded loops come for free: the fuel init constant
is the bound, so the escape-hatch idiom from [Provable
Loops](../docs/provable-loops.md) yields exact numbers. Output shape:
`function 4 loop 1: max_iterations 4096`. Caveat: for eq/ne exits the count
is only exact with unit steps.

**Tier 2: input-bounded loops.** Most real loops run `i < n` where `n`
derives from `render(input_size)`. A loop bounded by an unwritten local that
is the input_size parameter is `<= input_bytes_cap`, which is a declared
constant per module, so "input-bounded" still resolves to a number. Needs
parameter-provenance tracking (intraprocedural on `render` first,
then through call arguments).

**Tier 3: whole-module worst case.** The strict profile bans recursion, so
the call graph is a DAG. If every loop has a Tier 1 or 2 bound, worst-case
executed instructions per `render` is computable bottom-up: block cost times
the product of enclosing loop bounds, plus callee costs at each call site.
That upgrades score from a heuristic weighting to a certified ceiling
("at most N instructions per render at capacity"). Nested input-bounded
loops multiply into n^2 terms; report the degree honestly rather than a
single misleading number. This is classic WCET analysis made tractable by
the profile: structured control flow, no recursion, no indirect calls.

**Dynamic complement.** A trace-instrument variant that counts actual
iterations per loop for a given input gives observed maxima. Useful to
calibrate fuel budgets and to sanity-check the static ceilings, not a proof.

## Should wasm-safety-check split into multiple modules?

Terminology first: every check in the component is static (pre-execution).
The real split is **local checks** (per-section and per-instruction
allowlists: imports, memory limits, `memory.grow`, atomics, indirect calls,
unknown opcodes) versus **flow analysis** (call-graph acyclicity, loop-bound
evidence).

A two-way split maps onto that:

- `wasm-strict-profile.wasm`: sections, memory rules, instruction allowlist,
  and call-graph acyclicity. Tiny and stable; the rule set rarely changes.
- `wasm-bounded-loops.wasm`: the loop evidence analysis, which is where all
  recent churn happened and will keep happening.

The recursion check folds into strict-profile rather than standing alone,
even though it is graph analysis. Edge collection piggybacks on the decode
pass the allowlist already makes (`call`/`return_call` immediates), the
cycle check is a fixed forty-line three-color DFS, the rule is one binary
fact that never churns, and its soundness depends on a profile rule anyway:
with indirect calls banned, the recorded edges are the complete call graph.
Determinism also puts recursion in the base profile for every tier: without
fuel, runaway recursion ends in stack exhaustion at a host-dependent depth,
so the same input could trap on one host and succeed on another. Even a
fuel-metered tier wants the ban.

What the split buys:

- Policy tiers become pipeline composition. A fuel-metered tier runs
  strict-profile alone; the strict tier runs both stages. Hosts pick stages
  instead of asking the bundle for flags.
- Failure localization. Today one trap covers eight rule families; with
  stages, the failing stage names the family.
- Independent evolution and testing. The profile stays frozen while loop
  analysis grows rules.

What it costs:

- Each stage re-decodes the module. CPU is trivial at these sizes; the real
  risk is decoder drift between copies, which is exactly the bug class fixed
  in the safety-check rewrite. The mitigation is a shared
  `modules/application/wasm/lib/wasm-reader.zig` (the `vnd.sqlite3/lib/`
  pattern) holding the Reader and immediate decoding, imported by every
  wasm-inspecting component. That consolidation is worth doing regardless of
  the split: `wasm-score.zig` and `wasm-trace-instrument.zig` each carry
  their own decoder today.

Done (2026-07-13): the split shipped as `wasm-strict-profile.wasm` +
`wasm-bounded-loops.wasm` on top of a shared `lib/wasm-reader.zig`, and
`wasm-safety-check.wasm` was retired — the two-stage pipeline reproduced its
verdict on every module in the corpus, so the bundle added nothing. The Go
`wasminspect` package remains the diagnostic twin; the shared Zig reader is
the single source of truth for decoding on the component side. Remaining
follow-up: move `wasm-score.zig` and `wasm-trace-instrument.zig` onto the
shared reader too.

## What would it take to verify output length never exceeds capacity?

The invariant already cannot be silently violated at runtime: the CLI host
rejects a render result larger than the declared capacity ("Module returned
more bytes than its stated capacity"). So the question is proving the trap
never fires, or making the artifact self-enforcing on hosts we do not
control. Three rungs, each subsuming the last:

**1. Host runtime checks (exists).** O(1), total, already in the Go runner.
Worth auditing that every host (browser element runners included) performs
the same check.

**2. Enforcement by injection.** A wasm-to-wasm transform in the
fuel-instrument family: wrap `render` so
`if (result > output_bytes_cap) unreachable`. Sound with zero analysis, and
the artifact then enforces its own contract on any host. A heavier variant
instruments every store to check writes land inside
`[output_ptr, output_ptr + cap)`, catching overruns into neighboring buffers
inside linear memory, which wasm itself never protects. Store checking costs
real throughput; it is a CI/debug tier, not a production default.

**3. Static proof.** Proving `render`'s return value is always within
capacity requires value-range analysis: interval tracking per local,
branch-condition narrowing (the common `if (out >= CAP) trap` guard shape),
loop widening informed by the loop bounds we already prove, and
interprocedural summaries over the acyclic call graph. This is the core of
the eBPF verifier, and it is the same engine Tier 2/3 iteration counting
needs. One investment serves several invariants: output length, memory
accesses in bounds, stores confined to the output region, uniform ranges.
The strict profile makes it unusually tractable; qip's constraints are
stricter than eBPF's own.

### Decision (2026-07-13): build the value-range engine

Agreed as the next major verifier investment. One engine, several queries:
loop bounds by arithmetic instead of shape, render-return within output
capacity, store addresses confined to the output region, iteration
ceilings. The strict profile removes the parts that make eBPF's version
hard: no recursion (summaries compose over a DAG), no indirect calls,
structured control flow (joins are block ends), one memory, one entry
point. What remains is the textbook interval analysis: one `[min, max]`
per local and stack slot, transfer functions per opcode, narrowing at
branches, widening at loop headers, fixpoint per function, summaries
bottom-up over the call DAG.

Staging, designed to never break Go/Zig verdict alignment:

1. **Go engine, informational only.** New `qip score` lines
   (`range_proven_loops`, `output_within_cap`) that do not change
   PASS/WARN verdicts. The engine's proofs can be compared against the
   evidence checker's over the corpus while the Zig port does not exist.
2. **Zig port as `lib/wasm-ranges.zig`**, imported by wasm-bounded-loops
   (second prover) and the new `wasm-bounded-output` (contract gate);
   same fixed-buffer discipline, iterative like everything else in the
   checkers.
3. **Verdict flip.** Only when both sides agree over the corpus does
   range-proven become grounds for PASS. The evidence rules stay as the
   fast path; the engine runs where they fail.

Known limits to state up front: intervals are non-relational (`i < j` is
not representable, only their separate ranges), and memory contents stay
unknown unless guarded — commonmark-style memory-resident parser state
remains fuel-tier territory.

Placement: the engine lives in a shared `lib/wasm-ranges.zig` (the
wasm-reader precedent). Ranges alone cannot prove termination — safety
("values stay in bounds") is not progress ("something advances toward an
exit"); `while (true) {}` has bounded values everywhere. So the split is:

- `wasm-bounded-loops` keeps the irreducible variant argument — one local
  whose writes all move one way, plus a matching exit — but rebuilt on the
  engine: the interval of (new − old) per store replaces the entire
  pattern zoo (trace window, tee shapes, copy chains, fused chains,
  small-nonneg, one-sided compares). One rule instead of ten, and it
  accepts a superset of today's modules, so nothing needs porting. The
  must-exit pass stays; it is about exit placement, not values.
- `wasm-bounded-output` asks only the contract question: is the value
  `render` returns provably within the declared output capacity, on every
  path. Named for the fact it enforces, not the interval machinery
  inside. Deliberately out of scope: proving memory accesses in bounds.
  QIP components are told to trap on bad input, and an out-of-bounds
  access already traps deterministically at the wasm boundary — gating on
  trap-freedom would reject modules for following the contract. Store
  confinement to the output region is also wrong as a rule: modules
  legitimately write their own scratch and state buffers.

The tiers then read as sentences. Strict: profile, bounded loops, bounded
output. Metered: profile, bounded output, fuel — "may run long, cannot
lie about its output" — the natural home for parsers and interactive
modules.

### Decision (2026-07-13, revised): wasm components are the gates; Go
### qip score stays

The wasm components are the verdict authority for every host — CLI,
browser, server run the exact same checker artifacts, pinnable by hash.
The Go `qip score` stays, deliberately: its benefits are meaningful — the
prototyping lab (iterate and measure new rules against the corpus in
seconds), rich per-loop diagnostics, and the differential-testing oracle
(a CI test running Go and wasm over the corpus and failing on any
disagreement is what has caught every drift bug so far).

Follow-ups that still apply:

1. The checkers should pass their own checks. The call-graph DFS and a
   few analysis loops are work-stack shapes that need fuel guards before
   wasm-bounded-loops accepts itself. The authority should be self-clean.
2. Host policy flags (max-memory, fixed-memory) can later move onto the
   components as uniforms.

Cheaper invariant wins that need no new engine:

- Postcondition stages: the README already plans `--postcondition`; "output
  is valid UTF-8" is just piping through `utf8-must-be-valid.wasm`.
  Invariants as pipeline stages fit the component model.
- Determinism: NaN bit patterns are wasm's one nondeterminism source. A
  `float_free` line in score (opcode-class check, trivial) would let strict
  integer-only modules advertise bit-exact reproducibility, and flag the
  rest for NaN-canonicalization review.
