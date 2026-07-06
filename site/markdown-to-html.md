<title>Markdown to HTML</title>

# Markdown to HTML

Render Markdown locally with the same QIP component used by the router.

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
.rendered-preview {
  min-height: 22rem;
  padding: 0.75rem;
  border: 1px solid color-mix(in srgb, currentColor 20%, transparent);
}
.tool-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  align-items: center;
}
.tool-status {
  min-height: 1.5rem;
}
</style>

<div class="tool-grid">
  <label class="tool-panel">
    <strong>Markdown</strong>
    <textarea id="markdown-input" spellcheck="false"></textarea>
  </label>
  <section class="tool-panel" aria-labelledby="html-output-heading">
    <strong id="html-output-heading">HTML</strong>
    <textarea id="html-output" spellcheck="false" readonly></textarea>
  </section>
</div>

<p class="tool-actions">
  <button id="markdown-render" type="button">Render</button>
  <button id="markdown-copy" type="button">Copy HTML</button>
  <span id="markdown-status" class="tool-status" role="status"></span>
</p>

<section aria-labelledby="preview-heading">
  <h2 id="preview-heading">Preview</h2>
  <div id="markdown-preview" class="rendered-preview"></div>
</section>

<script type="module">
import { contentComponent, contentContract } from "/qip-runner.js";

const input = document.getElementById("markdown-input");
const output = document.getElementById("html-output");
const preview = document.getElementById("markdown-preview");
const renderButton = document.getElementById("markdown-render");
const copyButton = document.getElementById("markdown-copy");
const status = document.getElementById("markdown-status");
const markdown = contentContract({ encoding: "utf-8", contentType: "text/markdown" });
const html = contentContract({ encoding: "utf-8", contentType: "text/html" });
const componentModule = await WebAssembly.compileStreaming(fetch("/components/text/markdown/commonmark.0.31.2.wasm"));
const renderMarkdownComponent = contentComponent(markdown, componentModule, html);
input.value = "# Hello from QIP\n\nThis Markdown is rendered by a browser-loaded WebAssembly component.";

function renderMarkdown() {
  try {
    const result = renderMarkdownComponent(input.value);
    output.value = result;
    preview.innerHTML = result;
    status.textContent = "Rendered.";
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : String(error);
  }
}

renderButton.addEventListener("click", renderMarkdown);
copyButton.addEventListener("click", async () => {
  await navigator.clipboard.writeText(output.value);
  status.textContent = "Copied.";
});
input.addEventListener("input", renderMarkdown);
renderMarkdown();
</script>

## CLI equivalent

```bash
qip run modules/text/markdown/commonmark.0.31.2.wasm < page.md > page.html
```
