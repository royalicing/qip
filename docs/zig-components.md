# Writing QIP Components In Zig

Zig works well for QIP components because it can emit small freestanding WebAssembly without bringing a runtime, filesystem, or package graph along for the ride.

The tradeoff is that you are responsible for being explicit about the WebAssembly shape you want. For QIP, that means exporting a small ABI, using fixed buffers, and compiling with a maximum memory size.

## Build With A Memory Maximum

Compile Zig components with `--max-memory` so the component's worst-case linear memory is visible in the Wasm binary. For the cross-language resource policy, including fixed memory and `memory.grow` checks, see [Hard Limits](/docs/hard-limits).

Without this flag, Zig can emit a memory with an initial size but no declared maximum. That still runs in `qip`, but it is harder to inspect and it fails stricter safety checks that require fixed memory. A maximum also keeps review honest: if a component needs 20 MiB, the build command says so.

Use a value that covers static buffers, stack, and compiler-required runtime space:

```bash
zig build-exe component.zig \
  -target wasm32-freestanding \
  -O ReleaseSmall \
  -fno-entry \
  -rdynamic \
  --max-memory=1048576 \
  -femit-bin=component.wasm
```

If the cap is too small, Zig/wasm-ld reports the required size. Raise the limit deliberately rather than using a very large default.

When not to use a tight cap:

- Early prototyping, when buffer sizes are still moving.
- Large static tables, where the right cap is easier to choose after the first successful build.
- Interactive components with frame buffers, where width, height, and scratch space should be budgeted together.

Even then, add the cap before checking in the module.

## Minimal Content Component

This component accepts UTF-8 text and returns it unchanged. The example is simple so the ABI shape is visible.

```zig
const INPUT_CAP: usize = 64 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&output_buf)));
}

export fn output_utf8_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

export fn render(input_size_in: u32) u32 {
    const input_size: usize = @intCast(input_size_in);
    if (input_size > INPUT_CAP) @trap();

    @memcpy(output_buf[0..input_size], input_buf[0..input_size]);
    return input_size_in;
}
```

Build it:

```bash
zig build-exe echo.zig \
  -target wasm32-freestanding \
  -O ReleaseSmall \
  -fno-entry \
  -rdynamic \
  --max-memory=1048576 \
  -femit-bin=echo.wasm
```

Run it:

```bash
printf 'hello' | qip run echo.wasm
```

## Defaults We Prefer

QIP components age well when their resource shape is obvious from the source.

Use these defaults unless the module has a concrete reason not to:

- Static input, output, and scratch buffers sized by named constants.
- No allocator for normal content transforms.
- `@trap()` for invalid input, violated invariants, and output overflow.
- `error` unions internally, converted to `@trap()` at the exported boundary.
- Small exported surface: QIP ABI exports plus intentional `uniform_set_*` functions.
- `usize` for indexing inside Zig; cast at the ABI boundary.
- `u32` for exported pointers, sizes, caps, and return values.
- Simple `while` loops with visible bounds.
- Explicit content-type exports when the module knows its exact input or output format.

Avoid these by default:

- `@panic` for expected validation failures. Prefer `@trap()` so the component fails hard without pretending there is a recoverable runtime.
- Heap allocation for ordinary one-input/one-output transforms. Static buffers are easier to inspect and budget.
- Hidden global state that changes `render` behavior unless it is set through a documented uniform.
- Recursion in modules intended to pass strict safety checks.

This does not mean every useful component must be tiny. It means the cost of a component should be visible in constants and exports instead of discovered at runtime.

## Choose The Right Buffers

Use `input_utf8_cap` / `output_utf8_cap` for text and `input_bytes_cap` / `output_bytes_cap` for raw bytes.

QIP checks the host side of the capacity contract before writing input and after `render` returns. The component should still check its own assumptions and trap when an invariant fails. That keeps bugs obvious and prevents accidental truncation.

Good defaults:

- Validate `input_size <= INPUT_CAP` even though the host also checks it.
- Trap on malformed input for normalizers and transforms.
- Trap on output overflow.
- Return `0` only when empty output is a meaningful success.

For assertion pass-through validators, copy the input unchanged or use the same pointer for input and output when the host contract allows it. `components/utf8/utf8-must-be-valid.zig` is the model: validate every byte, trap on failure, and preserve the original bytes on success.

## Export Content Types When Known

Content-type exports make pipelines easier to compose and inspect.

```zig
const INPUT_CONTENT_TYPE = "application/wasm";
const OUTPUT_CONTENT_TYPE = "application/wasm";

export fn input_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr)));
}

export fn input_content_type_size() u32 {
    return @as(u32, @intCast(INPUT_CONTENT_TYPE.len));
}

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(OUTPUT_CONTENT_TYPE.len));
}
```

Do not export `text/plain` for generic UTF-8 transforms. The UTF-8 cap already communicates that. Export a MIME type when the component requires or guarantees a specific format, such as `application/wasm`, `text/html`, `image/bmp`, or `image/svg+xml`.

## Use Uniforms For Configuration

Prefer uniforms over parsing ad hoc control bytes from the main input.

Uniforms keep the data plane clean: the input stays the content being transformed, while runtime options configure behavior before `render` runs.

```zig
var color_rgba: u32 = 0x000000FF;

export fn uniform_set_color_rgba(value: u32) u32 {
    color_rgba = value;
    return color_rgba;
}
```

