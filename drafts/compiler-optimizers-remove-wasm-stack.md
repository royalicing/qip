# The WebAssembly operand stack that disappeared

Status: draft, 2026-08-12.

Our WebAssembly-to-C translator produces code that looks inefficient. Each
function has an array for the operand stack, a stack pointer, union values, and
many small copies.

WABT `wasm2c` does more work during translation. It converts WebAssembly stack
values into typed C local variables. We expected its generated code to be much
faster than ours.

Then we measured CommonMark:

| Translator | Mean time |
| --- | ---: |
| WABT `wasm2c`, explicit bounds | 0.470 ms |
| QIP generated C, explicit bounds and dirty tracking | 0.482 ms |

Our simpler generated code was only 2.5 percent slower in this test. We wanted
to know why.

## The source code looked busy

The Zig backend uses the same simple design as the C backend. A generated
multiplication has this form:

```zig
stack[sp].u32_ = input;
sp += 1;
stack[sp].u32_ = 1664525;
sp += 1;
stack[sp - 2].u32_ =
    stack[sp - 2].u32_ *% stack[sp - 1].u32_;
sp -= 1;
```

The complete test function had a 34-slot value array. It also had a local
array, temporary call arguments, a generated function call, and trap state.

This was correct code, but it did not look like efficient native code.

## The machine code had no operand stack

We compiled a small generated function with Apple Clang and Zig. Its input was
dynamic, so the compiler could not calculate the answer in advance.

Both compilers produced this central ARM64 sequence:

```asm
madd    w8, w0, w8, w9
eor     w8, w8, w0, ror #19
mul     w8, w8, w9
lsr     w0, w8, #16
```

The operand array was gone. The stack pointer was gone. The unions, temporary
arguments, and generated call were also gone.

The optimized LLVM function had the `memory(none)` attribute. The values lived
in registers. Zig `ReleaseSafe` produced the same arithmetic sequence for this
test.

We repeated the test with `f32` arithmetic and bit reinterpretation. The
generated union stack became direct float-register instructions.

This was the exciting part: the compiler recovered much of the typed value flow
that `wasm2c` had calculated during translation.

## Swift did it too

We do not have a Swift backend yet, so we wrote an equivalent Swift function.
It used a temporary buffer of raw 64-bit value slots, typed accessors, and a
runtime stack pointer.

Swift 6.3 with `-O` removed the buffer, accessors, subscripts, and stack pointer.
Its optimized arithmetic matched a function written with typed Swift local
variables. The float version also became direct float-register instructions.

One small cost remained. `withUnsafeTemporaryAllocation` kept a stack-canary
check. Typed Swift locals did not need that check.

This result gives us a useful starting point for the Swift backend. We can first
generate a simple and direct model of WebAssembly. We do not need to build a
complex typed-stack compiler before we have performance evidence that requires
one.

## Why this works

The generated stack is easier to analyze than a general array:

- Its size is constant.
- Most indexes become constant after inlining.
- The stack pointer changes by known amounts.
- The storage does not leave the function.

LLVM can split the array into separate values. It can then remove dead stores,
copies, and indexes.

This optimization is not guaranteed. Complex branches, large functions,
indirect calls, dynamic indexes, and escaped pointers can keep stack operations
in the final code.

The compiler also cannot freely remove WebAssembly memory bounds checks or QIP
dirty-page writes. Those operations preserve observable behavior. This is one
reason the image benchmark had a larger difference: bounds-checked `wasm2c` was
approximately 10.5 percent faster than QIP generated C.

## Inspect before you optimize the translator

The lesson is not “source structure does not matter.” The lesson is more
practical:

1. Generate simple code with correct semantics.
2. Test it with representative components.
3. Inspect optimized IR and assembly.
4. Add translator complexity only when avoidable work remains.

The experiment covered two small functions on one ARM64 Mac. The Swift test was
hand-written because its backend does not exist yet. The
[complete C benchmark report](../docs/qip-component-to-c-benchmarks.md) gives
the machine, inputs, flags, output checks, and broader results.

## TODO: identify the LLVM transformations

Use LLVM optimization records and pass-by-pass IR to find the first pass that
removes the operand array and stack pointer. Check the roles of inlining, scalar
replacement, memory-to-register promotion, constant propagation, and
dead-store elimination. Do not infer the pass sequence only from the final IR.
