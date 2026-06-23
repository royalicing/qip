# WebAssembly ES Module Integration

QIP components fit the WebAssembly ES module proposal because the contract is already a small set of named exports.

The proposal lets JavaScript import WebAssembly exports directly from a `.wasm` file. That means a QIP module can look like an ordinary ES module at the loading boundary, while still keeping QIP's explicit memory contract for the actual data exchange.

## Markdown To HTML

Use this pattern when a browser or runtime supports WebAssembly ES module imports and you want one UTF-8 QIP component as a plain JavaScript function.

```js
import {
  memory,
  input_ptr,
  input_utf8_cap,
  output_ptr,
  output_utf8_cap,
  render,
} from "/components/text/markdown/commonmark.0.31.2.wasm";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function markdownToHtml(markdown) {
  const inputBytes = encoder.encode(markdown);
  const inputPtr = input_ptr();
  const inputCap = input_utf8_cap();

  if (inputBytes.length > inputCap) {
    throw new RangeError(`markdown input exceeds input_utf8_cap (${inputBytes.length} > ${inputCap})`);
  }

  new Uint8Array(memory.buffer, inputPtr, inputBytes.length).set(inputBytes);

  const outputLen = render(inputBytes.length);
  const outputPtr = output_ptr();
  const outputCap = output_utf8_cap();

  if (outputLen < 0 || outputLen > outputCap) {
    throw new RangeError(`html output exceeds output_utf8_cap (${outputLen} > ${outputCap})`);
  }

  return decoder.decode(new Uint8Array(memory.buffer, outputPtr, outputLen));
}

console.log(markdownToHtml("# Hello\n\nThis came from QIP."));
```

The important part is not the loader. It is the boundary:

- Encode JavaScript text as UTF-8 bytes.
- Write those bytes at `input_ptr()`.
- Call `render(input_size)`.
- Read `outputLen` bytes from `output_ptr()`.
- Decode the result as UTF-8.

That is the same flow `qip run` uses, just written directly in JavaScript.

The `outputLen < 0` check is intentional. WebAssembly `i32` results cross into JavaScript as signed `Number` values, while QIP output lengths are non-negative byte counts. A negative result means the module did not return a valid QIP length, and failing there gives a clearer error than passing a bad length into `Uint8Array`.

## Traps

If the QIP component traps, the imported WebAssembly function throws a JavaScript exception. For content components, QIP treats traps as hard failure; they often mean invalid input, capacity overflow, or a violated precondition.

```js
try {
  return markdownToHtml(markdown);
} catch (err) {
  if (err instanceof WebAssembly.RuntimeError) {
    throw new Error("markdown component rejected the input", { cause: err });
  }
  throw err;
}
```

Do not read `output_ptr()` after a trapped `render(...)`. The output buffer may contain stale or partial bytes. Treat the render as failed and either report the error or retry after writing fresh input and setting the required uniforms again.

A trap does not normally terminate the WebAssembly instance. The ES module binding still points at the same instance, and later calls can still run. The catch is that traps do not roll back memory, globals, or other state mutated before the trap. Components should validate before mutating persistent state when possible; wrappers that reuse a singleton instance should assume output scratch memory is dirty after a trap.

If a component can leave important internal state inconsistent after a trap, do not use a direct singleton import for untrusted inputs. Instantiate a fresh module for that work, or add an explicit recovery/reset export to the component and document it as part of that component's API.

## Why This Fits

The ES module integration proposal exposes WebAssembly exports as named ES module bindings. QIP's content contract is intentionally named and small:

- `memory`
- `input_ptr()`
- `input_utf8_cap()` or `input_bytes_cap()`
- `output_ptr()`
- `output_utf8_cap()` or `output_bytes_cap()`
- `render(input_size)`

This makes the direct import readable. There is no generated glue layer in the middle, and there is no hidden object protocol to learn.

The tradeoff is that direct ES module imports create an instance through the module graph. That is pleasant for simple transforms, but callers should remember that module memory and uniforms are shared by every import of the same `.wasm` URL.

Use direct imports when:

- One module instance is enough for the page or worker.
- Calls are serialized or the module has disjoint buffers for your usage.
- The wrapper sets every uniform it needs immediately before each `render(...)` call.

Direct imports are less useful when:

- You need one fresh instance per request.
- You want to run the same module concurrently.
- You want persistent preconfigured renderers with independent mutable state.

For those cases, fall back to `WebAssembly.compileStreaming` / `WebAssembly.instantiate` so instance ownership is explicit.

## Current Support

WebAssembly ES module integration is still a platform feature, not a QIP-specific feature. Check the target browser, server runtime, or bundler before relying on direct `.wasm` imports.

When support is missing, the QIP contract does not change. Only the loading step changes:

```js
const module = await WebAssembly.compileStreaming(
  fetch("/components/text/markdown/commonmark.0.31.2.wasm"),
);
const instance = await WebAssembly.instantiate(module, {});
```

After that, use `instance.exports` with the same `memory`, pointer, capacity, and `render` calls.
