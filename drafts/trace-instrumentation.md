# Extending Trace-by-Rewriting: Loops, Branches, Calls — and Why Rewriting Is Hard

Status: draft research, 2026-07-08 (rev 2 — reconciled with the shipped `--trace-with` architecture)

## Where things actually stand

The README TODO's tracing item is partially shipped, with an architecture worth preserving:

- `qip run --trace-with modules/application/wasm/wasm-trace-instrument.wasm component.wasm` retries a *trapping* module through an instrumenter and reports recent memory events (`docs/tracing.md`).
- **The instrumenter is itself a QIP Content component** (`application/wasm` in → `application/wasm` out, ~880 lines of Zig). This is the load-bearing design decision: the CLI never grew a Go rewriting engine, any host that runs Content components can instrument (a browser can do it client-side), and the transformer is reviewable, portable, and dogfoods the whole thesis. **Keep this.**
- What it covers: every scalar load/store gets `qip_trace.before_load` / `before_store` / `after_store` import calls carrying `(func_id, op_id, mem_index, effective_addr, width)`. The host keeps the last 256 events and prints the last 16 on a failed retry — which already delivers the TODO's "trace unreachable via last input read" forensic.
- What it rejects (deliberately): SIMD memory ops, atomics, memory64, multi-memory; bulk-memory ops pass through untraced.

**Remaining from the TODO:** loop-iteration tracing (`trace_loop`), call tracing (`trace_will_call`), branch tracing (`trace_if`/`trace_block`) — plus quality-of-life items this doc adds: a site map so events symbolicate to names/offsets, and a possible zero-import instrumentation mode.

## Why rewriting is hard — the honest inventory

The shipped instrumenter is the best evidence; each difficulty below is something its 880 lines already pay for, and each new tracing level pays again.

### 1. Insertion invalidates every enclosing size

Function bodies, the code section, and the module all carry LEB128 byte lengths. Inserting one instruction means re-emitting the function body with a new size, which resizes the code section, which resizes the module. There is no patching, only full re-encode — which is why the instrumenter is structured as read-section/transform/re-emit with a scratch buffer, and why every instruction's immediates must be decodable (the big `skipInstructionImmediate` switch) even for opcodes it doesn't touch. Every opcode Zig's backend may emit in the future is a potential `InvalidWasm`/`Unsupported` rejection — a maintenance treadmill priced in deliberately (refuse loudly beats corrupt silently).

### 2. Adding imports renumbers the world

Imported functions occupy the low indices of the function index space, so adding the three `qip_trace` imports shifts every defined function's index. The instrumenter's `shiftFuncIndex` must be applied *everywhere* a function index appears: every `call` immediate, export entries, element segments, the start section, `ref.func`, and the name section. Miss one spot and you get a module that validates but calls the wrong function — the worst failure class, because it *sometimes works*. (The shipped docs even carry a user-visible scar: "function indices in the instrumented stack trace may shift.") This cost recurs for every new import added by new trace levels — unless imports are avoided entirely (see the ring-buffer variant below).

### 3. Wasm has no `dup` — observing operands means stack surgery

This is the deepest one, and the reason the injected code isn't just "insert a call."

At an `i32.store offset=8`, the operand stack holds `[…, addr, value]`. To report the address you must *see* `addr` without consuming it — and wasm has no `dup`/`pick`; the stack is strictly consume-on-use. Three viable techniques:

#### Technique 1 — Scratch locals (what ships today)

Append extra locals to each function (one `i32` for addresses, plus one per value type: the instrumenter reserves `addr_local` and four value locals), then sandwich each site:

```wat
;; original: i32.store offset=8
local.set $value      ;; pop value
local.set $addr       ;; pop addr
i32.const F  i32.const OP  i32.const 0
local.get $addr  i32.const 8  i32.add   ;; effective addr for the report
i32.const 4
call $before_store
local.get $addr  local.get $value        ;; restore stack
i32.store offset=8                       ;; original op, memarg intact
call $after_store …
```

Costs: local-declaration rewriting per function, ~15 injected instructions per store, and value-type polymorphism handled by a local per type. Benefits: the original instruction survives untouched (memarg `offset`/`align` semantics preserved exactly — note the `i32.add` computes the effective address only for the *report*, so the u33 effective-address semantics of the real store are never at risk), works in MVP wasm with no feature dependencies. It's verbose but proven.

#### Technique 2 — Wrapper functions replacing the instruction (proposed)

Replace `i32.store offset=8` with `call $traced_store`, where the wrapper's *parameters* catch the operands — a `call` is the one wasm instruction that naturally names the top of the stack:

