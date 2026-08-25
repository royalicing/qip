# Running QIP In React

React does not need a QIP-specific wrapper. Once the `.wasm` module has loaded, rendering is synchronous: encode the input, write it into component memory, call QIP’s `render`, and decode the output.

The examples below run the same `gfm-commonmark.0.31.2.wasm` component in a browser Client Component and a Next.js Server Component.

A QIP component is a [WebAssembly Core module](https://webassembly.github.io/spec/core/), not a [WebAssembly Component Model](https://component-model.bytecodealliance.org/) component. These examples use the Core WebAssembly APIs with zero WASI imports for improved security and determinism.

## Client Or Server

| Aspect | Client Component | Server Component |
| --- | --- | --- |
| Wasm location | Inlined or loaded by browser | Read from the server’s local disk |
| Compute cost | Paid by each user's device | Paid by the server or build process |
| Initial HTML | Rendered after the client module loads | Can be included in the first response |
| Good fit | Editors and live previews | CMS or static content |

Use a Client Component when the user is editing Markdown. Use a Server Component when the Markdown already lives on the server or loaded from a CMS and the browser only needs the resulting HTML.

## Client Component

This example uses the direct import described in [Running In JavaScript](/docs/running-in-javascript), so loading happens in the JavaScript module graph before React calls the component. The React render itself is synchronous and needs no state, Effect, or loading lifecycle.

```jsx
"use client";

import {
  memory,
  input_ptr,
  input_utf8_cap,
  render,
} from "/gfm-commonmark.0.31.2.wasm";

const encoder = new TextEncoder(), decoder = new TextDecoder();

function decodeRenderResult(value) {
  const bits = BigInt.asUintN(64, value);
  if ((bits >> 63n) !== 0n) throw new Error("component rejected input");
  return [Number((bits >> 32n) & 0x7fff_ffffn), Number(bits & 0xffff_ffffn)];
}

function renderMarkdown(source) {
  const input = encoder.encode(source);
  if (input.length > input_utf8_cap()) {
    throw new RangeError("Markdown input is too large");
  }

  new Uint8Array(memory.buffer, input_ptr(), input.length).set(input);
  const [outputPtr, outputSize] = decodeRenderResult(render(input.length));
  return decoder.decode(
    new Uint8Array(memory.buffer, outputPtr, outputSize),
  );
}

export function MarkdownPreviewClient({ source }) {
  const html = renderMarkdown(source);
  return <div dangerouslySetInnerHTML={{ __html: html }} />;
}
```

Direct `.wasm` imports depend on the browser, runtime, and bundler. When that integration is unavailable, load the module before mounting the React application and keep the component code synchronous:

```js
const markdownRenderer = await WebAssembly.instantiateStreaming(
  fetch("/gfm-commonmark.0.31.2.wasm"),
);

const {
  memory,
  input_ptr,
  input_utf8_cap,
  render,
} = markdownRenderer.instance.exports;
```

After that loading step, use the same `renderMarkdown` and `MarkdownPreviewClient` functions. `instantiateStreaming` expects the server to return the file with `Content-Type: application/wasm`.

## Server Component

[Server Components](https://react.dev/reference/rsc/server-components) are the default in the Next.js App Router.

Put the downloaded module on the server:

```text
public/
└── qip-components/
    └── gfm-commonmark.0.31.2.wasm
```

Then create `app/markdown-preview-server.jsx`:

```jsx
import "server-only";

import { readFileSync } from "node:fs";
import path from "node:path";

const wasmPath = path.join(
  process.cwd(),
  "public",
  "qip-components",
  "gfm-commonmark.0.31.2.wasm",
);
const wasmModule = new WebAssembly.Module(readFileSync(wasmPath));
const { exports } = new WebAssembly.Instance(wasmModule, {});
const encoder = new TextEncoder(), decoder = new TextDecoder();

function renderMarkdown(source) {
  const {
    memory,
    input_ptr,
    input_utf8_cap,
    render,
  } = exports;

  const input = encoder.encode(source);
  if (input.length > input_utf8_cap()) {
    throw new RangeError("Markdown input is too large");
  }

  new Uint8Array(memory.buffer, input_ptr(), input.length).set(input);
  const [outputPtr, outputSize] = decodeRenderResult(render(input.length));
  return decoder.decode(
    new Uint8Array(memory.buffer, outputPtr, outputSize),
  );
}

export function MarkdownPreviewServer({ source }) {
  const html = renderMarkdown(source);
  return <div dangerouslySetInnerHTML={{ __html: html }} />;
}
```

Use it from a page running in the Node.js runtime:

```jsx
import { MarkdownPreviewServer } from "./markdown-preview-server";

export const runtime = "nodejs";

export default function Page() {
  return <MarkdownPreviewServer source="# Rendered on the server" />;
}
```

## Errors and Traps

If `render` traps, the WebAssembly call throws. Let the nearest React error
boundary or server error handler deal with it. Do not read the output buffer
after a trapped call; it may contain stale or partial bytes. Discard that
instance and instantiate the module again before another render.

## Rendering Untrusted Markdown

QIP isolation limits what the Wasm component can access. It does not make the returned HTML safe to insert into a page. GitHub Flavored Markdown tag filtering is not a complete HTML sanitizer.

If users can supply Markdown, sanitize or validate the HTML before passing it to `dangerouslySetInnerHTML`. Keep that policy in the app so it can account for the elements, attributes, and URL schemes your product permits.
