# Hard Limits

QIP components run behind a byte-oriented interface. The host writes input into
linear memory, calls a known export, and reads the output. A component does not
receive a filesystem, network connection, clock, DOM, cookies, environment
variables, GPU access, or application secrets unless the host explicitly passes
that information in.

This boundary is useful only if its resource limits are also explicit. A module
that cannot access the network but can allocate without limit or run forever is
still difficult to operate safely.

QIP therefore separates three controls:

| Control | What it limits | How QIP applies it |
| --- | --- | --- |
| Host access | What the component can observe or change | No WASI or other host imports |
| Linear memory | How much memory the component can declare or grow | `--max-memory` and `--fixed-memory` |
| Execution time | How long a CLI stage may run | `--timeout-ms` |

The host-access boundary is the normal component model. The memory flags are
currently opt-in, so a host must select them when loading unreviewed modules or
when enforcing a production budget.

## Apply A Runtime Policy

The same policy flags work with text, binary, and image components:

```bash
qip run --timeout-ms 1000 --max-memory 1048576 --fixed-memory modules/utf8/trim.wasm
qip bench -i input.txt --timeout-ms 1000 --max-memory 1048576 --fixed-memory modules/utf8/trim.wasm
qip image -i in.png -o out.png --timeout-ms 1000 --max-memory 8388608 --fixed-memory modules/rgba/invert.wasm
```

- `--max-memory <bytes>` rejects a module when its declared memory minimum or
  maximum exceeds the cap. It also rejects a module that declares memory without
  a maximum.
- `--fixed-memory` rejects a module containing `memory.grow`. Equal initial and
  maximum memory declarations are not enough: the instruction may still exist
  in allocator or runtime code, even though it can only fail.
- `--timeout-ms <ms>` limits the execution time of each CLI stage. It deals with
  runaway execution, not allocation.

Browser hosts expose the memory controls as attributes:

```html
<qip-edit max-memory="1048576" fixed-memory>
  <source src="/components/text/markdown/commonmark.0.31.2.wasm" type="application/wasm" />
</qip-edit>
```

Input and output have separate bounds. The component advertises buffer
capacities through its ABI exports; the host rejects data that does not fit.
Those checks prevent a host copy from crossing the advertised buffer. They do
not impose a useful total-memory budget by themselves.

## The Strict Wasm Profile

For components that need a statically inspectable execution shape, QIP defines
a stricter subset of WebAssembly:

- wasm32 with at most one linear memory
- no imports, including WASI and custom host callbacks
- a declared memory maximum and no `memory.grow`
- no shared memory or atomic instructions
- no indirect calls
- an acyclic direct call graph, which excludes recursion
- a statically recognizable bound for every loop backedge

Compliance modules are an exception to the import rule: they import the
implementation being tested. Ordinary QIP components do not.

Run the artifact checkers as a two-stage pipeline:

```bash
qip run -i component.wasm -- \
  modules/application/wasm/wasm-strict-profile.wasm \
  modules/application/wasm/wasm-bounded-loops.wasm
```

`wasm-strict-profile` checks imports, memory shape, banned instructions, indirect
calls, and recursion. `wasm-bounded-loops` checks loop bounds. Keeping these
checks separate allows a host to enforce the structural profile while using a
runtime mechanism for execution, such as a timeout or fuel meter.

For a readable inspection report, use:

```bash
qip score component.wasm
```

`fixed_bound_loops: PASS` means every backedge matched the verifier's accepted
patterns. `WARN` means the verifier could not establish a bound. It does not
prove that the module loops forever.

## What The Loop Checker Can Prove

A source-level loop bound is irrelevant if the compiler removes or obscures it.
The checker works on the final Wasm binary. It looks for a local counter that:

1. changes monotonically inside the loop; and
2. participates in an exit comparison in the same direction.

