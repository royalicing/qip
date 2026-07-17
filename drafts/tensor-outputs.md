# Numeric Outputs as SIMD-Aware Tensors

Status: draft research, 2026-07-08

## Goal (from README TODO)

Revisit numeric outputs as SIMD-aware tensors instead of restoring the old `output_i32_cap` directly. Proof cases: batched CRC, histograms, offset arrays, masks, matrices. Keep element type, logical shape, and physical layout separate; Mojo's scalar-as-one-lane-SIMD and explicit layout model is pertinent prior art.

## The problem

QIP components speak bytes (`output_bytes_cap`) or UTF-8 (`output_utf8_cap`). Modules whose natural output is *numbers* — a CRC per input record, a byte histogram, token offsets, a match mask, a matrix — currently have two bad options: serialize to text (slow, lossy for floats, bloats output caps) or emit raw little-endian bytes with the shape/type conveyed out-of-band in documentation (uncomposable, error-prone). The old `output_i32_cap` fixed only the narrowest case (flat i32 vector) and hard-wired element type into the *contract surface*, which is exactly the coupling the TODO says to avoid.

The three-way separation the TODO demands, made concrete:

- **Element type** — u8/i32/f32/…: what one element is.
- **Logical shape** — scalar, `[n]`, `[rows, cols]`: what the data *means*. A histogram is `u32[256]` whether or not it's padded.
- **Physical layout** — strides, alignment, padding: how it sits in memory so v128 loads are fast. A `f32[3, 100]` matrix whose rows are padded to 112 elements (448 bytes, /16) is the same logical tensor as a dense one.

Mojo's relevance: it treats scalars as 1-lane SIMD vectors (`Scalar[f32] = SIMD[f32, 1]`) so the scalar/vector boundary is a parameter, not a type schism; and its layout types make physical arrangement an explicit, separate object from logical shape. Both ideas transfer: a QIP "scalar result" should be a rank-0 tensor, not a special case, and layout must be declared, not inferred.

## Approaches

### Approach A — Self-describing header in the byte stream (recommended)

Keep the contract exactly as it is (`output_ptr` / `output_bytes_cap` / `render`) and define a tiny binary envelope, "qip-tensor v0", carried as ordinary output bytes with content type `application/vnd.qip-tensor` via the existing optional `output_content_type` exports:

```
offset  size  field
0       4     magic "QTNS"
4       1     version (0)
5       1     dtype enum (u8=0, i8=1, u16=2, i16=3, u32=4, i32=5, u64=6, i64=7, f32=8, f64=9, bits=10)
6       1     rank (0..4)
7       1     flags (bit0: row-major dense; bit1: strided)
8       8×r   dims: u64 per rank
8+8r    8×r   strides in *bytes* per rank (present iff strided flag)
…       pad   zero padding so payload starts at a 16-byte-aligned offset from output_ptr
…       n     payload, little-endian (wasm is LE; declared LE forever)
```

