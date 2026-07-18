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
| Host access | What the component can observe or change | No WASI; only documented contract imports |
| Linear memory | How much memory the component can declare | Fixed by default; optional `--max-memory` cap |
| Execution time | How long a CLI stage may run | `--timeout-ms` |

The host-access boundary and fixed-memory policy are the normal component model.
A host may permit memory growth explicitly, but it must also set a byte cap.

## Where The CLI Enforces Each Rule

This page is the canonical map of Wasm validation in the CLI:

| Rule | `qip run` | `qip dry run` | `qip comply` |
| --- | --- | --- | --- |
| Component ABI and pipeline compatibility | Before execution | Yes, using the same pipeline planner | Base ABI and static contract checks for the implementation |
| Reject `memory.grow` | Every pipeline component, by default | Every pipeline component, by default | Not applied to the implementation |
| Enforce declared memory bounds | With `--max-memory` | With `--max-memory` | Not applied to the implementation |
| Strict Wasm artifact structure | Only when `wasm-strict-profile.wasm` is executed on input bytes | Validates the checker pipeline but does not inspect input bytes | Not currently applied |
| Recognizable bounded loops | Only when `wasm-bounded-loops.wasm` is executed on input bytes | Validates the checker pipeline but does not inspect input bytes | Not currently applied |
| Declarative Compliance checker | Not applicable | Not applicable | With `--declarative-checkers`, applied to every `--with` checker |

`qip run` and `qip dry run` share the Go module-policy validator. The strict
artifact and bounded-loop checks are currently executable QIP components, not
implicit modes of that validator. Dry run never reads or executes the input
being checked, so it cannot certify an artifact merely by planning the checker
pipeline.

## Apply A Runtime Policy

The same policy controls work with text, binary, and image components:

```bash
qip run --timeout-ms 1000 --max-memory 67108864 components/utf8/trim.wasm
qip bench -i input.txt --timeout-ms 1000 --max-memory 67108864 components/utf8/trim.wasm
qip image -i in.png -o out.png --timeout-ms 1000 --max-memory 8388608 components/rgba/invert.wasm
```

- `--max-memory <bytes>` rejects a module when its declared memory minimum or
  maximum exceeds the cap. It also rejects a module that declares memory without
  a maximum.
- Modules containing `memory.grow` are rejected by default. Equal initial and
  maximum memory declarations are not enough: allocator or runtime code may
  still contain the instruction, even though it can only fail.
- `--allow-memory-grow` permits `memory.grow` and requires `--max-memory` in the
  same command.
- `--timeout-ms <ms>` limits the execution time of each CLI stage. It deals with
  runaway execution, not allocation.

Browser hosts expose the memory controls as attributes:

```html
<qip-edit max-memory="67108864">
  <source src="/components/text/markdown/commonmark.0.31.2.wasm" type="application/wasm" />
</qip-edit>
```

Use `allow-memory-grow` only with an explicit cap:

```html
<qip-edit allow-memory-grow max-memory="16777216">
  <source src="/components/example.wasm" type="application/wasm" />
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
- no start function
- no indirect calls
- an acyclic direct call graph, which excludes recursion

Recognizable loop bounds are a separate check. They depend on conservative
proof patterns in compiler output rather than only on structural facts in the
artifact.

### Cost Of Structural Validation

Let `B` be the module size in bytes, `I` the decoded instruction count, `V` the
number of defined functions, and `E` the number of direct calls between defined
functions.

| Rule | Time | Additional space |
| --- | --- | --- |
| Reject imports | `O(B)` overall | `O(1)` |
| Validate the memory count, kind, sharing, and declared maximum | `O(B)` overall | `O(1)` |
| Reject a start function | `O(B)` overall | `O(1)` |
| Reject `memory.grow` | `O(I)` | `O(1)` |
| Reject atomic instructions | `O(I)` | `O(1)` |
| Reject indirect and reference-based calls | `O(I)` | `O(1)` |
| Detect recursive direct-call cycles | `O(V + E)` | `O(V + E)` |

Every call-graph edge comes from a decoded call instruction, so `V + E` is
bounded by the module size. The complete structural check is therefore `O(B)`
time. The call graph accounts for its linear additional memory.

The policy checker can read the module bytes once, checking every local rule
while it decodes and collecting direct-call edges. Once decoding finishes, it
runs a depth-first search over that graph. This is one pass over the module
bytes plus one graph traversal, not two passes over the Wasm file. A strictly
streaming constant-memory implementation is not sufficient for recursion:
functions may call functions defined later, so the graph cannot generally be
finalized while each function body is being read.

This policy checker assumes its input is already a valid WebAssembly module.
Full specification validation—section order and uniqueness, types, indices,
limits, constant expressions, and instruction typing—is a separate concern.
The policy reader still fails closed if it cannot safely decode an instruction
body, but that is not a substitute for the specification's validation
algorithm.

Compliance components use a separate declarative checker rule, enabled with
`qip comply --declarative-checkers`. They may import only the
documented oracle functions from the `qip` host module. The implementation
under test remains a separate instance and is not imported or memory-linked
into the checker. Ordinary QIP components still use the import-free artifact
profile above.

Run the artifact checkers as a two-stage pipeline:

```bash
qip run -i component.wasm -- \
  components/application/wasm/wasm-strict-profile.wasm \
  components/application/wasm/wasm-bounded-loops.wasm
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

Rust's `wasm32-unknown-unknown` target uses `dlmalloc` as its default allocator.
Allocator-using programs may therefore contain `memory.grow`. The linker option
`--no-growable-memory` only makes maximum memory equal initial memory; it does
not remove that instruction from allocator code.

For fixed-memory components, prefer `wasm32v1-none`, `no_std`, and either static
buffers or an allocator backed by a fixed static region. Set the memory shape at
link time, then let QIP inspect the final artifact:

```bash
RUSTFLAGS="-C link-arg=--initial-memory=1048576 -C link-arg=--max-memory=1048576" \
  cargo build --release --target wasm32v1-none

qip run target/wasm32v1-none/release/component.wasm
```

If an existing Rust component depends on a growable allocator, give it an
explicit host cap:

```bash
qip run --allow-memory-grow --max-memory 16777216 component.wasm
```

The [`wasm32-unknown-unknown` target notes](https://doc.rust-lang.org/rustc/platform-support/wasm32-unknown-unknown.html)
describe its default allocator. The [`wasm32v1-none` target](https://doc.rust-lang.org/rustc/platform-support/wasm32v1-none.html)
provides `core` and `alloc` without `std`; using `alloc` still requires a
component-supplied allocator.

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
2. Run the final artifact with `--max-memory` in CI; fixed memory is the default.
3. Keep ambient capabilities in the host and pass required data as bytes.
4. Use `--timeout-ms` for untrusted or expensive CLI stages.
5. Benchmark with `qip bench` after the contract and limits are stable.
