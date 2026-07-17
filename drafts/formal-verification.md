# Formal Verification of QIP Components — and a Verifier That Is Itself Wasm

Status: draft research, 2026-07-12. Companion: [agentic-verification.md](agentic-verification.md) covers how these checks should be scheduled when components are written by coding agents.

## Where things actually stand in this repo

QIP already practices three distinct layers of verification, without calling them that:

- **`drafts/cbmc/base64-encode-bounds.c`** — a CBMC bounded-proof harness that proves the base64 size arithmetic (`full_groups * 4 + tail padding`) never exceeds `QIP_OUTPUT_UTF8_CAP` for *all* inputs up to the cap, using nondeterministic inputs, loop invariants, and `__CPROVER_decreases` ranking functions. This is real deductive verification of a *model* of the component.
- **`components/application/wasm/wasm-safety-check.wasm`** — an eBPF-verifier-style *syntactic* checker that is itself a QIP Content component (`application/wasm` in → same bytes out, trap on violation). It proves loop bounds from monotonic-counter evidence, rejects recursion via call-graph acyclicity, and enforces the strict profile (no imports, no `memory.grow`, no atomics, no indirect calls).
- **`internal/wasminspect` / `qip score`** — the Go mirror of the same analysis, reporting WARN instead of rejecting.

So the two questions this document asks — "can existing tooling verify component wasm?" and "can a verifier be written in wasm?" — both already have embryonic *yes* answers in-tree. The question is how far each ladder goes up.

## Why QIP components are an unusually good verification target

Formal verification of general software dies on four things: unbounded loops, unbounded memory, ambient effects, and dynamic dispatch. The strict profile ([docs/hard-limits.md](../docs/hard-limits.md)) removes all four:

| General wasm obstacle | QIP strict profile |
|---|---|
| Unbounded heap via `memory.grow` | banned — memory is a fixed, statically known size |
| Nonterminating loops | every backedge must show a proven bound |
| Recursion | call graph must be acyclic |
| Indirect calls / function pointers | `call_indirect`, `call_ref` banned |
| Host imports with arbitrary semantics | zero imports |
| Concurrency | no threads, no atomics |

The consequence is worth stating precisely: **a strict-profile component is a finite-state machine with a computable upper bound on execution length.** Acyclic call graph + bounded loops ⇒ a finite maximum instruction count per `render()` call, derivable from the same evidence `wasm-safety-check` already extracts. That means *bounded model checking is complete, not just a bug hunt*: if CBMC-style unwinding covers the (finite, known) bound and finds no counterexample, the property holds for all inputs — no "unwinding assumption" caveat. For general programs BMC is a lens; for strict QIP components it is, in principle, a decision procedure. (In practice state-space size still bites; see costs below.)

The properties worth proving, roughly in order of value per effort:

1. **No traps for any valid input** (`input_size ≤ cap` ⇒ `render` returns). Wasm itself guarantees a trap can't escape the sandbox, but for pipeline components a trap is a broken recipe.
2. **Output-length safety**: return value ≤ output cap, and all writes land inside `[output_ptr, output_ptr + cap)`. This is exactly what the CBMC base64 harness proves for one component.
3. **Termination with an explicit bound** — already approximated syntactically; a semantic tool can prove bounds the syntactic checker rejects.
4. **Render idempotence / statelessness**: two `render()` calls with the same input bytes and uniforms produce the same output (the contract in [docs/component-contract.md](../docs/component-contract.md) demands this; mutable globals and scratch state can silently violate it).
5. **Functional correctness** against a spec (round-tripping, parser correctness). Highest cost, reserve for load-bearing components.

One determinism footnote the profile doesn't currently cover: wasm NaN *bit patterns* are nondeterministic across engines. A component that stores raw float results into output bytes can violate "same input, same output" across hosts. Either ban float→byte flows in the strict profile, require NaN canonicalization, or document it.

### The render obligations — candidate formal contract

The informal list above is prioritization; this is the candidate *canonical obligation list* — the machine-readable form of the contract that the conformance suite, the harness generator, and the proofs should all reference. Notation: `ip`/`ic` = input pointer/cap, `op`/`oc` = output pointer/cap, `N` = linear memory size, `n` = input size, `m` = render's return value.

