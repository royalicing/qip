# Browser Preview Element

`<qip-preview>` runs QIP Content components in the browser and writes the result back into ordinary HTML.

Use it when a page needs a live preview of the same component you also run from the CLI, router, server, or native host. The element is intentionally small: the page provides input controls, Wasm sources, and output views; the runtime wires them together.

## Contract

Each preview needs at least one QIP component, one input, and one output:

```html
<qip-preview>
  <source src="/components/text/markdown/commonmark.0.31.2.wasm" type="application/wasm" />
  <textarea name="input"># Hello</textarea>
  <output name="output"><pre><code></code></pre></output>
</qip-preview>
```

The runtime reads from the first child with `name="input"`. It runs each `<source type="application/wasm">` as a pipeline stage in document order. It then writes the same output bytes into every `<output name="output">`.

Multiple outputs are multiple views of one result. They are not multiple return values from the component.

## Output Views

`<output name="output">` is the semantic binding. Its child element declares how the page wants to show the bytes.

```html
<output name="output"><pre><code></code></pre></output>
<output name="output"><iframe title="Rendered HTML preview" sandbox></iframe></output>
<output name="output"><img alt="Generated image preview" /></output>
```

For UTF-8 output, the runtime looks inside each output for `pre > code` or `iframe`.

- `pre > code` receives the decoded output as `textContent`.
- `iframe` receives the decoded output as `srcdoc`. For `text/html` output, the runtime appends a low-specificity default sans-serif body style. Use `sandbox` for rendered HTML previews.
- Without either child, decoded text is written directly to the `<output>`.

For `image/*` output, an `img` child receives an object URL for the rendered image. This is the right view for SVG, PNG, JPEG, GIF, BMP, ICO, or WebP output. If there is no `img`, SVG and other UTF-8 image formats can still be shown as text with `pre > code`.

Binary output without a matching view falls back to a short hex preview in the `<output>`.

## Binary Input

Text inputs cover UTF-8 transforms; binary payloads have two HTML-native forms.

A `<source name="input">` declares the input. The runtime fetches it, and its `type` attribute becomes the pipeline's initial content type:

```html
<qip-preview>
  <source name="input" src="/data/countries.sqlite" type="application/vnd.sqlite3" />
  <source src="/components/application/vnd.sqlite3/sqlite-schema.wasm" type="application/wasm" />
  <output name="output"><pre><code></code></pre></output>
</qip-preview>
```

Every other `<source>` is a pipeline stage. The naming follows the element's existing `name="output"` and `name="uniform-*"` wiring, and the input can itself be a wasm module — for example, feeding one into `wasm-safety-check.wasm`:

```html
<qip-preview>
  <source name="input" src="/components/utf8/luhn.wasm" type="application/wasm" />
  <source src="/components/application/wasm/wasm-safety-check.wasm" type="application/wasm" />
  <output name="output"><pre><code></code></pre></output>
</qip-preview>
```

With an input `<source>` present, a separate input control is optional. `data:` URLs work for inlining small payloads.

An `<input type="file" name="input">` supplies the chosen file's bytes and content type instead. With no file selected it falls back to the input `<source>`, so a page can ship default data that visitors override with their own file:

```html
<qip-preview>
  <source name="input" src="/data/countries.sqlite" type="application/vnd.sqlite3" />
  <source src="/components/application/vnd.sqlite3/sqlite-schema.wasm" type="application/wasm" />
  <input type="file" name="input" accept=".sqlite,application/vnd.sqlite3" />
  <output name="output"><pre><code></code></pre></output>
</qip-preview>
```

Precedence: a chosen file wins, then the input `<source>`, then the input element's text.

## Module Policy

Use module policy attributes when a page previews code you want to keep inside a tighter resource boundary:

```html
<qip-preview max-memory="1048576" fixed-memory>
  <source src="/components/text/markdown/commonmark.0.31.2.wasm" type="application/wasm" />
  <textarea name="input"># Hello</textarea>
  <output name="output"><pre><code></code></pre></output>
</qip-preview>
```

- `max-memory="<bytes>"` rejects a module whose declared memory minimum or maximum exceeds the cap. If a module has memory but no declared maximum, it is rejected.
- `fixed-memory` rejects a module that can grow linear memory while it runs.

These checks run after the module bytes are fetched and before `WebAssembly.compile`.

## Pipeline Example

This preview renders Markdown, highlights TSX code blocks in the HTML, then shows the same HTML as source and as a rendered preview.

```html
<form aria-label="Markdown to HTML">
  <qip-preview>
    <source src="/components/text/markdown/commonmark.0.31.2.wasm" type="application/wasm" />
    <source src="/components/text/html/highlight-syntax-highlight-tsx.wasm" type="application/wasm" />

    <textarea name="input" rows="5"># Button

~~~tsx
export function Button({ label }: { label: string }) {
  return <button>{label}</button>;
}
~~~
    </textarea>

    <output name="output"><pre><code></code></pre></output>
    <output name="output"><iframe title="Rendered HTML preview" sandbox></iframe></output>
  </qip-preview>
</form>
```

Keep custom layout, labels, and surrounding controls in normal HTML. Keep QIP responsible for the byte transform.
