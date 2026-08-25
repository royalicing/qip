# Agentic Coding Against the Verification Stack

Status: draft research, 2026-07-12. Companion to [formal-verification.md](formal-verification.md), which defines the checks this document schedules.

## The question

If components are written largely by coding agents (Claude Code et al.), how should the verification stack run? Three candidate rhythms:

1. **Continually** — every check on every change.
2. **Ratchet** — start permissive, tighten thresholds over time.
3. **Small slices** — build and verify one narrow piece end-to-end, then the next.

The answer is not one of the three. Each rhythm is right for a different *layer*, sorted by check latency — because the single most important fact about agent-driven development is:

**An agent runs a check voluntarily if and only if it is fast, deterministic, and produces diagnostics it can act on.** Slow or flaky checks get skipped, rationalized, or worse, gamed. The verification stack should be scheduled around that behavioral reality, not around what a human release process would do.

## Layer 1 — Continual: the agent's inner loop (must run in seconds)

These run on every edit, unprompted, because they're wired into the one command the agent already runs to build:

- compile (Zig → wasm) + unit tests
- `wasm-validate` (type-check the artifact)
- `wasm-safety-check` / `qip score --fail-on-warn` (strict profile)
- the contract-conformance harness for the touched module (render-twice idempotence, length ≤ cap, trap-not-truncate)

Design rules for this layer:

- **One command.** `qip check components/text/foo.wasm` (or a build step that implies it). Agents reliably discover and reuse a single entry point documented in CLAUDE.md; they unreliably compose four separate tools.
- **Deterministic pass/fail with precise diagnostics.** This is where QIP's trap-with-diagnostics philosophy pays off twice: `qip score`'s per-loop WARN diagnostics are exactly the feedback an agent self-corrects from. A bare `wasm-safety-check` trap says *no*; the score report says *why* — the agent needs the report. Rich diagnostics are not a nicety here; they are the difference between one iteration and ten.
- **Checks-as-components is an agent superpower.** Because the checkers are themselves QIP components, an agent needs zero toolchain setup to run them — `qip run wasm-safety-check.wasm` works in any checkout. The portability thesis directly improves agent ergonomics.

## Layer 2 — Per slice: verification as the definition of done

"Small slices" is the right rhythm for *building* things — and the slice boundary QIP already has is the component. One component (or one property of one component) per slice, and a slice is done when its evidence exists, not when its code exists:

1. sentinel-byte noninterference test passes (no cross-render leakage)
2. reproducible-build check passes (rebuilt bytes == committed bytes)
3. Owi symbolic spike at small caps: no traps, write-set in bounds
4. evidence manifest updated (score report, stack/fuel bounds, proof certificates)

The deeper workflow insight: **the spec is the prompt.** When a component is agent-written, the human's leverage is in the property definitions — the CBMC harness, the conformance properties, the input/output contract — and the agent iterates against them until green. This inverts the review economics: the human reviews a 30-line spec instead of a 300-line implementation, and the verifier reviews the implementation. Formal verification and agentic coding aren't just compatible; each fixes the other's weakest point (verification's cost problem: agents grind through proof-annotation toil tirelessly; agentic coding's trust problem: proofs don't care who wrote the code). The README's "components, AI coding, security: pick all three" claim is *operationalized* by exactly this loop.

Two guardrails, because agents optimize what you measure:

- **Never let the same change edit spec and implementation.** An agent that can't satisfy a property will eventually — helpfully, plausibly — weaken the property. Specs, caps, and evidence manifests change only in human-reviewed commits; CI enforces "spec file touched ⇒ human approval required." This is separation of duties, applied to a coworker who types very fast.
- **Pair safety checks with correctness tests.** A safety-only gate invites degenerate passes (a loop "bounded" by truncating at 100 iterations passes `wasm-safety-check` while silently corrupting output). Every slice needs at least a golden-file or round-trip test so that gaming the safety gate breaks a correctness gate.

## Layer 3 — Ratchet: CI-owned coverage that only grows

Ratcheting is the wrong model for individual checks — each check should be binary from day one (a "70%-strict" safety check is not a meaningful thing). What ratchets is **coverage of the catalog**:

- **The proof ratchet:** once a component has a verified property, CI requires that property forever. The evidence manifest is the ratchet's memory — properties get added, never dropped. New components start with the layer-1 baseline; the catalog's verified fraction only climbs.
- **Budget ratchets:** per-component instruction count, module size, stack bound, fuel bound recorded as baselines; CI fails on regression beyond a tolerance. Cheap to keep, and exactly the drift agents introduce silently (an agent "fixing" a bug by adding a 4× slower path won't mention it; the fuel baseline will).
- **Expensive checks, time-boxed:** corpus-wide cross-engine differential runs, fuzzing the wasm-consuming components, full-cap CBMC proofs — nightly or weekly, not per-commit. Their findings arrive as new corpus entries and new required properties, i.e., they feed the ratchet rather than block the inner loop.

## The rhythm, in one table

| Layer | Rhythm | Latency budget | Who triggers | Examples |
|---|---|---|---|---|
| Inner loop | continual | seconds | agent, every edit | build, tests, validate, safety-check, conformance |
| Slice gate | per component/property | minutes | agent, at "done" | noninterference test, repro build, Owi spike, manifest |
| Catalog | ratchet | hours, async | CI | proof ratchet, budget baselines, fuzzing, differential runs |

The failure mode to avoid is putting a check in the wrong row: a minutes-long check in the inner loop teaches the agent to stop running checks; a seconds-long check left to nightly CI wastes ten agent iterations on a bug the inner loop would have caught on iteration one.

## Practical wiring for Claude Code specifically

- **CLAUDE.md** documents `qip check` and the slice checklist — the agent reads it every session; this is where the workflow actually lives.
- **A hook or CI gate on spec-vs-implementation separation** (layer 2's guardrail) — enforcement beats convention when the author is an agent.
- **Failing output is prompt material.** Format checker output so it's directly actionable: file/function/loop indices, the violated bound, the evidence that was expected but missing. `qip score`'s existing per-loop diagnostics are the house style; extend it to every new checker.
- **Slice = branch = evidence delta.** A reviewable agent PR is: one component, its spec (pre-approved), its implementation, and a green evidence manifest. The human reads the spec diff and the manifest; the code is the part they can afford to skim — which is the entire point.
