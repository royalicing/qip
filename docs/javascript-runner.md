# JavaScript Runner

The JavaScript runner treats QIP work as checked content components: declare what goes in, declare what comes out, and then call the result like an ordinary function.

- Raw source: [`/qip-runner.js`](/qip-runner.js)
- API:
  - `contentTypeUTF8(optionalMIMEType)`
  - `contentTypeBytes(optionalMIMEType)`
  - `contentComponent(input, implementation, output)`
  - `contentRecipe(input, components, output)`

## Contracts

Use `contentTypeUTF8` or `contentTypeBytes` to create a frozen content boundary. Pass a MIME type when the component requires a more specific contract.

```js
import { contentTypeBytes, contentTypeUTF8 } from "/qip-runner.js";

const text = contentTypeUTF8();
const markdown = contentTypeUTF8("text/markdown");
const html = contentTypeUTF8("text/html");
const bmp = contentTypeBytes("image/bmp");
```

Encoding is a hard requirement. Content type is a refinement: two contracts are compatible when the encodings match and either content type is unspecified or both specify the same type.

Content types are not normalized. When present, they must already be lowercase media types without parameters or whitespace, such as `text/html` or `image/bmp`. Hosts compare them exactly.

## Components

`contentComponent(input, implementation, output)` returns a callable component with `.input` and `.output` metadata.

The implementation can be a `WebAssembly.Module`:

```js
const markdownToHtml = contentComponent(markdown, markdownModule, html);
const fragment = markdownToHtml("# Hello");
```

For Wasm modules, the runner validates the declared QIP exports up front:

- `memory`
- `render`
- `input_ptr`
- `input_utf8_cap` or `input_bytes_cap`, matching the input contract
- `output_ptr`
- `output_utf8_cap` or `output_bytes_cap`, matching the output contract

If the module declares content-type exports, they must match the supplied contracts.

The implementation can also be a JavaScript function:

```js
const trim = contentComponent(text, (value) => value.trim(), text);
```

JavaScript functions are checked at the call boundary: UTF-8 contracts receive and return strings, byte contracts receive and return `Uint8Array`.

## Recipes

`contentRecipe(input, components, output)` composes content components and returns another callable component.

```js
const page = contentRecipe(markdown, [markdownToHtml, htmlPageWrap], html);
const result = page("# qip");
```

Recipe creation checks the whole chain:

- recipe input matches the first component input
- each component output matches the next component input
- the last component output matches recipe output

Recipes are components, so they can be nested:

```js
const cleanMarkdown = contentRecipe(markdown, [trim], markdown);
const cleanPage = contentRecipe(markdown, [cleanMarkdown, markdownToHtml, htmlPageWrap], html);
```

An empty recipe is allowed only when input and output are compatible:

```js
const identityText = contentRecipe(text, [], text);
```

## Browser Example

```html
<script type="module">
  import {
    contentComponent,
    contentRecipe,
    contentTypeUTF8,
  } from "/qip-runner.js";

  const markdown = contentTypeUTF8("text/markdown");
  const html = contentTypeUTF8("text/html");

  const markdownModule = await WebAssembly.compileStreaming(
    fetch("/components/text/markdown/commonmark.0.31.2.wasm"),
  );
  const pageModule = await WebAssembly.compileStreaming(
    fetch("/components/text/html/html-page-wrap.wasm"),
  );

  const markdownToHtml = contentComponent(markdown, markdownModule, html);
  const htmlPageWrap = contentComponent(html, pageModule, html);
  const renderPage = contentRecipe(markdown, [markdownToHtml, htmlPageWrap], html);

  console.log(renderPage("# qip"));
</script>
```

For Node, run from a package that treats `.js` files as ES modules, or import an `.mjs` copy of the runner.

```js
import { readFile } from "node:fs/promises";
import {
  contentComponent,
  contentRecipe,
  contentTypeUTF8,
} from "./site/qip-runner.js";

const markdown = contentTypeUTF8("text/markdown");
const html = contentTypeUTF8("text/html");

const markdownModule = await WebAssembly.compile(
  await readFile("modules/text/markdown/commonmark.0.31.2.wasm"),
);
const pageModule = await WebAssembly.compile(
  await readFile("modules/text/html/html-page-wrap.wasm"),
);

const markdownToHtml = contentComponent(markdown, markdownModule, html);
const htmlPageWrap = contentComponent(html, pageModule, html);
const renderPage = contentRecipe(markdown, [markdownToHtml, htmlPageWrap], html);

console.log(renderPage("# qip"));
```