Rank 0 = scalar (payload is one element — Mojo's one-lane view, no special case). `bits` dtype packs masks 8/LSB-first per byte with `dims` counting logical bits. Sixteen-byte payload alignment is *relative to `output_ptr`*, so a module that also 16-aligns its output buffer (trivial in Zig: `align(16)`) gives downstream SIMD consumers aligned v128 loads; the header's pad field is what makes that achievable for any rank/dtype combination.

Why this wins:

- **Zero contract change.** No new exports, no changes to contract detection, comply, score, hosts, or the zero-arg-export migration. A tensor is just bytes with a MIME type — it flows through the existing content-type composition rules (a consumer declares `input_content_type = application/vnd.qip-tensor`; generic byte transforms like `base64-encode` or zlib pass it through untouched, which is genuinely useful: compress a histogram, checksum a matrix).
- **Cross-host for free.** Browser, Go, native all read the same bytes.
- **Inspectable.** `qip run … | xxd` shows the header; a `tensor-to-json.wasm` companion module makes any tensor human-readable *using the pipeline itself* — the best possible dogfood.

### Approach B — Descriptor exports (rejected)

New exports (`output_tensor_desc_ptr()` pointing at a dtype/rank/dims struct in memory, or worse, one export per property). Rejected: every host, validator, and doc grows a parallel contract branch; pipeline composition breaks (a base64 stage can't pass shape metadata through); and it re-creates `output_i32_cap`'s mistake of welding data description into the ABI. The contract's entire strength is that everything is bytes plus an optional MIME type.

### Approach C — Restore `output_i32_cap` (rejected, per the TODO itself)

Flat i32 vectors only. No dtype (f32 CRCs? histograms are u32; offsets may exceed i32), no shape, no layout, and a third cap-export variant for detection logic to juggle. The TODO already rejects this; agreed.

### Approach D — Adopt an existing format

- **npy:** Python-literal text header — parsing a Python dict in Zig freestanding modules is absurd.
- **safetensors:** JSON header, multi-tensor, designed for model files — too heavy for a 256-bucket histogram, and JSON parsing in every consumer module again.
- **DLPack:** an in-process ABI struct (pointers), not a serialization format — wrong layer, though its dtype enum is worth mirroring for familiarity.
- **Arrow:** columnar table IPC; vastly more machinery than "one tensor".

Nothing fits a freestanding-wasm producer *and* consumer with sub-hundred-byte overhead; a 16–80 byte fixed header is defensible original design here, with DLPack's dtype codes borrowed to avoid gratuitous novelty.

**Recommendation:** A, with D's DLPack dtype numbering.

## Proof cases mapped

| Case | Tensor | Notes |
|---|---|---|
| Batched CRC32 | `u32[n]`, rank 1, dense | n = record count; SIMD-friendly 4-per-v128 |
| Byte histogram | `u32[256]`, rank 1, dense | fixed shape; payload exactly 1 KiB, aligned |
| Offset array | `u64[n]` (or `u32[n]` when caps < 4 GiB — they always are; hard limits cap memory far below) | token/line starts into the *input*, pairs with the aliasing work in drafts/output-slice-optimization.md |
| Match mask | `bits[n]` | 1 bit per input byte/record; 8× smaller than bool bytes |
| Matrix | `f32[r, c]`, strided | row stride padded to 16 B for aligned v128 rows |

Each becomes a small real module (`components/bytes/crc32-batch.wasm`, `components/bytes/byte-histogram.wasm`, …) plus consumers (`tensor-to-json.wasm`, `tensor-stats.wasm`, `tensor-to-bmp-heatmap.wasm` for the demo-friendly win). The producer/consumer pairs are the spec's test suite: pipeline round-trips in `qip run` assert header agreement.

## SIMD-awareness, concretely

"SIMD-aware" must not mean "the format mandates vectorization"; it means the format never *prevents* it:

1. Payload 16-byte alignment relative to `output_ptr` (header pad) + `align(16)` buffers in the reference modules.
2. Strides expressible so producers can pad rows to lane multiples; dense flag so simple consumers can ignore strides entirely when unset.
3. Dtype set closed under v128 lane types (i8x16 … f64x2) — no exotic types (f16 deferred to a future version byte bump; wasm relaxed-simd f16 support is not in the repo's `-mcpu=generic+simd128` baseline).
4. Scalar-as-rank-0 keeps consumer code uniform: a `tensor-stats` module loops over elements identically for rank 0..4 (Mojo's lesson).

## Implementation plan

1. **Spec:** `docs/formats.md` gains a "qip-tensor v0" section (it already hosts format documentation); header layout, dtype table, alignment rule, LE guarantee.
2. **Zig helper:** a small `tensor.zig` shared include (like existing shared module patterns) with `writeHeader(comptime dtype, dims, strides) usize` so modules can't misencode; keep it dependency-free.
3. **Reference producers:** byte-histogram (simplest, fixed shape) then batched CRC32 (variable n).
4. **Reference consumers:** `tensor-to-json.wasm`, `tensor-to-bmp-heatmap.wasm` (histogram → image is a great site demo).
5. **Host niceties (optional, later):** `qip run -v` pretty-prints the header when output content type is `application/vnd.qip-tensor`; `qip score` no changes needed.
6. **Site page:** histogram → heatmap pipeline as a visible example of typed composition.

Steps 1–4 are pure spec + modules; no Go changes at all — the strongest evidence Approach A is the right shape.

## Open questions

- **Multiple tensors per output?** v0: one tensor per render. Batching heterogeneous results (e.g. offsets *and* mask) can wait for a v1 container or simply two pipeline stages; resist the Arrow-shaped slide toward tables.
- **Uniform-driven shapes:** a matrix-transpose module needs input shape — it reads it from the *input* tensor's header, no uniforms needed. This is the composability payoff and should be the second consumer example.
- **`bits` bit-order:** LSB-first-per-byte matches typical wasm shift idioms; must be pinned in the spec with a test vector, since it's the one field people will get wrong.
- **Content type registration:** `application/vnd.qip-tensor` is unregistered; fine for now (exact-match string comparison per the contract), note it in the spec.
