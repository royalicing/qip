# JavaScript Runner: Annotated Source

The qip contract in tiny, pure JavaScript. Write bytes to `input_ptr`, call `render(input_size)`, read bytes from `output_ptr`.

- Raw source: [`/qip-runner.js`](/qip-runner.js)
- API:
  - `import { createRecipe, render } from "/qip-runner.js"`
  - `const result = render(component, input); result.value`
  - `const recipe = createRecipe(inputMimeType, components); recipe.render(input).value`
  - `result.reusedInput` is true when a byte/text component returned the original input buffer unchanged.

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
  if (required) throw Error("component missing export " + name);
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
    throw Error("component export memory must be WebAssembly.Memory");
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
    throw Error("component export memory must be WebAssembly.Memory");
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
      <strong>Component instantiation</strong><br>
      The runner expects compiled `WebAssembly.Module` values. Fetching, streaming compilation, caching, and invalidation stay under caller control.
    </td>
    <td>
<pre><code class="language-js">function instantiateComponent(component) {
  if (!(component instanceof WebAssembly.Module)) {
    throw Error("component must be a WebAssembly.Module");
  }
  return new WebAssembly.Instance(component, {});
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

  if (utf8Cap !== null) return { ptr: inputPtr, cap: utf8Cap, encoding: "utf8" };
  if (bytesCap !== null) return { ptr: inputPtr, cap: bytesCap, encoding: "bytes" };
  throw Error("component must export input_utf8_cap or input_bytes_cap");
}

function parseOutputSignature(exportsObj) {
  const hasOutputPtr = "output_ptr" in exportsObj;
  const utf8Cap = valueFromExport(exportsObj, "output_utf8_cap", false);
  const bytesCap = valueFromExport(exportsObj, "output_bytes_cap", false);
  const i32Cap = valueFromExport(exportsObj, "output_i32_cap", false);

  if (!hasOutputPtr || (utf8Cap === null && bytesCap === null && i32Cap === null)) {
    return { encoding: "scalar" };
  }

  if (utf8Cap !== null) return { encoding: "utf8", cap: utf8Cap, itemSize: 1 };
  if (bytesCap !== null) return { encoding: "bytes", cap: bytesCap, itemSize: 1 };
  return { encoding: "i32", cap: i32Cap, itemSize: 4 };
}
</code></pre>
    </td>
  </tr>

  <tr>
    <td>
      <strong>Stage execution</strong><br>
      This is the qip loop: validate types, write input bytes, call `render`, then read `output_ptr`.
      Reading the pointer after `render` lets components return the original input buffer for unchanged output.
    </td>
    <td>
