# BMP to lossy WebP

`bmp-to-webp-lossy.wasm` converts an uncompressed 32-bit BGRA BMP into an
opaque lossy WebP. It statically links the libwebp 1.6.0 VP8 encoder and
SharpYUV; it has no runtime imports or dynamic library dependency.

The release module is built by Emscripten 2.0.34's Clang 14 and `wasm-ld`
directly, with `-O3`, LTO, and libwebp's SSE2/SSE4.1 implementations lowered to
WebAssembly SIMD. This is the manual-source equivalent of libwebp's
`WEBP_ENABLE_SIMD=1` CMake option. The Emscripten SDK supplies its Wasm SIMD
compatibility headers and C sysroot, but no browser runtime or JavaScript glue
is linked. The resulting module has no host imports and only the exports named
by the component. LLVM bulk-memory lowering emits `memory.copy` and
`memory.fill` directly instead of linking a JavaScript-assisted `memcpy`. See
[Building C libraries as QIP components](../../../docs/c-wasm-toolchains.md)
for the compiler comparison and the direct-link responsibilities. Install the
pinned compiler with `mise install emsdk@2.0.34` before rebuilding.

The component is tuned for high-quality photographs:

- quality 95
- method 4
- sharp YUV conversion enabled
- libwebp low-memory mode enabled
- single-threaded encoding
- a direct fixed-capacity output writer

All four choices are uniforms: `quality` is 0–100, `method` is 0–6, and
`sharp_yuv` / `low_memory` accept 0 or 1.

```sh
./qip run \
  --timeout-ms 180000 \
  --max-memory 418971648 \
  -i input.bmp -o output.webp -- \
  components/image/bmp/bmp-to-webp-lossy.wasm \
  '?quality=95&method=4&sharp_yuv=1&low_memory=1'
```

The module accepts BGRA32 BMPs up to 25,000,000 pixels, with no dimension above
8192 pixels. This matches Cloudinary's 25 MP baseline image limit: 6000x4000
and 5000x5000 are accepted, while an 8000x6000 camera original must be resized
first. The input capacity includes 64 KiB for BMP headers and metadata, and the
output capacity is 32 MiB.

Its fixed linear memory is 6,393 WebAssembly pages (418,971,648 bytes, about
399.6 MiB). Its initial and maximum declarations agree, and the module has no
`memory.grow` instruction. The 256 MiB reset-only arena includes libwebp and
SharpYUV allocations.

The BMP input is disposable. After validating the header, the component moves
the pixel payload to an aligned base, flips bottom-up rows in place, forces
alpha to opaque, and exposes those pixels directly as `WebPPicture.argb`.
This avoids a second full-size ARGB copy. The current module intentionally does
not preserve BMP alpha because compressed WebP alpha invokes a separate VP8L
encoder with a different memory profile.

Allocator telemetry remains exported for measurements:

- `arena_peak_bytes()`
- `arena_allocation_count()`
- `arena_largest_allocation()`
- `arena_failed_allocation()`
- `arena_free_count()`
- `arena_free_null_count()`
- `arena_free_matched_count()`
- `arena_free_unmatched_count()`
- `arena_freed_bytes()`
- `arena_allocation_size(index)`
- `arena_allocation_event(index)`
- `arena_allocation_free_event(index)`

Encoding speed depends strongly on the Wasm runtime and sustained CPU clock.
On the development machine, the SIMD module encoded a 12 MP photograph in
about 2.2--3.6 seconds under Node's WebAssembly JIT; the former Zig scalar
build took 3.85--4.03 seconds. The output is byte-identical between those
builds and to native libwebp 1.6.0 with the same configuration.

The Go CLI's wazero interpreter/JIT path is substantially slower for this
calculation-heavy component, so the command example allows three minutes. The
timeout is a host policy rather than a component memory or image-size limit.

A 5000x5000 boundary test with the defaults took 8.7--9.1 seconds under Node,
down from 15.8--17.2 seconds for the Zig scalar build. Its arena peak was
229,373,312 bytes, leaving about 39 MiB of the 256 MiB arena untouched, and the
encode completed without a failed allocation.

Allocation traffic is small in call count. Measurements from 2 MP through 25
MP used 12--17 successful allocations per encode. libwebp issued one matching
non-null `free()` for every allocation, plus five `free(NULL)` calls. At 25 MP,
the reset-only arena peaked at 229,373,312 bytes; honoring the observed frees
could reduce that to about 212,595,000 bytes, a saving of about 16.8 MB (7%).
All allocations are released before `WebPEncode()` returns, so libwebp keeps no
allocator-owned state between renders.

libwebp is vendored under `third_party/libwebp-1.6.0`; its `COPYING` and
`PATENTS` files apply to that source.
