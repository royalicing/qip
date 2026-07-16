<title>Markdown to HTML</title>

# Markdown to HTML

Render Markdown in the browser with either the GFM or CommonMark QIP component.

<style>
.tool-grid {
  display: grid;
  gap: 1rem;
}
@media (min-width: 900px) {
  .tool-grid { grid-template-columns: 1fr 1fr; }
}
.tool-panel {
  display: grid;
  gap: 0.5rem;
}
.tool-panel textarea {
  box-sizing: border-box;
  min-height: 22rem;
  width: 100%;
  resize: vertical;
  font: inherit;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
.source-output {
  display: block;
  min-height: 22rem;
  padding: 0;
  overflow: auto;
}
.source-output pre {
  min-height: 22rem;
  margin: 0;
  padding: 0.75rem;
}
.rendered-preview {
  display: block;
  min-height: 22rem;
  padding: 0;
  border: 1px solid color-mix(in srgb, currentColor 20%, transparent);
}
.rendered-preview iframe {
  display: block;
  width: 100%;
  min-height: 22rem;
  border: 0;
  background: white;
}
</style>

## GitHub Flavored Markdown

This renderer combines CommonMark 0.31.2 with GFM tables, task lists,
strikethrough, extended autolinks, and tag filtering in
<qip-content-size src="/components/text/markdown/gfm-commonmark.0.31.2.wasm"></qip-content-size>
of Wasm.

<form aria-label="GitHub Flavored Markdown to HTML">
  <qip-edit>
    <source src="/components/text/markdown/gfm-commonmark.0.31.2.wasm" type="application/wasm" />
    <div class="tool-grid">
      <label class="tool-panel">
        <strong>GFM input</strong>
        <textarea name="input" spellcheck="false"># Project status&#10;&#10;| Feature | Status |&#10;| --- | --- |&#10;| Tables | Ready |&#10;| Task lists | In progress |&#10;&#10;- [x] Render CommonMark 0.31.2&#10;- [x] Add ~~plain Markdown~~ GFM&#10;- [ ] Ship it&#10;&#10;Visit https://github.github.com/gfm/</textarea>
      </label>
      <section class="tool-panel" aria-labelledby="gfm-html-output-heading">
        <strong id="gfm-html-output-heading">HTML output</strong>
        <output name="output" class="source-output"><pre><code></code></pre></output>
      </section>
    </div>
    <section class="tool-panel" aria-labelledby="gfm-preview-heading">
      <h3 id="gfm-preview-heading">Preview</h3>
      <output name="output" class="rendered-preview">
        <iframe title="Rendered GFM preview" sandbox></iframe>
      </output>
    </section>
  </qip-edit>
</form>

## CommonMark 0.31.2

Use this renderer when the portable CommonMark syntax is the intended contract;
it implements CommonMark 0.31.2 in
<qip-content-size src="/components/text/markdown/commonmark.0.31.2.wasm"></qip-content-size>
of Wasm.

<form aria-label="CommonMark to HTML">
  <qip-edit>
    <source src="/components/text/markdown/commonmark.0.31.2.wasm" type="application/wasm" />
    <div class="tool-grid">
      <label class="tool-panel">
        <strong>CommonMark input</strong>
        <textarea name="input" spellcheck="false"># Hello from QIP&#10;&#10;This CommonMark is rendered by a browser-loaded WebAssembly component.&#10;&#10;- **No atomics.** Atomic instructions imply shared-memory coordination, which is&#10;  outside the normal QIP component model.</textarea>
      </label>
      <section class="tool-panel" aria-labelledby="commonmark-html-output-heading">
        <strong id="commonmark-html-output-heading">HTML output</strong>
        <output name="output" class="source-output"><pre><code></code></pre></output>
      </section>
    </div>
    <section class="tool-panel" aria-labelledby="commonmark-preview-heading">
      <h3 id="commonmark-preview-heading">Preview</h3>
      <output name="output" class="rendered-preview">
        <iframe title="Rendered CommonMark preview" sandbox></iframe>
      </output>
    </section>
  </qip-edit>
</form>

## CLI equivalent

```bash
qip run modules/text/markdown/gfm-commonmark.0.31.2.wasm < page.md > page.html
qip run modules/text/markdown/commonmark.0.31.2.wasm < page.md > page.html
```