Accepted updates include adding or subtracting a constant, division or shifts
toward zero, and those operations routed through a temporary local. The checker
also recognizes the common parser stride `i += 1 + len` when `len` is a known
non-negative narrow value.

Exit evidence may use signed or unsigned 32-bit or 64-bit comparisons against a
constant, local, global, or computed value. Countdown tests with `i32.eqz` are
also accepted. The exit may branch out of the loop, return from the function, or
pass through blocks whose paths all leave the loop or function.

Any unrecognized write to the candidate counter disqualifies it. For example,
`i = next_pos` might move the counter away from the bound. An unconditional
`loop { br 0 }` has no counter or exit and is rejected.

This is a deliberately conservative analysis, not a general termination proof.
If a safe loop compiles into an unsupported shape, simplify its counter, add an
explicit step budget, or run the component under a runtime execution limit.
[Provable Loops](provable-loops.md) contains verified source-level rewrites for
the common cases.

## Build With A Memory Budget

Choose the budget before selecting compiler flags. Account for input, output,
scratch space, stack, static data, and any allocator arena. Then inspect the
final `.wasm`; source code and linker settings do not establish the whole policy.

For small transforms, static buffers are usually the simplest arrangement. If
an API requires an allocator, put it over a fixed buffer. Treat overflow as an
error or trap rather than silently requesting more memory.

### Zig

Set an explicit initial and maximum memory when both should be 1 MiB:

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

The repository Makefile supplies `--max-memory=$(ZIG_WASM_MAX_MEMORY)` and
allows individual modules to override the value. `std.heap.FixedBufferAllocator`
is available when an allocator-shaped interface is useful without a growable
heap.

### C And Clang

LLVM's Wasm linker can make maximum memory equal initial memory:

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

The explicit equivalent is:

```bash
-Wl,--initial-memory=1048576 -Wl,--max-memory=1048576
```

The same linker flags work through `zig cc`. Avoid `malloc` and libc features
that assume a larger runtime unless you have provided and budgeted their memory.
See the [LLVM lld WebAssembly options](https://lld.llvm.org/WebAssembly.html) for
the linker semantics.

### Rust

Rust can produce a small freestanding component, but crate selection can
quietly reintroduce allocation. Start with `no_std` and abort on panic. Avoid
`alloc`, `Vec`, `String`, `Box`, allocating formatting, and allocator-dependent
crates unless a fixed allocator is part of the design.

Pass the memory setting to the linker:

```bash
RUSTFLAGS="-C link-arg=--no-growable-memory" \
  cargo build --release --target wasm32-unknown-unknown
```

The [`wasm32-unknown-unknown` target notes](https://doc.rust-lang.org/rustc/platform-support/wasm32-unknown-unknown.html)
describe the target's supported features. A minimal target does not imply that
the resulting program avoids allocation.

### WebAssembly Text

For hand-written WAT, declare equal initial and maximum page counts and omit
`memory.grow`:

```wat
(memory (export "memory") 16 16)
```

A WebAssembly page is 64 KiB, so 16 pages is 1 MiB.

## When This Boundary Does Not Fit

The restrictions buy a component that is easier to inspect, test, benchmark,
and run in different hosts. They do not prove correctness or make untrusted
output safe to consume. The host must still validate output according to how it
will be used.

QIP is a reasonable boundary for content transforms, validators, image filters,
and small interactive renderers with known input sizes. It is a poor fit for
work that genuinely needs open-ended allocation, operating-system services,
threads, recursive or highly irregular control flow, or a large managed
runtime. Keep that work in the host, or use a less restrictive execution model
with its own resource controls.

For production components:

1. Set a memory maximum at link time.
2. Run the final artifact with `--max-memory` and `--fixed-memory` in CI.
3. Keep ambient capabilities in the host and pass required data as bytes.
4. Use `--timeout-ms` for untrusted or expensive CLI stages.
5. Benchmark with `qip bench` after the contract and limits are stable.