Two-level input quantification, which keeps O3 falsifiable: an input is **permitted** when `n ≤ ic` (a host-level size fact), and **valid** when it satisfies the component's *declared validity predicate* (a component-level content fact, e.g. "well-formed UTF-8" — which must be machine-readable per component, else every trap can be retroactively excused as "the input must have been invalid" and a bug is indistinguishable from a rejection).

For every permitted input and every uniform assignment within declared ranges:

- **O1 — Region well-formedness.** `ip + ic ≤ N` and `op + oc ≤ N`, with no 32-bit wraparound in either sum. Statically checkable at load time — the exports are constant functions — so this belongs in `wasm-safety-check`, not only in proofs.
- **O2 — Bounded termination.** `render(n)` terminates within the declared execution budget (the fuel bound from the certificate story below).
- **O3 — Total or honestly partial.** `render` either (a) traps, and the input violates the declared validity predicate; or (b) returns `m ≤ oc`.
- **O4 — No memory-access traps.** Every load and store is provably in bounds. (Wasm semantics already guarantee containment — an out-of-bounds access traps rather than escapes — so "stays in linear memory" is a tautology at runtime; the verification property is the *absence of the trap*, which is what keeps O3(b) reachable.)
- **O5 — Write-set discipline.** Stores land only in the declared output, scratch, and explicit persistent-state regions.
- **O6 — Information-flow discipline.** `output[0:m]` depends only on `input[0:n]`, explicit uniforms, declared persistent state, and immutable module data. The `[0:n]` slice matters: stale bytes between `n` and `ic` left by a previous longer render must not influence output — exactly what the sentinel-byte test in the noninterference section detects.
- **O7 — Deterministic replay.** Repeating the call from an equivalent pre-state produces equivalent output and equivalent observable post-state, where *equivalent* means byte-equality over declared regions with scratch excluded. Scoped per-engine; cross-engine is O8.
- **O8 — Cross-host determinism.** O7's equality holds across conforming engines. This is where NaN bit-pattern nondeterminism lives: a component can satisfy O7 on every engine individually while violating O8. Discharged by banning float→byte flows, requiring NaN canonicalization, or proving floats never reach output.

O5 and O6 factor cleanly: O5 restricts *where writes go*, O6 restricts *where information flows from* — loads need no restriction because O6 already bounds their influence.

Two consequences for the existing contract, both new surface:

1. **O5 requires region declarations that don't exist yet.** Today's contract declares only input and output regions; scratch and persistent state would need exports (`scratch_ptr`/`scratch_cap`, …) or a custom section. It also collides with [drafts/output-slice-optimization.md](output-slice-optimization.md): in-place output has `output_ptr` aliasing the input buffer, so "stores limited to declared output" and "input is host-owned" must be reconciled by declaration (e.g. the input region is declared writable-after-read for aliasing components).
2. **O6's "declared persistent state" quietly legalizes stateful components** (memoizers, caches). Fine — but that state must then appear in O7's pre-state definition and in the conformance tests, or the statefulness is unobservable and unverifiable.

### Open contract decisions (blockers, not caveats)

Three of the obligations can't be checked until a contract decision is made. Each blocks a specific downstream artifact:

1. **Validity-predicate format** (for O3a). How does a component declare what inputs it rejects — a named predicate in a custom section? a companion spec file? a reserved export? *Blocks:* the generated conformance harness (can't distinguish bug-trap from rejection-trap) and any "no traps for valid input" proof.
2. **Region declarations** (for O5/O6). How do components declare scratch and persistent-state regions, and how does the declaration reconcile with in-place output aliasing? *Blocks:* the write-set assertions in both the Owi harness and the instrumenter's runtime-verification mode, and consequence 2's stateful-component testing.
3. **Float determinism policy** (for O8). Ban float→byte flows in the strict profile, require NaN canonicalization, or accept per-engine scope and document it? *Blocks:* honest wording of the cross-host determinism claim, and decides whether the cross-engine differential suite treats NaN-payload diffs as failures.

Simplest defaults if deciding today: (1) start with a small enum of named predicates (`any-bytes`, `utf8`, `wasm`, …) in a custom section, growing as needed; (2) two optional exports mirroring the existing `*_ptr`/`*_cap` convention, with aliasing declared rather than inferred; (3) canonicalize NaNs at the component boundary — it's the only option that keeps O8 both true and checkable.

## Ladder 1 — Existing tooling against component wasm

### Source-level (verify what you wrote)

- **CBMC** (in use). Cheap to extend, mature, great counterexamples. The structural weakness of the current setup: `base64-encode-bounds.c` is a *hand-ported model* of Zig code — the proof can drift from the shipped artifact and nobody notices. Fine for arithmetic lemmas; not a trust anchor.
- **Kani** (CBMC-based, Rust) — only relevant if Rust components ever appear; the repo's Zig preference rules it out today.
- **Zig has no verification tooling.** No Frama-C, no Kani equivalent. This is the strongest argument for verifying at the *binary* level instead: the language choice stops mattering.

### Binary-level (verify what you ship) — the best fit for QIP's trust model

QIP's whole pitch is that the `.wasm` artifact is the unit of trust and review. Verification should target the same artifact:

- **[Owi](https://github.com/OCamlPro/owi)** (OCamlPro) — the standout candidate. A symbolic interpreter for wasm binaries with parallel path exploration, built for bug finding *and* verification, actively developed ([paper, 2025](https://arxiv.org/abs/2412.06391)). The natural QIP harness: mark the `input_ptr` region and `input_size` symbolic (with `input_size ≤ cap` assumed), run `render`, assert the return value and write-set stay inside the output region. Because strict-profile loops are bounded, symbolic execution *terminates* — path explosion is the only enemy, and it's tamed by verifying with a reduced symbolic cap (e.g. 64–512 symbolic bytes) while relying on the CBMC-style arithmetic lemmas for the full-cap size math. That two-tool split — Owi for control-flow/memory behavior on small symbolic inputs, CBMC for the size arithmetic at full caps — covers most of properties 1–3 today.
- **[Certora Sunbeam](https://docs.certora.com/en/latest/docs/sunbeam/index.html)** — proves user-written specs *at the wasm bytecode level* for Soroban smart contracts ([case study](https://www.certora.com/blog/formally-verifying-webassembly)). Proprietary and blockchain-focused, so not a tool to adopt — but it's the industrial existence proof that spec-driven verification of wasm bytecode works on real code, and Soroban's constraints (deterministic, bounded, no ambient I/O) are strikingly close to the QIP profile. QIP components are arguably an *easier* target.
- **[KWasm](https://odr.chalmers.se/server/api/core/bitstreams/a06be182-a12e-46ce-94d3-cff7a5dc42ba/content)** (K framework), **Eunomia**, SeeWasm, Manticore's wasm mode — research-grade; worth tracking, not worth integrating first.

### Foundations (verify the rules of the game)

The wasm spec itself is formally specified, and as of March 2025 the standard's formal parts are generated from **[SpecTec](https://webassembly.org/news/2025-03-27-spectec/)**, a mechanized DSL. **WasmCert-Coq/Isabelle** mechanize the semantics; **[Iris-Wasm](https://dl.acm.org/doi/abs/10.1145/3591265)** is a separation logic proving *robust safety* — adversarial modules can only interact through explicit exports, which is a machine-checked version of QIP's isolation story. None of this is tooling to run in CI, but it's citable ground truth: wasm validation (which every host already runs) is itself a soundness-proven type check, so every QIP component passes a lightweight formal verification before its first instruction executes. `wasm-safety-check` extends that layer; heavier tools extend it further. It's one ladder, not a separate discipline.

### Concrete integration sketch

```
qip verify components/utf8/base64-encode.wasm \
    --symbolic-input-cap 256 \
    --assert no-trap,output-cap,write-set
```

Implementation-wise: a `qip verify` subcommand that shells out to (or embeds) Owi with a generated harness derived from the component contract exports — the contract is uniform, so *one* harness template covers every Content component. Per-module functional specs, when wanted, live next to the module (`base64-encode.spec.wat` or assume/assert pairs). Start by wiring the three components with the trickiest loop structure through it and benchmarking wall-clock cost, per the measured-naive rule — if 256 symbolic bytes takes minutes, that decides the CI-vs-nightly question empirically.

## Ladder 2 — A verifier written in WebAssembly

The instrumenter precedent (`wasm-trace-instrument`, per [drafts/trace-instrumentation.md](trace-instrumentation.md)) established the load-bearing pattern: wasm-analyzing tools as QIP Content components, so any host — including a browser, client-side — can run them. The verification ladder has four rungs of ambition:

**(a) Syntactic/structural checking — shipped.** `wasm-safety-check` is already a formal verifier in the same sense the eBPF verifier is one: a sound (conservative, incomplete) static analysis with rejection on failure.

**(b) Full wasm validation (type-checking) as a component — very feasible, high value.** The validation algorithm is precisely specified, single-pass, and needs only bounded stacks — it fits static buffers and the strict profile comfortably. A `wasm-validate` component in Zig (or `wasm-tools validate` compiled to wasm32, though Rust+allocator is heavier than a bespoke Zig pass) would mean a QIP host can *formally type-check a module using a module*, with no toolchain dependency. Natural pipeline: `wasm-validate.wasm | wasm-safety-check.wasm`.

**(c) Abstract interpretation — the sweet spot, and the natural next component.** Value-range analysis over locals/globals can prove properties the syntactic checker can't: return value ≤ output cap, address operands of every store within the output region, loop bounds established through arithmetic rather than pattern-matched counter shapes. Abstract interpretation is deterministic, terminates by construction (finite lattice + widening), needs memory proportional to function size — it fits the QIP contract *exactly*. This is the eBPF verifier's actual trajectory (tnum/range tracking) and the measured-naive path: no SMT solver, no search, just a fixpoint loop over bytecode. Rough shape: `wasm-range-check.wasm`, input `application/wasm`, output same bytes on success, trap with diagnostics otherwise; shares section-walking code with `wasm-safety-check`.

**(d) SMT-backed verification in wasm — possible, but not as a strict component.** The solvers themselves already run as wasm: [Z3 ships official wasm builds on npm](https://www.npmjs.com/package/z3-solver) and [cvc5 compiles via emscripten](https://cvc5.github.io/docs/latest/installation/installation.html) — browser-hosted verification playgrounds are a solved problem. But a Z3-class solver as a *strict QIP component* fails the profile on every axis: multi-megabyte module, dynamically growing memory, unbounded runtime, internal randomness/timeouts. Two honest resolutions:

   1. **Relax, don't pretend:** run the solver as ordinary wasm in the host (browser page or CLI), outside the component boundary — the *harness generator* can still be a QIP component that turns `component.wasm` into an SMT-LIB query (bytes in, bytes out, fully deterministic).
   2. **Shrink the solver:** a small CDCL SAT solver in Zig with static arenas and a *conflict-count* limit instead of a time limit (no clock ⇒ the QIP contract forces reproducible solving, which is a genuinely nice property — solver nondeterminism is a chronic reproducibility headache elsewhere). Input DIMACS, output SAT+model / UNSAT / trap-on-limit. Bit-blasting bounded wasm semantics to SAT is classical BMC. This is a fun, decomposable build but a research project; don't start here.

**The strongest wasm-verifier idea is neither: proof *checking*, not proof *finding*.** Split the trust story the way proof assistants do (the de Bruijn criterion): an untrusted, heavyweight prover runs anywhere — Owi, Z3, CBMC, native, cloud, doesn't matter — and emits a certificate; a small, deterministic, bounded *checker* validates the certificate, and *that checker is a QIP component*. Concrete instances:

- A **DRAT/LRAT proof checker** (for SAT-backed proofs) — LRAT checking is nearly linear, allocation-light, and has been implemented in a few hundred lines; ideal component material.
- A **loop-bound certificate checker**: instead of `wasm-safety-check` re-deriving bounds from pattern evidence, the build pipeline emits a custom section (`qip.bounds`: per-loop counter local, step, limit, ranking function) and a component checks each claim locally — checking an invariant is drastically simpler than inferring it, so the checker stays small while the *claims* can come from arbitrarily clever offline tools. This inverts the current design's hardest problem (the pattern-matcher's incompleteness) into someone else's problem.

That last design composes with everything above: CBMC or Owi finds the invariants offline once, the certificate travels inside the `.wasm` as a custom section (surviving distribution), and any browser host re-checks it in milliseconds with a component. Verification becomes portable the same way execution already is — which is the QIP thesis applied to proofs.

## The security & QA perimeter — what per-component proofs silently assume

Everything above proves properties of one component at a time. Those proofs rest on assumptions the repo doesn't currently check: that the binary matches the reviewed source, that the checker is sound, that engines agree, that the rewriter preserves semantics. Verifying the perimeter is mostly cheaper than verifying components — and worth more. Roughly ordered by payoff per effort:

### 1. Reproducible builds — verify the artifact matches the source

The `.wasm` binaries are checked in alongside their `.zig` sources; people review the Zig, but hosts execute the wasm. A CI job that rebuilds every module with a pinned Zig version and asserts byte-identical output closes the biggest supply-chain gap in the current model. It's formal verification's cheap cousin — an equality check, not a proof — and probably the single highest security value per line of CI.

### 2. Red-team the verifier itself

`wasm-safety-check` is a soundness-critical trust boundary: if a handcrafted module can fool the loop-evidence pattern matcher (a counter that looks monotonic but is also written through a derived local; an exit comparison on a different local than the one stepped), the result is an "approved" nonterminating module. Maintain an adversarial corpus of near-miss modules — each a documented attempted bypass, asserted to be *rejected*. This is the eBPF verifier's own QA practice, and eBPF's CVE history maps exactly where this class of checker breaks.

Related cheap win: differential-test the Zig component against `internal/wasminspect`. The source comment says "keep the two in sync" but nothing enforces it — feed both the same corpus; any accept/warn disagreement is a latent soundness hole in one of them.

### 3. Cross-engine differential testing of the determinism promise

"Same component, same input, same output — on any host" is the central claim, and it's directly testable: run every module on the Go CLI's runtime, wasmtime, and at least one browser engine over a shared input corpus and assert byte-identical outputs. This is how the NaN-bit-pattern nondeterminism gets *found* rather than theorized about. ([WRTester](https://arxiv.org/pdf/2312.10456) is the research version of this idea, aimed at runtime bugs; here the target is the determinism contract.)

### 4. Fuzz the wasm-consuming components hardest

`wasm-safety-check` and `wasm-trace-instrument` are binary parsers of attacker-supplied input — structurally the riskiest code in the tree. Two feeds: [wasm-smith](https://github.com/bytecodealliance/wasm-tools/tree/main/crates/wasm-smith)-style generated *valid* modules (exercises the analysis logic), and mutated/malformed bytes (exercises the parser's trap paths). The oracle is simple because components trap rather than corrupt: never accept-and-emit anything a reference validator rejects.

### 5. Translation validation for the instrumenter

`wasm-trace-instrument` rewrites modules, and [drafts/trace-instrumentation.md](trace-instrumentation.md) is candid that index-shifting bugs "validate but call the wrong function — the worst failure class." Pragmatic check: for every corpus module, run original and instrumented side by side on the same inputs and assert identical outputs (ignoring trace events). That's differential testing today and the on-ramp to real translation validation later.

### 6. Contract-conformance suite generated from a machine-readable contract

The component contract (call `render` before `output_ptr`, return current not cumulative length, repeated renders must be deliberate, content-type composition rules) lives as prose. The render obligations O1–O8 above are the precise form; one generated harness can then test their observable faces against *every* module in the catalog:

- render twice with same input → same bytes (O7);
- render A, B, A → third output equals the first (O6/O7 — catches state leaks between renders, which the contract explicitly worries about);
- returned length ≤ output cap (O3b);
- trap rather than truncate on overflow (O3a);
- sentinel bytes beyond `input_size` never surface in output (O6's `[0:n]` slice).

One harness, whole catalog, runs forever in CI. This also gives the Go CLI and the JavaScript runner a shared host-side conformance target.

### 7. Resource-bound certificates

`wasminspect` already counts instructions, loops, and call edges. Extend it to publish a per-component worst-case fuel bound (derivable once loop bounds are proven), and have hosts enforce it with fuel metering. That converts `--timeout-ms` — a wall-clock heuristic that varies by machine — into a deterministic, portable limit, and gives users a reviewable "at most N instructions" claim. Composes directly with the `qip.bounds` certificate idea above.

### 8. Runtime verification as a middle ground

The trace instrumenter could grow an assertion mode: inject checks that every store lands within `[output_ptr, output_ptr + cap)` and that input memory isn't written during render, then run the test corpus through instrumented builds in CI. Not a proof — it covers only exercised paths — but it checks the real semantic property on the real artifact with tooling already in-tree, which beats an unwritten proof.

### Deliberately out of scope (say so explicitly)

- **Constant-time / side-channel properties.** QIP components shouldn't process secrets; document that as a non-goal rather than leaving it ambiguous.
- **Verifying the Go/JS hosts.** Much bigger surface, weaker tooling; the conformance suite in item 6 is the practical substitute.

The meta-pattern: items 1–5 verify the assumptions every per-component proof stands on. Proofs about components are only as trustworthy as this foundation.

## High-assurance and enterprise: the NASA lens

NASA/JPL's ["Power of Ten" rules for safety-critical code](https://spinroot.com/gerard/pdf/P10.pdf) (Holzmann, 2006) and the QIP strict profile are nearly the same document — and QIP enforces its half *mechanically, on the shipped binary*, where JPL relies on source-level static analysis and review:

| Power of Ten rule | QIP strict profile |
|---|---|
| 1. Simple control flow, no recursion | recursion banned (acyclic call graph); wasm has no `goto`/`setjmp` |
| 2. Fixed upper bound on every loop | enforced by `wasm-safety-check` |
| 3. No dynamic allocation after init | no `memory.grow`; static buffers |
| 9. Restrict pointers; no function pointers | no `call_indirect` / `call_ref` |
| 4. Short functions · 5. Assertion density · 10. Zero-warning gate | **gaps — all cheap `qip score` additions** (function-size limit, trap-site density metric, `--fail-on-warn` CI gate) |

Being *binary-level* Power of Ten is stronger than the original: it holds regardless of source language and can't drift from the artifact. Worth stating explicitly in positioning docs. The rest of this section is what a high-assurance reviewer would ask for next.

### Bound the stack — the missing hard limit

QIP bounds memory (fixed), time (loop bounds → fuel), and I/O (caps), but not the call stack — the first thing a flight-software reviewer asks about. The strict profile makes worst-case stack *statically computable*: the call graph is acyclic, so max call depth is the longest path in a DAG, and per-function frame cost is estimable from locals plus value-stack shape. `wasminspect` already builds the call graph for recursion detection; extending it to report "max call depth ≤ N, worst-case stack ≈ K bytes" completes the claim that **every resource a component consumes has a pre-execution bound** — the wasm analog of avionics WCET analysis, and a limit almost no other platform can state honestly.

### Cross-render noninterference

The contract lets hosts reuse one instance across many renders, and Zig components use `undefined` static buffers — so can bytes from render N−1 leak into render N's output via a stale-length bug or uninitialized scratch? In a pipeline pushing different users' data through a shared instance, that's an information-disclosure bug class. Testable now: render sentinel-filled input A, then short input B; scan B's output for A's bytes, across the whole corpus. Provable later: noninterference is exactly what the [Iris-Wasm](https://dl.acm.org/doi/abs/10.1145/3591265) line formalizes. This is obligation **O6** — the upgrade from "same output for same input" (O7) to "output depends *only* on `input[0:n]`, uniforms, and declared persistent state."

### Evidence bundles — what enterprise procurement actually buys

High-assurance regimes (DO-178C, NASA IV&V, FedRAMP) demand *auditable evidence*, not just correct software. QIP can generate it automatically per component: a signed manifest bundling source hash, pinned toolchain version, reproducible-build attestation, `wasm-safety-check` verdict, score report, stack/fuel bounds, proof certificates (`qip.bounds`), and conformance-suite results — SLSA-style provenance plus verification evidence, carried as a custom section or sidecar, signed via [Sigstore](https://www.sigstore.dev/) or wasm-native [wasmsign2](https://github.com/wasm-signatures/wasmsign2). Adjacent cheap wins:

- **SBOM**: a zero-dependency component's SBOM is trivially empty — itself a headline claim; emit it in CycloneDX form so enterprise scanners can consume the *absence*.
- **Coverage evidence**: the instrumenter's planned branch-tracing mode ([drafts/trace-instrumentation.md](trace-instrumentation.md)) doubles as a coverage tool. DO-178C Level A requires MC/DC; "our tests exercised every branch decision *of the shipped binary*" is rare air.
- **Policy-as-code**: ship `qip score` policies as named, versioned profiles (`strict`, `power-of-ten`) so CI gates cite a documented policy, not folk knowledge.

### Two smaller items

- **Traceability matrix**: requirement → property → proof/test evidence, auto-generated from the specs and evidence manifests. DO-178C reviewers live in these tables.
- **Decade-scale reproducibility**: NASA missions outlive toolchains. Pin *and archive* the exact Zig compiler alongside the repo so "rebuildable in 2036" is a checkable claim; wasm's backward-compatibility record is unusually strong here.

## Recommended order of experiments

Three items are cheaper than everything below and should land first: **reproducible builds in CI** (perimeter 1), the **Go-vs-Zig checker differential test** (perimeter 2), and **static stack-depth bounds in `wasminspect`** (NASA-lens section) — each is roughly a day and either hardens the foundation the rest stands on or completes the hard-limits story. Then:

1. **Owi harness spike** (existing tooling, days): symbolic `render` harness for 2–3 shipped components; measure wall-clock vs symbolic input size; write down where it breaks.
2. **`wasm-validate` component** (rung b, ~same size as safety-check): completes the "hosts need no toolchain" story.
3. **Range-analysis component** (rung c): the biggest capability jump per line of code; subsumes parts of the loop-evidence pattern matcher.
4. **Bounds-certificate custom section + checker** (the inversion): design doc first — it changes what `wasm-safety-check` and `qip score` need to be.
5. SMT/SAT-in-a-component: only after 1–4 prove insufficient.

## Sources

- [Owi: Performant Parallel Symbolic Execution Made Easy, an Application to WebAssembly (arXiv 2024/2025)](https://arxiv.org/abs/2412.06391) · [GitHub](https://github.com/OCamlPro/owi) · [project site](https://ocamlpro.github.io/owi/)
- [Certora — Formally Verifying WebAssembly: A Soroban Case Study](https://www.certora.com/blog/formally-verifying-webassembly) · [Sunbeam docs](https://docs.certora.com/en/latest/docs/sunbeam/index.html) · [Blend V1 verification report](https://www.certora.com/reports/blend-smart-contract-verification-report)
- [SpecTec has been adopted (webassembly.org, 2025-03-27)](https://webassembly.org/news/2025-03-27-spectec/) · [Bringing the WebAssembly Standard up to Speed with SpecTec (PLDI 2024)](https://dl.acm.org/doi/10.1145/3656440)
- [Iris-Wasm: Robust and Modular Verification of WebAssembly Programs (PLDI 2023)](https://dl.acm.org/doi/abs/10.1145/3591265) · [Iris-MSWasm (OOPSLA 2024)](https://dl.acm.org/doi/10.1145/3689722)
- [Two Mechanisations of WebAssembly 1.0 (WasmCert-Coq/Isabelle)](https://www.semanticscholar.org/paper/Two-Mechanisations-of-WebAssembly-1.0-Watt-Rao/3f723ab858d5f2b5040e2769139bcf4405e606c9)
- [Formally Verifying WebAssembly with KWasm (Chalmers thesis)](https://odr.chalmers.se/server/api/core/bitstreams/a06be182-a12e-46ce-94d3-cff7a5dc42ba/content)
- [Eunomia: User-specified Fine-Grained Search in Symbolically Executing WebAssembly Binaries (arXiv)](https://arxiv.org/pdf/2304.07204)
- [The Power of Ten — Rules for Developing Safety Critical Code (Holzmann, NASA/JPL, 2006)](https://spinroot.com/gerard/pdf/P10.pdf)
- [wasmsign2: signatures for WebAssembly modules](https://github.com/wasm-signatures/wasmsign2) · [Sigstore](https://www.sigstore.dev/)
- [WRTester: Differential Testing of WebAssembly Runtimes via Semantic-aware Binary Generation (arXiv)](https://arxiv.org/pdf/2312.10456)
- [wasm-smith: a WebAssembly test-case generator (Bytecode Alliance)](https://github.com/bytecodealliance/wasm-tools/tree/main/crates/wasm-smith)
- [z3-solver npm package (official Z3 wasm build)](https://www.npmjs.com/package/z3-solver) · [z3.wasm builds](https://github.com/cpitclaudel/z3.wasm)
- [cvc5 installation docs (emscripten/wasm build support)](https://cvc5.github.io/docs/latest/installation/installation.html)
