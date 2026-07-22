# Building C libraries as QIP components

QIP C components can use Emscripten's Clang and system libraries without using
Emscripten's browser runtime. The final `.wasm` is the boundary that matters:
inspect its imports, exports, memory declaration, and instructions rather than
inferring its runtime requirements from the compiler name.

`bmp-to-webp-lossy.wasm` uses this approach. It statically links libwebp and
SharpYUV with Clang and `wasm-ld`, then runs Binaryen directly. It has no
imports, exports only its QIP interface and diagnostics, and does not require
JavaScript, WASI, a filesystem, or a dynamically loaded library.

## The available build paths

| Path | What it buys | What it costs |
| --- | --- | --- |
| Zig | A compact freestanding toolchain and straightforward QIP ABI control | libwebp's upstream Wasm SIMD route uses Emscripten's SSE compatibility headers, so Zig's scalar build was substantially slower |
| `emcc` standalone | The simplest way to activate libwebp's translated SSE SIMD and select compatible system libraries | Emscripten 2.0.34 also exported its function table, `errno` accessor, and three stack helpers |
| Clang + `wasm-ld` | Explicit imports, exports, memory, libraries, and post-link passes | The recipe must reproduce the relevant parts of the Emscripten driver correctly |

The direct Clang build was selected for `bmp-to-webp-lossy.wasm`. On the 12 MP
photograph used during development it had the same encoding speed and produced
byte-identical WebP output as the standalone `emcc` build. It was about 362 KB
instead of 353 KB, but reduced the export surface from 31 entries to the 26
entries requested by the component.

The five removed exports were not browser dependencies:

- `__indirect_function_table` exposed the table used internally for C function
  pointers.
- `__errno_location` exposed C's `errno` address.
- `stackSave`, `stackRestore`, and `stackAlloc` supported Emscripten-generated
  JavaScript argument marshalling.

An export makes an internal value callable by the host. An import is a runtime
dependency that the host must provide. The earlier module had no imports and
was already a valid QIP component; direct linking gives it a narrower public
surface.

## What `emcc` was doing

Invoking Clang from the Emscripten SDK is not equivalent to replacing `emcc`
with `clang` in the command line. The driver supplied four relevant behaviors.

First, `-msse4.1` is a driver-level compatibility feature for Wasm. Direct
Clang 14 ignores that option for a `wasm32` target. The QIP recipe explicitly
adds Emscripten's `include/compat` directory and defines the SSE feature macros
that select libwebp's SSE2 and SSE4.1 sources. Those headers lower the intrinsics
to WebAssembly SIMD.

Second, libwebp's CPU dispatcher checks `EMSCRIPTEN`, not only
`__EMSCRIPTEN__`, to treat compile-time SIMD support as available at runtime.
Omitting that definition produces a valid but effectively scalar module. In
the development benchmark it took about 3.1 seconds instead of about 1.8
seconds for 12 MP.

Third, Emscripten's normal optimized `memcpy` delegates copies of 512 bytes or
more to a JavaScript helper. Its standalone fallback deliberately traps if that
path is reached. Compiling and linking with `-mbulk-memory` lets LLVM lower
`memcpy` and `memset` operations to WebAssembly `memory.copy` and `memory.fill`
instead. This removes the JavaScript path without maintaining a replacement C
copy loop. The final libwebp module currently contains 149 `memory.copy` and 95
`memory.fill` instructions; QIP's strict profile accepts both bounded-memory
operations.

Finally, `emcc` chose and prepared its musl-derived C library, compiler runtime,
and standalone support library, then ran Binaryen. The Makefile now makes those
steps explicit:

- `embuilder.py --lto` prepares the pinned system libraries in a QIP-specific
  cache.
- Clang 14 compiles and LTO-links with `-nostdlib` and an explicit library
  list.
- `wasm-ld` receives every public export, the 64 KiB stack, and equal initial
  and maximum memory sizes.
- `wasm-opt -O3 --enable-simd --enable-bulk-memory` performs the post-link
  optimization and removes debug and producer metadata.

There is no direct-Clang equivalent of `-sFILESYSTEM=0`: that option controls
Emscripten's generated runtime. The direct build never links that runtime. A
zero-entry import section is the stronger artifact-level check.

## Reproducing the build

The compiler is pinned because Emscripten 2.0.34/Clang 14 generated materially
faster libwebp Wasm SIMD than the newer Emscripten version tested during this
work.

```sh
mise install emsdk@2.0.34
make -j components/image/bmp/bmp-to-webp-lossy.wasm
```

The Makefile locates the SDK through `mise`, prepares the LTO sysroot libraries,
and keeps intermediate objects in `/private/tmp` on macOS or `/tmp` elsewhere.
Preparing a fresh cache took about one minute on the development machine;
subsequent builds reuse it.

Check the result rather than relying on build flags alone:

```sh
./qip comply components/image/bmp/bmp-to-webp-lossy.wasm
wasm-objdump -x components/image/bmp/bmp-to-webp-lossy.wasm
node --test test/bmp-webp.mjs test/qip-wasm-policy.mjs
```

For a freestanding algorithm that does not need Emscripten's translated SIMD
headers or system libraries, Zig or a normal freestanding Clang build is less
fragile. Use the explicit Emscripten-Clang path when an upstream C library's
performance depends on those facilities and the narrower final Wasm surface is
worth maintaining the additional linker detail.