```wat
(func $traced_i32_store_off8 (param $addr i32) (param $value i32)
  local.get $addr … call $log …
  local.get $addr
  local.get $value
  i32.store offset=8)
```

This is elegant — no scratch locals in user functions, no local-section rewriting, a 1→1 instruction replacement (well, 2 with a site-id `i32.const` prepended: params `(addr, value, site)`). Wrapper functions are *appended*, and appended definitions take the next free indices, so they cause **no index shifting**. Two real complications:

- **The memarg immediate is static, so it must live in the wrapper.** Either generate one wrapper per distinct `(opcode, offset, align)` triple actually present (deduplicated — in `ReleaseSmall` modules the distinct-offset count is modest, but it's unbounded in principle), or fold the offset into the address dynamically (`local.get $addr; i32.const 8; i32.add; i32.store offset=0`). **The folding version is a trap-parity bug:** wasm computes `addr + offset` as a 33-bit value (an out-of-range sum traps), while `i32.add` wraps mod 2³². A module where `addr = 0xFFFF_FFF0, offset = 0x20` traps natively but would silently store at `0x10` when folded. Contrived? Yes. But "instrumented module must trap on exactly the inputs the original traps on" is the whole correctness contract of a debugging tool, so per-triple wrappers it is.
- **Control instructions can't be wrapped.** `if`, `loop`, `br_if` involve branches, and branches can't cross a function boundary — so Technique 2 covers memory ops and plain `call`s (a per-callee wrapper forwarding the exact signature, logging, then `call $real`), but not the branch/loop levels of the TODO.

#### Technique 3 — Tap functions: identity loggers inserted *before* untouched instructions

The refinement that gets the best of both: never replace the native instruction; insert a *pass-through* logger in front of it that receives the operands as params and returns them unchanged:

```wat
(func $tap_store2 (param $addr i32) (param $value i32) (param $site i32)
                  (result i32 i32)          ;; multi-value
  …log addr/value/site…
  local.get $addr
  local.get $value)

;; site rewrite: insert 2 instructions, keep the store byte-identical
i32.const 17
call $tap_store2
i32.store offset=8
```

- The native memarg stays in place → **no trap-parity risk, no per-offset wrapper explosion** (one tap per operand *shape*, not per memarg; the static offset is looked up from the site id at symbolication time).
- Single-operand sites (`load` address, `if` condition) need only a 1-in/1-out tap — plain MVP wasm. Two-operand stores need **multi-value returns**, which wazero, all browsers, and `wat2wasm` support, but which is a new feature dependency for instrumented output (graceful fallback: use Technique 1 for stores only).
- Zero-operand sites (loop headers, block entries, before-`call` logging) are simpler still: insert `i32.const site; call $log_visit` — self-contained, always stack-safe, no tap needed. **This is all the remaining TODO levels require**: `trace_loop` is a visit-log at each loop body start, `trace_will_call` a visit-log before each call, `trace_block` a visit-log at block entry. Only `trace_if`'s *condition value* needs a 1-ary tap.

So the difficulty gradient, made explicit: **the unshipped TODO levels (loops/calls/blocks) are the easy kind of injection** — pure insertion, no operand observation, no stack surgery. The hard part (memory operand capture) is the part already shipped. That reordering of difficulty is this document's most actionable finding.

### 4. The i32.add subtlety, generalized

Any arithmetic the instrumenter injects on values it reports (effective addresses, iteration counters) lives outside wasm's checked semantics. Reports may lie at the margins (wrapped adds); *behavior* must never change. Rule: injected code may compute anything for logging, but original instructions keep their original immediates and operands, always. Techniques 1 and 3 satisfy this by construction; Technique 2 only in its per-triple form.

## A zero-import variant worth prototyping: the in-memory ring buffer

Every technique above still calls `qip_trace.*` imports — which forces index shifting (difficulty 2) and makes instrumented modules violate QIP's no-import property. There's a variant that eliminates both: **append the log sink instead of importing it.**

- Bump the memory section's min pages by a fixed amount; place a ring buffer + cursor in the new pages (instrumented modules are debug-only artifacts, so the memory-policy deviation is acceptable and disclosed).
- Taps/loggers are appended wasm functions that write fixed-size event records `(site_id, addr, payload)` into the ring via an appended mutable global cursor. Appended functions, globals, types, and exports all take fresh high indices — **nothing existing is renumbered; `shiftFuncIndex` and its whole bug class disappear.**
- Host protocol: exported `qip_trace_buffer_ptr()` / `qip_trace_cursor()`; after a trap the host (wazero or a browser — trapped instances keep readable memory in both) reads the ring and symbolicates. No host callbacks at all, so it works on *any* host with zero integration — including hosts that never heard of `qip_trace`.
- Bonus: fixes the "stack trace indices shift" limitation, and per-event cost drops from a host-boundary call (expensive in wazero) to an intra-module store — which matters if loop tracing runs on hot loops.

Trade-offs: last-N semantics only (the import version lets the host see events *live*, and `before_load` can report an address *before* a trapping load — the ring version records it just as well, since the write happens before the load executes); and bounded capacity means a firehose mode still wants imports. The two modes share site numbering, so they can coexist: `--trace-with` picks the instrumenter component, and the ring variant is just a second component (or a uniform).

## Design for the remaining levels

- **Configuration via uniforms**, the native QIP channel: `wasm-trace-instrument.wasm '?loops=1&calls=1&branches=1&memory=1'` rather than a family of single-purpose instrumenters. (Current component traces memory always; make that the `memory=1` default for compatibility.)
- **Site map:** events carry `(func_id, op_id/site_id)`; today symbolication relies on deterministic renumbering conventions. Emit an explicit site table as a **wasm custom section** (`qip.trace.sites`) in the instrumented output — runtimes ignore custom sections, the artifact stays self-contained (one Content output, no sidecar file needed), and the host extracts it to map site → (function name from name section, original byte offset, opcode, memarg offset). Include the original module's SHA-256 for provenance.
- **Report UX:** extend the existing failed-retry report with loop context ("inside loop_3, iteration 4093" — iteration counts derived by counting visit events per site) and branch outcomes. Later: `qip trace diff` between a passing and failing input; determinism guarantees the first divergent event is meaningful.
- **What stays out:** `trace_block` is near-zero information for its cost next to `if`-outcomes and loop visits — cut it from v1 of the extension (revisit if real debugging sessions miss it).

## Correctness strategy (unchanged in spirit, sharpened by the above)

1. **Identity check:** instrumenter with all levels disabled should pass modules through byte-identically (or, if re-encoding normalizes LEBs, semantically — byte-identical is worth the effort as a test oracle).
2. **Behavioral duel:** instrumented-with-no-op-sink vs original over a corpus — byte-identical outputs and *trap parity* (same inputs trap). The photocopy duel harness (drafts/photocopy.md) is exactly this oracle; run it in CI over every module in `modules/` and `recipes/`.
3. **`wasm-validate`** (wabt, already a dependency) on instrumented outputs in tests; wazero compilation always.
4. **Refuse loudly:** keep the existing rejection list (SIMD memory, atomics, memory64, multi-memory) and extend it to anything the new passes can't re-encode. The existing `test/trace-with.mjs` WAT-fixture pattern extends naturally per level.

## Plan

1. **Loop + call visit-logging** in `wasm-trace-instrument.zig` behind uniforms — pure insertion, no stack surgery, highest forensic value per line of code. Ship with iteration counts in the retry report.
2. **Site-map custom section** + host symbolication (name-section names, original offsets).
3. **`if`-condition taps** (1-ary, MVP-compatible) for branch outcomes.
4. **Ring-buffer zero-import variant** as a prototype: measure hot-loop overhead vs import callbacks; if it wins, it likely becomes the default for `loops=1` tracing.
5. **Store taps via multi-value** only if profiling shows Technique 1's store sandwich matters; otherwise keep the shipped scratch-local stores forever — they work.

## Open questions

- **Scratch capacity:** the instrumenter transforms within fixed buffers (`SCRATCH_CAP`); heavier instrumentation inflates bodies further. Size the caps against the largest repo modules with all levels on, and make overflow a clean `ScratchTooSmall` refusal (it already is) with a documented workaround (instrument fewer levels).
- **Uniform-driven op_id stability:** site ids must be stable across level combinations (a site's id shouldn't change when `loops=1` is toggled), or `trace diff` across configurations breaks. Number sites by a single pre-pass over all instrumentable positions regardless of enabled levels.
- **Multi-value as a host requirement:** every current host supports it, but the safety-check/score vocabulary may not decode multi-value block types; confirm before Technique 3 lands anywhere that feeds those tools (it shouldn't — instrumented modules are never scored — but the wasminspect decoder is also used for other analysis).
- **Browser-side `--trace-with` parity:** the instrumenter component runs anywhere, but the *retry-and-report* loop currently lives in the CLI; the play/preview client runtimes could adopt the same retry flow — worth a small follow-up design note once the ring-buffer variant exists (it makes browser adoption trivial: no import wiring).
