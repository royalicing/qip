# Hard Limits

QIP components should run with a small, explicit budget for memory, time, and host access.

That budget is part of the component contract. The host gives the component input bytes, calls a known export, and reads output bytes back. It does not give the component a filesystem, network, environment variables, cookies, DOM access, GPU APIs, or secrets unless the host deliberately turns some data into input.

This is stricter than normal application code. A JavaScript file loaded with `<script src>` runs inside a browser sandbox, but once it is page code it can inspect the DOM, make network requests, allocate memory until browser/runtime limits, and load more code. A QIP component should not be able to discover more world by itself. If it needs data, the host passes that data in.

## What QIP Enforces

QIP exposes resource policy in two layers.

The default component boundary removes ambient host access:

- No WASI by default.
- No filesystem, network, environment, clock, DOM, cookie, token, or GPU capability.
- No custom host imports unless the host has intentionally provided them.
- Input and output must fit the component's advertised capacities.

## Strict WebAssembly Profile

WebAssembly is a broad execution format. QIP uses a constrained subset of it for
normal components:

- **No ambient imports.** A component should not require WASI, host callbacks,
  filesystem access, network access, clocks, random sources, secrets, or package
  loading. The host passes required data as input bytes or explicit uniforms.
- **No `memory.grow`.** The component should stay inside the linear memory it
  starts with, so memory use is visible before execution.
- **No shared memory.** Components should not depend on threads or shared linear
  memory.
- **No atomics.** Atomic instructions imply shared-memory coordination, which is
  outside the normal QIP component model.
- **Fixed-bound loops for safety-checked modules.** A strict verifier can reject
  loops unless it can see a local counter, a monotonic update, and an exit bound.
- **Wasm32 with one linear memory.** QIP pointers and capacities are `i32`
  values into one memory, which keeps host writes and reads simple.

Compliance modules are a separate testing protocol and intentionally import the
implementation they are checking. That is not ambient authority for normal QIP
components.

Execution policies can tighten the module before it runs:

```bash
qip run --timeout-ms 1000 --max-memory 1048576 --fixed-memory modules/utf8/trim.wasm
qip bench -i input.txt --timeout-ms 1000 --max-memory 1048576 --fixed-memory modules/utf8/trim.wasm
qip image -i in.png -o out.png --timeout-ms 1000 --max-memory 8388608 --fixed-memory modules/rgba/invert.wasm
```

Use the same policy shape in browser hosts:

```html
<qip-edit max-memory="1048576" fixed-memory>
  <source src="/components/text/markdown/commonmark.0.31.2.wasm" type="application/wasm" />
</qip-edit>
```

`--max-memory <bytes>` rejects modules whose declared linear memory minimum or maximum exceeds the byte cap. A module with memory but no declared maximum is rejected when this flag is set.

`--fixed-memory` rejects modules that can grow linear memory while they run. Internally this means rejecting the WebAssembly `memory.grow` instruction. Publicly, call this fixed memory: the component must stay inside the memory it starts with.

`--timeout-ms <ms>` bounds how long a CLI stage may run. Use it with memory policy: timeouts handle runaway execution, while fixed memory handles runaway allocation.

Use `qip score` to inspect loop shape:

```bash
qip score modules/utf8/luhn.wasm
```

The `fixed_bound_loops` line is a conservative static check. `PASS` means every Wasm loop with a backedge matched the accepted counter pattern. `WARN` means QIP could not prove the bound from the binary.

Use the safety checker component when the Wasm artifact itself should enforce the strict profile:

```bash
qip run -i component.wasm -- modules/application/wasm/wasm-safety-check.wasm
```

The checker currently rejects ambient imports, missing memory maximums, `memory.grow`, shared memory, atomics, indirect calls, recursion, and loops whose fixed bound cannot be proven.

## Why Budgets Help

Budgets make components easier to run in more than one place.

Determinism is the main reason. If a component cannot read the filesystem, call the network, inspect environment variables, query the clock, or grow into a larger runtime, the same input bytes are much more likely to produce the same output bytes across CLI, browser, server, desktop, and mobile hosts.

That also helps testing. You can snapshot output bytes, run `qip comply`, and benchmark a component without recreating the application environment around it.

The security benefit is narrow blast radius. Sandboxing does not prove the code is correct, but it limits what buggy, malicious, or AI-generated code can touch. The component can transform the bytes it receives. It cannot borrow the user's session, read unrelated app state, scan the disk, phone home, or ask the GPU to do work behind the host's back.

The tradeoff is that QIP asks you to budget work up front. For content transforms, validators, image filters, and small interactive renderers, that is usually a good trade. For components that need open-ended allocation, many system calls, or a large language runtime, QIP may be the wrong boundary.

## Fixed Memory

There are two related but different controls:

- A declared memory maximum tells the host how large linear memory may become.
- A fixed-memory policy rejects modules that contain `memory.grow`.

Compiler flags can set the memory maximum. They do not always prove the final binary contains no growth instruction. Allocators and language runtimes may still include code paths that try to grow memory, even if growth would fail at runtime.

For QIP, use both sides:

1. Compile with a declared memory budget.
2. Avoid allocator paths that require runtime growth.
3. Validate the final `.wasm` with QIP policy.

```bash
qip run --max-memory 1048576 --fixed-memory component.wasm
```

