# `qip photocopy` — Research & Implementation Approaches

Status: draft research, 2026-07-08

## Goal

Add a `qip photocopy` command that:

1. Observes an existing local CLI tool's input/output behavior (a pure calculation — bytes in, bytes out — not something like `ls` that depends on ambient context),
2. Generates a behaviorally similar QIP Content module (`.zig` source compiled to `.wasm`),
3. Validates the copy by duelling it against the original over a fuzzed input corpus,
4. Reports divergences with minimized reproducing inputs.

The name is apt: a photocopy is a faithful reproduction made by observing the surface, not by having the original's internals. The output is a first-class QIP component — deterministic, sandboxed, portable — that can replace a native tool dependency in a recipe.

## Decisions already made

| Question | Decision |
|---|---|
| Synthesis mechanism | LLM-driven: photocopy drives an LLM to write Zig, compiles, and iterates against the duel harness |
| LLM access | Pluggable command (`--synth-cmd`, default `claude -p`); qip defines a file-based prompt/response protocol, no SDK dependency |
| Tool shape (v1) | stdin→stdout filters only (e.g. `base64`, `tr a-z A-Z`, `jq -c .` with frozen argv) |
| Target language | Zig, compiled with the repo's existing `wasm32-freestanding` flags |
| Equivalence | Byte-exact by default; opt-in relaxations (`--trim-trailing-newline`, future comparators) |
| Corpus | User seeds + automatic mutation fuzzing + LLM-proposed edge-case inputs |
| Artifacts | Dedicated workdir per run (`photocopy/<name>/`); user promotes to `modules/` manually |

## Constraints inherited from QIP

