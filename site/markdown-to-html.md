<title>Markdown to HTML</title>

# Markdown to HTML

Render Markdown with the same QIP component used by this website.

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

<form aria-label="Markdown to HTML">
  <qip-edit>
    <source src="/components/text/markdown/commonmark.0.31.2.wasm" type="application/wasm" />
    <div class="tool-grid">
      <label class="tool-panel">
        <strong>Markdown input</strong>
        <textarea name="input" spellcheck="false"># Hello from QIP&#10;&#10;This Markdown is rendered by a browser-loaded WebAssembly component.</textarea>
      </label>
      <section class="tool-panel" aria-labelledby="html-output-heading">
        <strong id="html-output-heading">HTML output</strong>
        <output name="output" class="source-output"><pre><code></code></pre></output>
      </section>
    </div>
    <section class="tool-panel" aria-labelledby="preview-heading">
      <h2 id="preview-heading">Preview</h2>
      <output name="output" class="rendered-preview">
        <iframe title="Rendered HTML preview" sandbox></iframe>
      </output>
    </section>
  </qip-edit>
</form>

## CLI equivalent

```bash
qip run modules/text/markdown/commonmark.0.31.2.wasm < page.md > page.html
```
