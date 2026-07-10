# In-Place Output: Letting `output_ptr` Alias the Input Buffer

Status: draft research, 2026-07-08

## Goal (from README TODO)

Add an optimization where if `output_ptr >= input_ptr && (output_ptr + output_size <= input_ptr + input_cap)` the host can treat the output as a slice of the input it already holds, instead of copying it out. Requires a contract clarification that `output_ptr()` MUST be read only after calling `render()`, because a module using this optimization returns a pointer that depends on the input just rendered.

## Why this matters (and for whom)

A large family of modules are *subrange filters*: trim, substring/field extraction, front-matter stripping, validators that re-emit their input on success, parsers that return a region of what they were given. Today each of these must `memcpy` from `input_buf` to a separate `output_buf` — which costs:

1. **Module memory:** a dedicated output buffer as large as the input cap. For a 4 MiB-cap trim module, aliasing halves the linear memory footprint. Under `--max-memory` and the hard-limits policy this is the difference between fitting and not.
2. **Module code + time:** the copy loop itself (code size matters at `ReleaseSmall`, time matters at 4 MiB inputs).
3. **Host copies:** hosts that defensively copy output bytes pay again.

The aliased version of trim is beautiful: `render` computes `start`/`end`, stores `input_ptr + start` into a global, returns `end - start`. Zero data movement inside the module.

## The key reframing: this is a lifetime problem, not a location problem

The TODO frames the host-side win as a pointer-range check. Investigating the actual hosts changes the picture:

- **Go/wazero** (`main.go` render paths): `mod.Memory().Read(ptr, len)` already returns a **view** into the module's linear memory, not a copy. The host is already zero-copy on read; the copy happens when those bytes are written into the *next* stage's memory, which is unavoidable (different module, different memory). So on the Go side there is nothing to optimize by detecting aliasing — the win there is entirely module-side (points 1–2 above).
- **JS runtimes** (`embedded/qip-preview-client-runtime.js`): output is read with `mem.slice(start, end)` — a copy. Switching to `subarray()` (a view) is the actual host-side optimization, and it is valid *regardless of whether output aliases input*. What gates it is **lifetime**: a view into wasm memory is invalidated by `memory.grow` (detaches the ArrayBuffer) and clobbered by the next `render` or the next input write.

So the design question is not "when may the host slice?" but "**how long is `output_ptr`'s region guaranteed stable, and what invalidates it?**" The pointer-range check from the TODO survives as a diagnostic (see Telemetry), not as a correctness gate.

## Proposed contract amendments (`docs/component-contract.md`)

The contract already says the host must call `render()` before `output_ptr()`. Strengthen and complete that:

1. **`output_ptr()` is render-scoped.** Its value MAY change on every `render`. Hosts MUST re-read it after each `render` and MUST NOT cache it across renders. (Both current hosts already re-read per render — this codifies existing behavior.)
2. **Output bytes are valid until the next mutation.** The region `[output_ptr, output_ptr + returned_size)` is stable only until the host next (a) writes input bytes, (b) calls `render` or any uniform setter, or (c) the module's memory grows. Hosts MUST consume or copy the output before doing any of these.
3. **Output MAY alias the input region.** The sentence "Keep input and output buffers disjoint unless overlap is an intentional and tested optimization" (Memory Recommendations) gets a companion: aliasing `output_ptr` into `[input_ptr, input_ptr + input_cap)` is a supported, first-class pattern for subrange transforms; the returned region must lie within bytes the host actually wrote this render (`input_size`), never within the uninitialized tail of the input buffer.
4. **Pre-render value is meaningless.** `output_ptr()` called before the first `render` may return anything in-bounds; validators and inspectors MUST NOT interpret it (see Interactions below).

Rule 3's "within `input_size`, not `input_cap`" clause is load-bearing: without it, a buggy aliasing module could return a window over stale bytes from a *previous, larger* input — a cross-render data leak. In a pipeline that's cross-*stage* leakage. The comply harness should get a dedicated test: render a large input, then a small one, and verify no bytes of the large input can appear in the small render's output region unless legitimately contained in it.

## Approaches

### Approach A — Module-side convention only (do first)

No host changes. Document the pattern, add a Zig example (`docs/zig-components.md`) and convert one real module (`trim` or a front-matter stripper) as the reference:

```zig
var output_offset: u32 = 0; // set by render
export fn output_ptr() u32 { return @intFromPtr(&input_buf) + output_offset; }
export fn output_utf8_cap() u32 { return INPUT_CAP; }
```

Wins 1–2 (memory halving, no copy loop) accrue immediately on every host, because hosts already re-read `output_ptr` per render. Cost: a docs PR and one module conversion. This is most of the value.

### Approach B — JS host view fast-path (measure, then maybe)

Replace `slice` with `subarray` in the client runtimes where the consumer finishes with the bytes synchronously before the next render/input write (true for pipeline hand-off; *not* true for bytes handed to async APIs like `fetch`, `TextDecoder` streams held across ticks, or anything retained). Requires an audit of every consumer of the returned buffer; any escape → keep copying. Given input sizes in the browser preview are typically small, benchmark first (`qip bench` and the play debug stats harness) — if the copy isn't visible in profiles, skip B and keep the simpler always-copy semantics on the JS side.

### Approach C — Explicit aliasing signal (rejected)

A discoverable export (`output_aliases_input()`) or an encoded return convention letting hosts *know* output aliases input. Rejected: after reframing, hosts don't need to know — lifetime rules cover both aliased and non-aliased modules uniformly, and a signal would bifurcate the contract and every validator for no additional win.

**Recommendation:** A now; B only if benchmarks justify it; C never.

## Interactions to check before shipping A

- **Contract detection / comply / score:** anything that calls `output_ptr()` at instantiation time (instantiation metrics in `wasminspect`, comply harness setup) must tolerate a pre-render garbage value and must not assert `output_ptr` is constant across renders. Audit `EvaluateQIPContractChecks` and the comply flow for both assumptions.
- **Repeated-render guidance:** the contract's repeated-render section ("keep internal state consistent when input bytes change between calls") composes naturally — an aliasing module's "state" is just the offset, recomputed each render. Add an invalid-then-valid recovery test for the reference module, matching the existing validator-recovery TODO.
- **Interactive/Tile contracts:** untouched; this is Content-only. `output_rgba8_srgb_bytes` paths have separate semantics.
- **`qip photocopy` / duel harnesses (drafts/photocopy.md):** the duel already re-renders on one instance; an aliasing module that violates rule 3 shows up as a divergence there. Good — one more reason the duel interleaves repeated renders.

## Telemetry (the TODO's check, repurposed)

After each render in `-v`/bench mode, evaluate `output_ptr ∈ [input_ptr, input_ptr + input_size)`: report "output aliases input (zero-copy)" plus the offset. Cheap, and it makes the optimization *visible* — useful both for module authors verifying they got the pattern right and for `qip score` to eventually award the memory-footprint win.

## Risks

- **Silent misuse without rule 3 enforcement:** the stale-byte leak described above is the one genuinely dangerous failure mode; the comply test is not optional.
- **Third-party hosts** that cached `output_ptr` at instantiation would break on aliasing modules. The contract text never promised stability, and both first-party hosts are correct, but the amendment should be called out prominently (changelog + component-contract heading) since it converts an implicit assumption into a documented non-guarantee.
- **B's escape analysis is fragile** under future JS runtime edits; if B ships, wrap the view in a debug-mode proxy that throws after invalidation so misuse fails loudly in development rather than corrupting silently in production.