<pre><code class="language-js">function renderComponent(component, input, inputContentType = "", options = {}) {
  const instance = instantiateComponent(component);
  const exportsObj = instance.exports;
  const renderExport = exportsObj.render;
  if (typeof renderExport !== "function") {
    throw Error("component missing export: render");
  }

  const inputSignature = parseInputSignature(exportsObj);
  const outputSignature = parseOutputSignature(exportsObj);

  const declaredInputType = readContentType(exportsObj, exportsObj.memory, "input_content_type_ptr", "input_content_type_size");
  const declaredOutputType = readContentType(exportsObj, exportsObj.memory, "output_content_type_ptr", "output_content_type_size");
  const normalizedInputType = normalizeMimeType(inputContentType);
  if (declaredInputType !== "" && normalizedInputType === "" && options.strictInputContentType) {
    throw Error("input content type mismatch: expected " + declaredInputType + ", got unknown");
  }
  if (declaredInputType !== "" && normalizedInputType !== "" && declaredInputType !== normalizedInputType) {
    throw Error("input content type mismatch: expected " + declaredInputType + ", got " + normalizedInputType);
  }

  const normalized = toInputBytes(input);
  if (normalized.bytes.length > inputSignature.cap) {
    throw Error("input is too large for component");
  }

  writeSlice(exportsObj.memory, inputSignature.ptr, normalized.bytes, "input_ptr");
  const outputLen = toI32(renderExport(normalized.bytes.length), "render");

  if (outputSignature.encoding === "scalar") {
    return { value: outputLen, encoding: "scalar", contentType: declaredOutputType };
  }

  const byteLen = outputLen * outputSignature.itemSize;
  const outputPtr = valueFromExport(exportsObj, "output_ptr", true);
  const outputBytes = readSlice(exportsObj.memory, outputPtr, byteLen, "output_ptr");
  const reusedInput = outputPtr === inputSignature.ptr && byteLen === normalized.bytes.length;

  if (outputSignature.encoding === "utf8") {
    return { value: textDecoder.decode(outputBytes), bytes: outputBytes, encoding: "utf8", contentType: declaredOutputType, reusedInput };
  }
  if (outputSignature.encoding === "bytes") {
    return { value: outputBytes, bytes: outputBytes, encoding: "bytes", contentType: declaredOutputType, reusedInput };
  }
  return { value: new Int32Array(outputBytes.buffer, outputBytes.byteOffset, outputLen), bytes: outputBytes, encoding: "i32", contentType: declaredOutputType, reusedInput };
}
</code></pre>
    </td>
  </tr>

  <tr>
    <td>
      <strong>Public `render`</strong><br>
      This returns a result object with `value`, `encoding`, optional `bytes`, `contentType`, and `reusedInput`.
    </td>
    <td>
<pre><code class="language-js">export function render(component, input) {
  return renderComponent(component, input, "");
}
</code></pre>
    </td>
  </tr>

  <tr>
    <td>
      <strong>Recipe pipeline</strong><br>
      `createRecipe` composes multiple content components in stage order and tracks final MIME/encoding metadata.
    </td>
    <td>
<pre><code class="language-js">export function createRecipe(inputMimeType, components) {
  if (!Array.isArray(components) || components.length === 0) {
    throw Error("createRecipe requires a non-empty array of QIP components");
  }
  for (let i = 0; i < components.length; i += 1) {
    if (!(components[i] instanceof WebAssembly.Module)) {
      throw Error("recipe component at stage " + String(i + 1) + " must be a WebAssembly.Module");
    }
  }

  const recipeInputMimeType = normalizeMimeType(inputMimeType);
  const recipeComponents = components.slice();

  return {
    render(input) {
      // ... run each component, validate MIME compatibility ...
      return finalResultWithRecipeContentType;
    },
  };
}
</code></pre>
    </td>
  </tr>
</table>

## Usage Examples

```html
<script type="module">
  import { createRecipe, render } from '/qip-runner.js';

  const hello = await WebAssembly.compileStreaming(fetch('/components/utf8/hello.wasm'));
  const out = render(hello, 'World').value;
  console.log(out); // Hello, World

  const recipe = createRecipe('text/markdown', [
    await WebAssembly.compileStreaming(fetch('/components/text/markdown/commonmark.0.31.2.wasm')),
    await WebAssembly.compileStreaming(fetch('/components/text/html/html-page-wrap.wasm')),
  ]);
  const result = recipe.render('# qip');
  console.log(result.contentType, result.value.slice(0, 32));
</script>
```

For Node, run this from a package that treats `.js` files as ES modules, or import an `.mjs` copy of the runner.

```js
import { readFile } from 'node:fs/promises';
import { createRecipe, render } from './site/qip-runner.js';

async function main() {
  const markdownComponent = await WebAssembly.compile(await readFile('modules/text/markdown/commonmark.0.31.2.wasm'));
  const pageComponent = await WebAssembly.compile(await readFile('modules/text/html/html-page-wrap.wasm'));

  const htmlFragment = render(markdownComponent, '# Hello').value;
  const recipe = createRecipe('text/markdown', [
    markdownComponent,
    pageComponent,
  ]);
  const page = recipe.render('# qip');
  console.log(htmlFragment, page.value);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
```