Callers pass uniforms next to the module path:

```bash
qip run components/image/svg+xml/svg-recolor-current-color.wasm -u color_rgba=0xff5511ff
```

Use packed integer uniforms for compact settings like colors, flags, and modes. Use `f32` uniforms for image math where fractional values are natural.

## Keep The Wasm Easy To Inspect

Sandboxing is not enough by itself. Keep the Wasm easy to audit.

For safety-oriented modules, prefer:

- No imports.
- No `memory.grow`.
- No recursion.
- Fixed-bound loops with a visible counter and exit condition.
- No indirect calls unless there is a specific need.
- Fixed memory maximum via `--max-memory`.
- Small exported surface: only the QIP contract and intentional uniforms.

For strict safety-check-clean modules, replace recursion with an explicit stack. A recursive-descent parser with a `MAX_DEPTH` guard is often fine for practical transforms, but it still has a recursive call graph. If the module is a safety gate, validator, or infrastructure component, use iterative traversal so the binary passes no-recursion checks.

For loops, write the bound in the loop condition when possible:

```zig
var i: usize = 0;
while (i < input.len) : (i += 1) {
    // parse one byte or advance deliberately
}
```

The safety checker looks at the final Wasm. It accepts the normal counter-loop shape where a local counter is compared to a bound, updated by `+1` or `-1`, and then branches back. If a loop advances by variable amounts, make every branch either advance or trap; this is easier to review, but it may still need a simpler counter shape if the strict checker cannot prove the bound.

You can inspect the resulting module with WABT:

```bash
wasm-objdump -x component.wasm
```

Look for a memory entry with both initial and max pages:

```text
Memory[1]:
 - memory[0] pages: initial=... max=...
```

## Makefile Pattern

For checked-in modules, prefer the project rule over a one-off command. The Makefile sets a default `ZIG_WASM_MAX_MEMORY` for Zig modules, and individual targets can override it when they need a larger or tighter budget.

```make
ZIG_WASM_MAX_MEMORY ?= 67108864

components/%.wasm: components/%.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

components/bytes/example.wasm: ZIG_WASM_MAX_MEMORY = 1048576
```

Use the generic default for ordinary modules. Add target-specific overrides for modules with large static buffers, frame buffers, embedded tables, or intentionally tighter safety budgets.

For C components compiled through `zig cc`, pass the linker spelling instead:

```make
components/utf8/example-c.wasm: components/utf8/example-c.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib \
		-Wl,--no-entry -Wl,--max-memory=1048576 \
		-Wl,--export=render -Wl,--export-memory \
		-Wl,--export=input_ptr -Wl,--export=input_utf8_cap \
		-Wl,--export=output_ptr -Wl,--export=output_utf8_cap \
		-Oz -o $@
```

Zig uses `--max-memory=...`; `zig cc` passes `-Wl,--max-memory=...` to the Wasm linker.

## Testing And Review

Each component should have at least one direct smoke test through `qip`.

```bash
printf 'hello' | qip run components/utf8/your-module.wasm
```

For binary modules, round-trip through files or compare bytes:

```bash
qip run -i input.bin -- components/bytes/your-module.wasm > /tmp/out.bin
cmp expected.bin /tmp/out.bin
```

For validators, test both success and failure:

```bash
printf 'valid' | qip run components/utf8/your-validator.wasm
printf '\xff' | qip run components/utf8/your-validator.wasm
```

Also test recovery on a reused instance: feed a range of invalid inputs that trap, then feed valid input through the same instance and confirm the result is still correct. A WebAssembly trap stops the current call, but it does not reset memory or globals. This catches parsers that mutate persistent state before rejecting malformed input.

Review the binary shape before trusting the source shape:

```bash
wasm-objdump -x components/bytes/your-module.wasm
qip score components/application/wasm/your-module.wasm
```

Use `qip score` as a quick smell test for imports, indirect calls, recursion, loop-bound evidence, and control-flow weight. Use `components/application/wasm/wasm-validate-core-1.0.wasm` for WebAssembly Core 1.0 specification validation. Use the policy checkers `components/application/wasm/wasm-strict-profile.wasm` (fixed memory, no imports, no banned instructions, no recursion, and static content-type metadata) and `components/application/wasm/wasm-bounded-loops.wasm` (fixed-bound loops) when the valid module should also obey the strict profile. Use `components/application/wasm/wasm-bounded-output.wasm` when `render` carries the recognized proof that its successful result does not exceed the static output capacity.

The QIP ABI can be expressed in WebAssembly Core 1.0, while the standard
component build targets Core 2.0 features such as bulk memory. Current Chrome,
Firefox, and Safari releases implement the Core 2.0 feature set, but there is no
single browser switch named “Core 2.0”: support arrived feature by feature and
older browsers remain in use. Check the WebAssembly project's
[Feature Status](https://webassembly.org/features/) table for the first browser
version supporting each feature, and use `WebAssembly.validate()` when selecting
an optional optimized component such as a SIMD variant.

## Checklist

- Pick UTF-8 or bytes caps before writing parsing logic.
- Keep input and output buffers sized from explicit constants.
- Trap on invalid input, oversized input, and output overflow.
- Test invalid input followed by valid input on the same instance.
- Compile with `--max-memory`.
- Run `wasm-objdump -x` and confirm `max=...` is present.
- Check for accidental imports, indirect calls, tables, and recursion.
- Smoke test with `qip run`.