- The generated module must satisfy the Content contract (`docs/component-contract.md`): `input_ptr`/`input_bytes_cap` (or `_utf8_cap`), `output_ptr`/`output_bytes_cap`, `render(input_size) -> i32`, repeated renders on one instance must be safe.
- Fixed buffer capacities. photocopy must pick `input_bytes_cap`/`output_bytes_cap` from observed behavior (max seed size × headroom, and observed output-expansion ratio, e.g. base64's 4/3). Caps become part of the report so the user knows the copy's envelope.
- Prefer trapping over silent truncation; `return 0` only for intentional empty output. The synthesized module should trap on inputs outside its envelope rather than diverge quietly.
- Determinism is the whole point. The *original tool* must be verified deterministic before any synthesis happens (see Phase 0).
- Compile with `--max-memory` per `docs/hard-limits.md`; the result should pass `qip score` / the wasm safety check like every other module.

## CLI design

```
qip photocopy [flags] -- <tool> [frozen-args...]

  -name <slug>            module name (default: derived from tool basename)
  -seed <path>            seed input file or directory (repeatable); "-" reads one seed from stdin
  -workdir <dir>          output workdir (default: photocopy/<name>/)
  -synth-cmd <template>   LLM command (default: `claude -p`); receives prompt on stdin, emits response on stdout
  -rounds <n>             max synthesize→duel repair rounds (default: 6)
  -fuzz-time <dur>        mutation fuzzing budget per round (default: 10s)
  -fuzz-total <dur>       final acceptance fuzz budget (default: 60s)
  -input-cap <bytes>      override inferred input_bytes_cap
  -output-cap <bytes>     override inferred output_bytes_cap
  -utf8                   assert tool is UTF-8 text in/out (use *_utf8_cap exports)
  -trim-trailing-newline  relax comparison: ignore a single trailing \n difference
  -timeout <dur>          per-invocation timeout for the observed tool (default: 5s)
```

Example:

```bash
qip photocopy -seed fixtures/b64/ -- base64
qip photocopy -name jq-compact -seed samples.jsonl -- jq -c .
```

Everything after `--` is the tool plus *frozen* argv — treated as part of the tool's identity, never varied. Only stdin varies.

## Pipeline

Seven phases. Each phase writes its artifacts into the workdir so a run is inspectable and resumable.

### Phase 0 — Qualify the target (determinism gate)

Before spending any LLM tokens, prove the tool is a candidate:

1. Run each seed through the tool **3×**; outputs must be byte-identical across runs. If not → hard fail: "tool is nondeterministic, not photocopyable."
2. Re-run a sample of seeds with a perturbed environment: different `TZ`, `LC_ALL=C` vs inherited locale, different working directory (the scratchpad), empty vs inherited env. Any output change → fail with the specific env sensitivity named. This catches `date`-like and locale-dependent tools.
3. Record exit codes. v1 policy: nonzero exit on some inputs is allowed and modeled as "module traps on this input class" (QIP's analog of a tool error). stderr is captured for the LLM's benefit but never compared.
4. Probe the empty input and a large input (near proposed cap) so envelope behavior is known up front.

Deliverable: `manifest.json` — tool argv, hashes of the tool binary, seed list, env-sensitivity results, timing stats, proposed caps.

### Phase 1 — Observe (build the behavior corpus)

- Run every seed through the tool, store `(input, output, exit_code)` triples in `corpus/` as content-addressed files (`<sha256>.in` / `.out` / `.exit`).
- Generate structural probe inputs automatically: empty, 1 byte, all 256 single bytes, short ASCII, invalid UTF-8, NUL bytes, long runs, inputs at/over the proposed cap. These probes are cheap and dramatically sharpen the LLM's hypothesis (e.g. all-256-bytes instantly reveals a case-mapping table or base64 alphabet).
- Mutate seeds (bit flips, byte swaps, truncation, duplication, splicing, interesting-value insertion — go-fuzz style) and record those triples too.
- Cap what's shown to the LLM later: a representative sample selected for output diversity (bucket by output length delta, exit code, byte histogram), not the whole corpus.

### Phase 2 — Hypothesize & synthesize (LLM round 1)

Build a prompt file containing:

- The task: "write a QIP Content component in Zig matching this observed behavior."
- The component contract essentials + a known-good example module from `modules/` as a style/ABI template (e.g. an existing text transform in the repo).
- The tool's name/argv (a strong hint: the LLM likely *knows* what `base64` does — observation confirms rather than teaches), plus `tool --help`/man page text if available.
- The sampled I/O pairs, hex-escaped where non-printable.
- Buffer caps and the trap-on-overflow rule.
- Response protocol: reply with exactly one ```zig fenced block; also propose up to N adversarial test inputs in a fenced ```inputs block (one per line, escaped) — these get run through the *real tool* and added to the corpus.

Invoke `--synth-cmd` with the prompt on stdin, parse the fenced blocks from stdout. The pluggable command means `claude -p`, a local model, or anything else works; qip only owns the protocol.

### Phase 3 — Build

- Write `module.zig`, compile with the repo's standard flags: `zig build-exe -target wasm32-freestanding -O ReleaseSmall -fno-entry -rdynamic --max-memory=<computed>`.
- Compile errors are fed back to the LLM verbatim as a repair round (cheap, no fuzzing needed).
- Run the existing wasm safety check / `qip score` gate on the artifact; violations are also repair-round feedback.

### Phase 4 — Duel

Run the full corpus through both sides:

- **Original:** subprocess, stdin→stdout, timeout enforced.
- **Copy:** instantiated once via wazero (reusing `internal/wasmruntime`), `render()` called repeatedly on the same instance — which also exercises the repeated-render contract for free. Interleave a deliberate re-render of a previous input to catch stale-state bugs.

Comparison is byte-exact (modulo opted-in relaxations). Classify each divergence:

| Class | Meaning |
|---|---|
| `output-mismatch` | both succeeded, bytes differ (first-diff offset + hex context recorded) |
| `copy-trap` / `tool-error` | one side errored where the other succeeded; `tool-error`+`copy-trap` together count as agreement |
| `copy-overflow` | output exceeded cap — cap bug, not logic bug; handled by raising cap, not re-prompting |
| `timeout` | either side exceeded budget |

### Phase 5 — Fuzz

Mutation-based fuzzing with the duel as the oracle — this is differential fuzzing, so no property spec is needed; the original tool *is* the spec.

- Mutate from the corpus; any input producing a divergence is **minimized** (ddmin: chunk removal, then byte-level simplification toward printable ASCII, re-checking divergence each step) and added to `divergences/`.
- Coverage proxy without instrumentation: keep mutated inputs that produce *novel outputs* (new output length class, new first-diff behavior, new exit class) as new corpus members — output-diversity-guided fuzzing. Optionally later: wazero's experimental coverage listener for real branch feedback on the copy side.
- Budget: `-fuzz-time` per repair round (fast signal), `-fuzz-total` for the final acceptance run.

### Phase 6 — Repair loop & report

- If divergences exist and rounds remain: build a repair prompt = previous source + up to ~10 minimized divergent inputs with both sides' outputs (hex-diffed) → back to Phase 3. Each round's source is kept (`rounds/1/module.zig`, …) so regressions are visible.
- Terminate on: zero divergences through the acceptance fuzz (**success**), rounds exhausted (**partial**, best round shipped with its divergence list), or no improvement across two consecutive rounds (**stuck**, stop burning tokens).
- Emit `report.md`: verdict, corpus size, fuzz executions, divergence count by class with minimized repros, inferred caps/envelope, and the exact `qip run` command to try the copy. Exit code 0 only on a clean acceptance fuzz — CI-friendly.

### Workdir layout

```
photocopy/<name>/
  manifest.json         # tool identity, hashes, caps, env-sensitivity results
  module.zig            # best round's source
  module.wasm
  corpus/               # <sha256>.in/.out/.exit
  divergences/          # minimized failing inputs + both outputs
  rounds/<n>/           # per-round source, build log, duel summary
  prompts/<n>.txt       # exact prompts sent (auditable, replayable)
  report.md
```

## Approaches considered

### Approach A — LLM synthesis loop (chosen)

What's described above. The LLM does hypothesis formation ("this is base64") and code generation; the duel/fuzz harness does *all* the trust work. The architecture is honest about this split: the LLM is an untrusted proposer, the differential fuzzer is the verifier. Handles the widest class of tools (anything the LLM can recognize or infer from examples). Cost: LLM dependency, nondeterministic synthesis time, and behavior on inputs the fuzzer never reached is only probabilistically similar.

### Approach B — Scaffold-only (no LLM in qip)

`qip photocopy` records behavior, writes the corpus + manifest + a ready-made prompt/spec, and stops; a human or coding agent implements the module, then `qip photocopy duel` validates it. Strictly less magic, but Phases 0/1/4/5 are identical — so **B is a free byproduct of A**: expose `observe` and `duel` as subcommands (`qip photocopy observe`, `qip photocopy duel`) and A's loop is just the orchestration of them plus the synth command. Worth doing regardless, since users will want to re-duel after hand-editing the generated Zig.

### Approach C — Programmatic transform search (no LLM)

Fit observed pairs against a library of known transforms (base64/hex/case/URL-encode/hash/compress) and simple combinators. Deterministic and instant when it hits, but the vocabulary ceiling is low and maintaining the library is a treadmill. Rejected as the main path; could later become a fast pre-pass ("recognized base64 in 0.1s, skipping LLM") since recognition against the corpus is a one-liner per candidate. Not v1.

### Approach D — Recompile/lift the original

If source is available, compile *the tool itself* to wasm32; or lift the binary. This is a photograph, not a photocopy — perfect fidelity, but it drags in libc/WASI/syscall emulation, exactly the complexity QIP exists to avoid, and produces bloated modules. Out of scope, though the doc for photocopy should mention it as the alternative when fidelity must be total.

**Recommendation:** A, structured so B's subcommands fall out of it. C as a possible later optimization.

## Implementation plan (Go)

The command follows the existing pattern: a `case "photocopy"` in `main.go`'s dispatch, implementation in `internal/photocopycommand.go` plus an `internal/photocopy/` package:

1. **`observe.go`** — Phase 0–1: subprocess runner (context timeout, env control), determinism/env gate, probe generation, corpus store. *Testable standalone against `base64`, `tr`, `sort -u` (deterministic) and `date` (must be rejected).*
2. **`duel.go`** — Phase 4: wazero instantiation via `internal/wasmruntime`, comparator, divergence classification. *Testable with a hand-written correct module vs the real tool, and a deliberately buggy module.*
3. **`fuzz.go`** — Phase 5: mutators, output-diversity corpus admission, ddmin minimizer. Pure functions, easy unit tests.
4. **`synth.go`** — Phases 2/6: prompt builder (templates embedded via `embed`, like the existing client runtimes), `--synth-cmd` invocation, fenced-block parser, round loop with the three termination conditions.
5. **`report.go` + `photocopycommand.go`** — manifest/report writers, flag parsing, subcommands `observe` / `duel` / full run.
6. **Docs**: `docs/qip-photocopy.md`; add to `llms.txt` / site nav alongside `qip-cli.md`.

Milestones: (1)+(2) alone already deliver Approach B and are fully testable without any LLM; (3) makes the duel adversarial; (4) completes Approach A. Integration tests for (4) can use a fake `--synth-cmd` (a script that emits a known-good or known-bad Zig file), so CI never needs a real LLM.

## Risks & open questions

- **Fidelity is probabilistic.** A clean fuzz run is evidence, not proof. The report must say so plainly, and the envelope (caps, input classes exercised) must be explicit. For tools with locale-sized state spaces this is fine; photocopy should refuse or loudly warn when Phase 0 smells hidden state.
- **Compression/float tools:** byte-exact equivalence may be unachievable for tools whose exact output is an implementation detail (e.g. `gzip` bit-stream choices, float formatting). v1 stance: they simply fail the duel, honestly. Pluggable comparators (JSON-semantic, decompress-then-compare) are the future answer — the comparator interface in `duel.go` should anticipate this.
- **Trojan-source risk:** generated Zig could in principle do something unwanted; mitigated by the existing safety-check/score gate (no imports, memory caps) and by the source being small and reviewable in the workdir. Never auto-promote into `modules/`.
- **Frozen argv vs uniforms:** flags like `tr`'s operands or `fold -w N` map naturally onto QIP uniforms. v1 freezes them; a later `-uniform cols=<int>` flag could observe the tool at several parameter values and ask the LLM to generalize. Design the manifest to record frozen argv so this is a compatible extension.
- **Non-UTF-8 stdout tools on Windows** and other platform text-mode quirks: observation happens where photocopy runs; the manifest records platform, and the report should note the copy reproduces *this platform's* behavior.
- **Naming the module's content type:** if all observed outputs share a sniffable MIME type, propose the optional `output_content_type` exports; otherwise omit per the contract rules.
