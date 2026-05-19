# JavaScript Runner: Annotated Source

The qip contract in tiny, pure JavaScript. Write bytes to `input_ptr`, call `render(input_size)`, read bytes from `output_ptr`.

- Raw source: [`/qip-runner.js`](/qip-runner.js)
- API:
  - `await QIP.render(wasmModule, input)`
  - `const recipe = new QIP.Recipe(inputMimeType, modules); await recipe.render(input)`

<style>
main { max-width: none; }

.annotated-source {
  width: 100%;
  border-collapse: collapse;
  table-layout: fixed;
  
  td {
    vertical-align: top;
    border-top: 1px solid color-mix(in srgb, currentColor 20%, transparent);
    padding: 0.75rem;
  }
  td:first-child {
    width: 32%;
  }
  td:last-child {
    width: 68%;
  }
  pre {
    margin: 0;
    white-space: pre;
    overflow-x: auto;
  }
}
</style>

<table class="annotated-source">
  <tr>
    <td>
      <strong>Core utilities</strong><br>
      Numeric conversion, MIME normalization, and export value reading all fail fast with explicit errors.
    </td>
    <td>
<pre><code class="language-js">const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder("utf-8", { fatal: true });

function toI32(value, label) {
  const n = typeof value === "bigint" ? Number(value) : value;
  if (typeof n !== "number" || !Number.isFinite(n)) {
    throw Error(label + " returned non-finite numeric value");
  }
  return n | 0;
}

function normalizeMimeType(value) {
  if (typeof value !== "string") return "";
  const trimmed = value.trim().toLowerCase();
  if (trimmed === "") return "";
  const semi = trimmed.indexOf(";");
  return semi === -1 ? trimmed : trimmed.slice(0, semi).trim();
}

function valueFromExport(exportsObj, name, required) {
  const value = exportsObj[name];
  if (typeof value === "function") return toI32(value(), name);
  if (value instanceof WebAssembly.Global) return toI32(value.value, name);
  if (typeof value === "number" || typeof value === "bigint") return toI32(value, name);
  if (required) throw Error("module missing export " + name);
  return null;
}
</code></pre>
    </td>
  </tr>

  <tr>
    <td>
      <strong>Memory safety helpers</strong><br>
      Every memory read/write performs pointer and bounds checks.
    </td>
    <td>
<pre><code class="language-js">function readSlice(memory, ptr, len, label) {
  if (!(memory instanceof WebAssembly.Memory)) {
    throw Error("module export memory must be WebAssembly.Memory");
  }
  if (ptr < 0 || len < 0) {
    throw Error(label + " returned negative pointer/size");
  }
  const start = ptr >>> 0;
  const size = len >>> 0;
  const end = start + size;
  const mem = new Uint8Array(memory.buffer);
  if (end < start || end > mem.length) {
    throw Error(label + " exceeds wasm memory bounds");
  }
  return mem.slice(start, end);
}

function writeSlice(memory, ptr, bytes, label) {
  if (!(memory instanceof WebAssembly.Memory)) {
    throw Error("module export memory must be WebAssembly.Memory");
  }
  const start = ptr >>> 0;
  const end = start + bytes.length;
  const mem = new Uint8Array(memory.buffer);
  if (ptr < 0 || end < start || end > mem.length) {
    throw Error(label + " exceeds wasm memory bounds");
  }
  mem.set(bytes, start);
}
</code></pre>
    </td>
  </tr>

  <tr>
    <td>
      <strong>Module loading</strong><br>
      `wasmModule` can be an instance, compiled module, URL string, `Response`, `Uint8Array`, `ArrayBuffer`, or typed view.
    </td>
    <td>
<pre><code class="language-js">async function instantiateWasm(wasmModule) {
  if (wasmModule instanceof WebAssembly.Instance) return wasmModule;

  if (wasmModule instanceof WebAssembly.Module) {
    const out = await WebAssembly.instantiate(wasmModule, {});
    return out instanceof WebAssembly.Instance ? out : out.instance;
  }

  if (typeof wasmModule === "string") {
    const response = await fetch(wasmModule);
    if (!response.ok) {
      throw Error("failed to fetch wasm module: " + response.status + " " + response.statusText);
    }
    const bytes = await response.arrayBuffer();
    const out = await WebAssembly.instantiate(bytes, {});
    return out instanceof WebAssembly.Instance ? out : out.instance;
  }

  if (wasmModule && typeof wasmModule.arrayBuffer === "function") {
    const bytes = await wasmModule.arrayBuffer();
    const out = await WebAssembly.instantiate(bytes, {});
    return out instanceof WebAssembly.Instance ? out : out.instance;
  }

  // ... Uint8Array / ArrayBuffer / TypedArray branch ...
}
</code></pre>
    </td>
  </tr>

  <tr>
    <td>
      <strong>Contract parsing</strong><br>
      The runner supports qip’s dual style exports: function or global for pointers/caps.
    </td>
    <td>
<pre><code class="language-js">function parseInputSignature(exportsObj) {
  const inputPtr = valueFromExport(exportsObj, "input_ptr", true);
  const utf8Cap = valueFromExport(exportsObj, "input_utf8_cap", false);
  const bytesCap = valueFromExport(exportsObj, "input_bytes_cap", false);

  if (utf8Cap !== null) return { ptr: inputPtr, cap: utf8Cap, kind: "utf8" };
  if (bytesCap !== null) return { ptr: inputPtr, cap: bytesCap, kind: "bytes" };
  throw Error("module must export input_utf8_cap or input_bytes_cap");
}