## Fixed-Bound Loops

A loop bound has to be visible in the compiled Wasm, not only obvious in the source language.

The safety checker accepts the common counter-loop shape: compare a local counter with a limit, branch out of the loop when the limit is reached, update the same counter by `+1` or `-1`, then branch back. This covers ordinary loops such as `while (i < input.len) : (i += 1)` after compilation.

It rejects a loop like `loop { br 0 }` because there is a backedge but no counter, no update, and no exit bound.

This is not a general termination proof. If a loop is safe but compiled into a shape the checker does not understand, rewrite the loop into a simpler counter form or treat the warning as a review item.

## Zig

Zig is a good default for QIP components because freestanding WebAssembly is a normal target and the build command can say what memory shape you want.

Use `--max-memory` so the module declares a maximum. If you want the linker-level equivalent of non-growable memory, set initial and maximum memory to the same value:

```bash
zig build-exe component.zig \
  -target wasm32-freestanding \
  -O ReleaseSmall \
  -fno-entry \
  -rdynamic \
  --stack 65536 \
  --initial-memory=1048576 \
  --max-memory=1048576 \
  -femit-bin=component.wasm
```

Keep ordinary QIP components simple:

- Use static input, output, and scratch buffers.
- Avoid heap allocation for normal content transforms.
- Use `std.heap.FixedBufferAllocator` only when an allocator-shaped API is worth it.
- Trap on input overflow, invalid data, and output overflow.
- Run the final artifact with `--fixed-memory`.

The repo Makefile uses `--max-memory=$(ZIG_WASM_MAX_MEMORY)` for Zig modules and lets individual modules override the value when they need a tighter or larger budget.

## C And Clang

For freestanding C, the LLVM WebAssembly linker has the clearest spelling:

```bash
clang --target=wasm32 -nostdlib -Oz component.c \
  -Wl,--no-entry \
  -Wl,--no-growable-memory \
  -Wl,-z,stack-size=65536 \
  -Wl,--export=render \
  -Wl,--export=input_ptr \
  -Wl,--export=input_utf8_cap \
  -Wl,--export=output_ptr \
  -Wl,--export=output_utf8_cap \
  -Wl,--export-memory \
  -o component.wasm
```

`--no-growable-memory` sets the maximum memory size to the initial memory size. The explicit form is also valid:

```bash
-Wl,--initial-memory=1048576 -Wl,--max-memory=1048576
```

These are linker settings, not a substitute for code discipline. Prefer static arrays, avoid `malloc`, avoid libc features that expect a larger runtime, and validate the final module with QIP.

The same linker flags work through `zig cc`:

```bash
zig cc component.c -target wasm32-freestanding -nostdlib \
  -Wl,--no-entry \
  -Wl,--no-growable-memory \
  -Wl,-z,stack-size=65536 \
  -Oz -o component.wasm
```

See the LLVM lld WebAssembly documentation for `--initial-memory`, `--max-memory`, and `--no-growable-memory`: <https://lld.llvm.org/WebAssembly.html>.

## Rust

Rust can produce QIP-shaped WebAssembly, but you need to be clear about allocation.

Start with `no_std` when you want fixed memory:

```rust
#![no_std]
```

Then avoid `alloc` unless you have deliberately provided a fixed allocator. Treat `Vec`, `String`, `Box`, formatting that allocates, and allocator-using crates as signs that the component may no longer be a small fixed-budget transform.

Pass the linker policy through `RUSTFLAGS`:

```bash
RUSTFLAGS="-C link-arg=--no-growable-memory" \
  cargo build --release --target wasm32-unknown-unknown
```

Or use explicit equal memory values:

```bash
RUSTFLAGS="-C link-arg=--initial-memory=1048576 -C link-arg=--max-memory=1048576" \
  cargo build --release --target wasm32-unknown-unknown
```

For strict QIP components, prefer:

- `#![no_std]`
- `panic = "abort"`
- fixed input/output buffers
- no default allocator
- no crates that need filesystem, network, time, threads, randomness, or process state
- final validation with `qip run --max-memory ... --fixed-memory`

The Rust `wasm32-unknown-unknown` target is intentionally minimal, but Rust still supports allocation on that target when the program opts into it. Read the target notes before assuming a crate is QIP-shaped: <https://doc.rust-lang.org/rustc/platform-support/wasm32-unknown-unknown.html>.

## WebAssembly Text

For hand-written `.wat`, declare both initial and maximum memory pages and do not emit `memory.grow`:

```wat
(memory (export "memory") 16 16)
```

WebAssembly pages are `64 KiB`, so `16` pages is `1 MiB`.

This is the easiest format to inspect, which is why small comply modules and tiny validators are often pleasant to write in WAT.

## Adoption Checklist

- Pick a memory budget before the component grows around accidental allocation.
- Compile with an explicit memory maximum.
- Prefer fixed memory for production components and unreviewed code.
- Keep filesystem, network, GPU, environment, clock, token, and app-state access in the host.
- Pass required data into the component as bytes.
- Add `--max-memory` and `--fixed-memory` to CI for modules that should obey the strict profile.
- Add `--timeout-ms` when running untrusted or expensive components in the CLI.
- Use `qip bench` after correctness is locked down so performance work stays measurable.
