<title>Unicode transforms</title>

# Unicode transforms

Case conversion pinned to **Unicode 17.0.0**, running locally in your browser as QIP components. The version is in the component's name — `unicode-17-lowercase.wasm` — so the same bytes produce the same result in this page, in your CI, on your server, and in five years. No locale lottery: your OS, browser ICU revision, and `LC_ALL` are never consulted.

<style>
.tool-grid {
  display: grid;
  gap: 1rem;
}
@media (min-width: 860px) {
  .tool-grid { grid-template-columns: 1fr 1fr 1fr; }
}
.tool-panel {
  display: grid;
  gap: 0.5rem;
  align-content: start;
}
.tool-panel textarea {
  box-sizing: border-box;
  min-height: 10rem;
  width: 100%;
  resize: vertical;
  font: inherit;
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
    <strong>Text</strong>
    <textarea id="case-input" spellcheck="false">Straße İstanbul ΘΕΣΣΑΛΟΝΊΚΗ — ΣΟΦΟΣ ΟΔΥΣΣΕΥΣ! ﬁne ǅungla</textarea>
  </label>
  <label class="tool-panel">
    <strong>Lowercase (unicode-17-lowercase.wasm)</strong>
    <textarea id="case-lower" spellcheck="false" readonly></textarea>
  </label>
  <label class="tool-panel">
    <strong>Uppercase (unicode-17-uppercase.wasm)</strong>
    <textarea id="case-upper" spellcheck="false" readonly></textarea>
  </label>
</div>

<p class="tool-actions">
  <button type="button" data-sample="ΘΕΣΣΑΛΟΝΊΚΗ ΣΟΦΟΣ σοφός">Greek final sigma</button>
  <button type="button" data-sample="straße GROẞ ﬁ ﬂ ﬃ ŉ">German &amp; ligatures</button>
  <button type="button" data-sample="İstanbul ı I i̇">Dotted &amp; dotless i</button>
  <button type="button" data-sample="𐐐𐐨 𐵰𐵐 ꭰꮣ ᏣᎳᎩ">Deseret, Garay, Cherokee</button>
  <span id="case-status" class="tool-status" role="status"></span>
</p>

Things to try: `ΣΟΦΟΣ` lowercases with a final sigma (`σοφος` ends in ς, not σ — the Final_Sigma context rule). `straße` uppercases to `STRASSE` — a full case mapping, one that Go's `strings.ToUpper` gets wrong because it only applies simple per-character mappings. `İ` lowercases to `i̇` (i + combining dot, the non-Turkish rule). The Garay sample needs Unicode 16+ data — older platforms silently leave it unchanged.

<script type="module">
import { contentComponent, contentContract } from "/qip-runner.js";

const input = document.getElementById("case-input");
const lowerOutput = document.getElementById("case-lower");
const upperOutput = document.getElementById("case-upper");
const status = document.getElementById("case-status");
const text = contentContract({ encoding: "utf-8" });
const [lowerModule, upperModule] = await Promise.all([
  WebAssembly.compileStreaming(fetch("/components/utf8/unicode-17-lowercase.wasm")),
  WebAssembly.compileStreaming(fetch("/components/utf8/unicode-17-uppercase.wasm")),
]);
const toLower = contentComponent(text, lowerModule, text);
const toUpper = contentComponent(text, upperModule, text);

function transform() {
  try {
    lowerOutput.value = toLower(input.value);
    upperOutput.value = toUpper(input.value);
    status.textContent = "";
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : String(error);
  }
}

for (const button of document.querySelectorAll("[data-sample]")) {
  button.addEventListener("click", () => {
    input.value = button.dataset.sample;
    transform();
  });
}
input.addEventListener("input", transform);
transform();
</script>

## Why pin the Unicode version?

Every platform carries its own Unicode data at its own revision: your browser's ICU, your server's distro `libicu`, your database's collation tables, your game engine's frozen copy. They disagree — about digit shapes, about calendar days, about whether a script's characters have case at all. These components end that by carrying their own data: **the identifier states its data revision** (the same move as MySQL's `utf8mb4_0900_ai_ci` collation naming), and a future Unicode 18 build will be a visibly different artifact, `unicode-18-lowercase.wasm`, so upgrading is an explicit, diffable act instead of silent drift.