function parseOutputSignature(exportsObj) {
  const outputPtr = valueFromExport(exportsObj, "output_ptr", false);
  const utf8Cap = valueFromExport(exportsObj, "output_utf8_cap", false);
  const bytesCap = valueFromExport(exportsObj, "output_bytes_cap", false);
  const i32Cap = valueFromExport(exportsObj, "output_i32_cap", false);

  if (outputPtr === null || (utf8Cap === null && bytesCap === null && i32Cap === null)) {
    return { kind: "scalar" };
  }

  if (utf8Cap !== null) return { kind: "utf8", ptr: outputPtr, cap: utf8Cap, itemSize: 1 };
  if (bytesCap !== null) return { kind: "bytes", ptr: outputPtr, cap: bytesCap, itemSize: 1 };
  return { kind: "i32", ptr: outputPtr, cap: i32Cap, itemSize: 4 };
}
</code></pre>
    </td>
  </tr>

  <tr>
    <td>
      <strong>Stage execution (`renderDetailed`)</strong><br>
      This is the qip loop: validate types, write input bytes, call `render`, read output.
    </td>
    <td>
<pre><code class="language-js">async function renderDetailed(wasmModule, input, inputContentType) {
  const instance = await instantiateWasm(wasmModule);
  const exportsObj = instance.exports;
  const renderExport = exportsObj.render;
  if (typeof renderExport !== "function") {
    throw Error("module missing export: render");
  }

  const inputSignature = parseInputSignature(exportsObj);
  const outputSignature = parseOutputSignature(exportsObj);

  const normalized = toInputBytes(input);
  if (normalized.bytes.length > inputSignature.cap) {
    throw Error("input is too large for module");
  }

  writeSlice(exportsObj.memory, inputSignature.ptr, normalized.bytes, "input_ptr");
  const outputLen = toI32(renderExport(normalized.bytes.length), "render");

  // TODO: remove this
  if (outputSignature.kind === "scalar") {
    return outputLen;
  }

  const byteLen = outputLen * outputSignature.itemSize;
  const outputBytes = readSlice(exportsObj.memory, outputSignature.ptr, byteLen, "output_ptr");

  if (outputSignature.kind === "utf8") {
    return textDecoder.decode(outputBytes);
  }
  if (outputSignature.kind === "bytes") {
    return outputBytes;
  }
  return new Int32Array(outputBytes.buffer, outputBytes.byteOffset, outputLen);
}
</code></pre>
    </td>
  </tr>

  <tr>
    <td>
      <strong>Public `render`</strong><br>
      This returns only the stage output value: `string`, `Uint8Array`, `Int32Array`, or scalar `number`.
    </td>
    <td>
<pre><code class="language-js">export async function render(wasmModule, input) {
  const result = await renderDetailed(wasmModule, input, "");
  return result.value;
}
</code></pre>
    </td>
  </tr>

  <tr>
    <td>
      <strong>`Recipe` pipeline</strong><br>
      `Recipe` composes multiple render modules in stage order and tracks final MIME/kind metadata.
    </td>
    <td>
<pre><code class="language-js">export class Recipe {
  constructor(inputMimeType, arrayOfWasmModules) {
    if (!Array.isArray(arrayOfWasmModules) || arrayOfWasmModules.length === 0) {
      throw Error("Recipe requires a non-empty array of wasm modules");
    }
    this.inputMimeType = normalizeMimeType(inputMimeType);
    this.modules = arrayOfWasmModules.slice();
    this.lastRender = null;
  }

  async render(input) {
    let current = input;
    let currentMimeType = this.inputMimeType;

    for (let i = 0; i < this.modules.length; i += 1) {
      const isLast = i === this.modules.length - 1;
      const result = await renderDetailed(this.modules[i], current, currentMimeType);
      if (!isLast && (result.kind === "scalar" || result.kind === "i32")) {
        throw Error("only utf8/bytes can be piped to another stage");
      }
      current = result.value;
      if (result.outputContentType !== "") currentMimeType = result.outputContentType;
    }

    this.lastRender = { outputMimeType: currentMimeType };
    return current;
  }
}
</code></pre>
    </td>
  </tr>
</table>

## Usage Examples

```html
<script src="/qip-runner.js"></script>
<script type="module">
  const out = await QIP.render('/modules/utf8/hello.wasm', 'World');
  console.log(out); // Hello, World

  const recipe = new QIP.Recipe('text/markdown', [
    '/modules/text/markdown/commonmark.0.31.2.wasm',
    '/modules/text/html/html-page-wrap.wasm',
  ]);
  const html = await recipe.render('# qip');
  console.log(recipe.lastRender.outputMimeType, html.slice(0, 32));
</script>
```

```js
const fs = require('node:fs');
const { render, Recipe } = require('./site/qip-runner.js');

async function main() {
  const hello = await render(new Uint8Array(fs.readFileSync('modules/utf8/hello.wasm')), 'World');
  const recipe = new Recipe('', [
    new Uint8Array(fs.readFileSync('modules/utf8/trim.wasm')),
    new Uint8Array(fs.readFileSync('modules/utf8/hello.wasm')),
  ]);
  const out = await recipe.render('  qip  ');
  console.log(hello, out);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
```