Both components implement Unicode Default Case Conversion for the root locale — byte-identical behavior for English, French, German, Spanish, and every language without a casing tailoring. Only Turkish/Azerbaijani (dotted/dotless i) and Lithuanian differ, and those would ship as separate components (`unicode-17-lowercase-turkic.wasm`).

## Conformance you can run yourself

The uppercase contract ships as an executable spec: a *Content Compliance component* (`compliance/unicode-17-uppercase.comply.wasm`) that declares 100 deterministic cases — curated inputs, seeded fuzz cases, and algebraic properties like idempotence — through a five-function host bridge. Any implementation in any language can be tested against it; a failing case is reproducible from just *(component hash, seed, ordinal)*.

The repo includes two self-contained examples: Node.js's `toUpperCase` (ICU 78, Unicode 17) **passes all 100 cases**; Go's stdlib `unicode.ToUpper` **fails 38** — simple mappings only, Unicode 15 tables — with each divergence pinpointed by ordinal. See `examples/comply-uppercase-node/` and `examples/comply-uppercase-go/`.

## CLI equivalent

```bash
echo "ΘΕΣΣΑΛΟΝΊΚΗ ΣΟΦΟΣ" | qip run modules/utf8/unicode-17-lowercase.wasm
# θεσσαλονίκη σοφος

echo "straße" | qip run modules/utf8/unicode-17-uppercase.wasm
# STRASSE
```

## Run it in Node.js

No SDK, no dependencies — the QIP contract is small enough to drive with the
platform's own WebAssembly API:

```js
import { readFile } from "node:fs/promises";

const wasm = await readFile("modules/utf8/unicode-17-lowercase.wasm");
const { instance } = await WebAssembly.instantiate(wasm);
const { memory, input_ptr, input_utf8_cap, output_ptr, render } = instance.exports;

function lowercase(text) {
  const bytes = new TextEncoder().encode(text);
  if (bytes.length > input_utf8_cap()) throw new Error("input too large");
  new Uint8Array(memory.buffer, input_ptr(), bytes.length).set(bytes);
  const size = render(bytes.length);
  return new TextDecoder().decode(new Uint8Array(memory.buffer, output_ptr(), size));
}

console.log(lowercase("ΘΕΣΣΑΛΟΝΊΚΗ ΣΟΦΟΣ")); // θεσσαλονίκη σοφος
```

The instance is reusable: call `lowercase()` as many times as you like — same
component, same bytes, no matter which Node (or ICU) version is underneath.

## Run it in the browser

The same contract, driven the same way — only the loading differs:

```html
<script type="module">
const { instance } = await WebAssembly.instantiateStreaming(
  fetch("/components/utf8/unicode-17-lowercase.wasm"),
);
const { memory, input_ptr, input_utf8_cap, output_ptr, render } = instance.exports;

function lowercase(text) {
  const bytes = new TextEncoder().encode(text);
  if (bytes.length > input_utf8_cap()) throw new Error("input too large");
  new Uint8Array(memory.buffer, input_ptr(), bytes.length).set(bytes);
  const size = render(bytes.length);
  return new TextDecoder().decode(new Uint8Array(memory.buffer, output_ptr(), size));
}

console.log(lowercase("İstanbul")); // i̇stanbul
</script>
```

This page itself uses the small helper from [`/qip-runner.js`](/qip-runner.js),
which wraps the same steps:

```js
import { contentComponent, contentContract } from "/qip-runner.js";

const text = contentContract({ encoding: "utf-8" });
const module = await WebAssembly.compileStreaming(
  fetch("/components/utf8/unicode-17-lowercase.wasm"),
);
const lowercase = contentComponent(text, module, text);

lowercase("ΘΕΣΣΑΛΟΝΊΚΗ ΣΟΦΟΣ"); // "θεσσαλονίκη σοφος"
```

You can also [import a component directly as a WebAssembly ES module](/docs/esm-integration).

More Unicode and locale-aware components are planned — normalization, per-locale date/number/currency formatting with pinned CLDR data — following the same rule: the data revision lives in the artifact, not in the environment.
