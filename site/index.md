<title>QIP: reproducible rendering</title>

<style>
h1 + a, nav > a  {
    text-align: center;
    display: inline-block;
    margin-bottom: var(--paragraph-leading);
    padding: 0.5lh 1.5em;
    border: 1px solid currentColor;
    border-radius: 10000px;
    text-decoration: none;

    &:hover {
        background: rgba(255, 255, 255, 0.125);
    }
}
</style>

<h1>Components that are<br> <em>Quick</em> to make/maintain/run, <em>Isolated</em> from net/disk/deps, <em>Portable</em> to web/server/native.</h1>

<a href="/docs">Read the docs</a>

QIP components are fast to create with coding agents and fast for users to run.

Users get small `.wasm` modules that load quickly. You get code small enough to review.

Render across browser, server, mobile, native, CLI, and CI. Same input, same output everywhere.

---

## Render any content

Use QIP components for text, images, documents, archives, interactive UI, or any MIME type.

Just like the web is `request -> response`, with QIP components are `input -> output`. But QIP components are not tied to HTML or JavaScript: they work with any content as input or as output.

Your components can render Markdown into HTML, URLs into QR codes, SVG into bitmap images, or WARC archives into deployable websites. Missing something? Prompt a small component and add it to your collection.

```bash
echo "# A Markdown renderer that works _identically_ on any platform" \
| qip run modules/text/markdown/commonmark.0.31.2.wasm
# <h1>A Markdown renderer that works <em>identically</em> on any platform<h1>
```

<nav>
<a href="/markdown-to-html">Try Markdown renderer</a>
</nav>

## Repeatable recipes

You can pipe one component into another step-by-step like a recipe.

Make a recipe you like? It will work identically on mobile, in a browser, in your CI pipeline, or on Windows. You can be confident if it works here, it works there.

For example, one component can render Markdown to HTML, then the next component can highlight TSX code blocks in that HTML.

```bash
printf '%s\n' \
  '# Markdown with code snippet' \
  '' \
  '```tsx' \
  'export function Button({ label }: { label: string }) {' \
  '  return <button>{label}</button>;' \
  '}' \
  '```' \
| qip run \
  modules/text/markdown/commonmark.0.31.2.wasm \
  modules/text/html/highlight-syntax-highlight-tsx.wasm

# <h1>Markdown with code snippet</h1>
# <pre><code class="language-tsx hljs"><span class="hljs-keyword">export</span> <span class="hljs-keyword">function</span> Button({ label }: { label: <span class="hljs-type">string</span> }) {
#   <span class="hljs-keyword">return</span> <span class="hljs-tag">&lt;button&gt;</span>{label}&lt;/button&gt;;
# }
# </code></pre>
```

## Browser rendering

Load the exact same Markdown component in the browser with the `<qip-preview>` custom HTML element:

<pre><code class="language-html">&lt;form aria-label=&quot;Markdown to HTML&quot;&gt;
    &lt;qip-preview&gt;
        &lt;source src=&quot;/components/text/markdown/commonmark.0.31.2.wasm&quot; type=&quot;application/wasm&quot; /&gt;
        &lt;source src=&quot;/components/text/html/highlight-syntax-highlight-tsx.wasm&quot; type=&quot;application/wasm&quot; /&gt;
        &lt;textarea name=&quot;input&quot; rows=&quot;5&quot; placeholder=&quot;Write some Markdown&quot;
        &gt;# A Markdown renderer that works identically cross-platform! Try typing…&lt;/textarea&gt;
        &lt;output name=&quot;output&quot;&gt;&lt;pre&gt;&lt;code&gt;&lt;/code&gt;&lt;/pre&gt;&lt;/output&gt;
        &lt;output name=&quot;output&quot;&gt;&lt;iframe title=&quot;Rendered HTML preview&quot; sandbox&gt;&lt;/iframe&gt;&lt;/output&gt;
    &lt;/qip-preview&gt;
&lt;/form&gt;
</code></pre>

<form aria-label="Markdown to HTML">
    <qip-preview>
        <source src="/components/text/markdown/commonmark.0.31.2.wasm" type="application/wasm" />
        <source src="/components/text/html/highlight-syntax-highlight-tsx.wasm" type="application/wasm" />
        <textarea name="input" rows="5" placeholder="Write some Markdown"
        ># A Markdown renderer that works identically cross-platform! Try typing…</textarea>
        <output name="output" style="min-height: 5lh"><pre><code></code></pre></output>
        <output name="output" style="min-height: 5lh"><iframe title="Rendered HTML preview" sandbox></iframe></output>
    </qip-preview>
</form>

## Interactive components

Interactive QIP Components receive keyboard & pointer events and render out pixels.

<qip-play log>
  <source src="/components/interactive/sudoku.wasm" type="application/wasm" />
</qip-play>

See [`/play`](/play) for more interactive examples, or [`/charts`](/charts) for chart-focused components.

## Pick three: components, AI coding, security

Modern software is tied to an ecosystem that never stops moving. QIP components are self-contained, so you can worry less about supply-chain attacks, outdated libraries, remote-code execution, and environment drift.

QIP is built around a strict contract: same component, same input, same output. It does not read the clock, locale, filesystem, package graph, environment variables, OS, device, chipset, or network — unless you deliberately pass it in. Every input is explicit. This means if it works today, it’ll work tomorrow.

## Utilities that run cross-platform

We believe small functions should not need a massive application environment to run. Write or vibe Zig/C then compile to WebAssembly, and you get a deterministic puzzle piece that runs the same everywhere.

- [Markdown to HTML](/markdown-to-html)
- [JSON prettifier](/json-prettify)
- [CSS minifier](/css-minifier)
- [JPEG location stripper](/jpeg-location-stripper)
- [Image color palette extractor](/image-color-palette)
- [SQLite as a payload](/sqlite)

## Interactive explainers

- [Cache-Control request chains](/cache-control)
- [Flexbox and SwiftUI layout](/layout-systems)
- [Browser security: CORS, CSRF, and XSS](/browser-security)
- [Web mechanics: TLS, DNS, page loading, and cookies](/web-mechanics)
- [Page load waterfall](/page-load-waterfall)

## Portable pipelines of purity

Use QIP Router to render a website from a folder of Markdown files:

```txt
site/
  index.md
  about.md
  docs/index.md
  docs/install.md
  _recipes/text/markdown/10-commonmark.0.31.2.wasm
```

```bash
# Make a HEAD request to the /about page
qip router head ./site /about

# Make a GET request to the /about page
qip router get ./site /about

# Copy a component to syntax highlight bash code
cp syntax-highlight-bash.wasm ./site/_recipes/text/markdown/20-syntax-highlight-bash.wasm

# Run a dev server
qip dev ./site

# Generate an archive of the entire site with view source enabled
qip router warc ./site --view-source
```

Router Recipes allow each MIME type to be processed step-by-step by a series of QIP components. Each source file is transformed by the recipe and becomes served as a webpage route. The same components can be rendered in the browser via custom HTML elements.

If it works here, it works there. If it works today, it'll work tomorrow. Build a recipe of components as a pipeline then carry them to browser, native mobile, server, CLI, CI, or edge with the exact same components and the same rendered output.

QIP makes performance work portable: every pipeline stage is a benchmark boundary. Feed it bytes, measure runtime, optimize the component, and compare output bytes. If the bytes still match and the stage gets faster, ship the same `.wasm` module everywhere that component runs.

Agents get room to optimize without widening the blast radius: they can use Zig or C compilers, explicit memory layouts, and SIMD inside portable Wasm, while the sandbox keeps filesystem, network, secrets, and platform side effects out of the component.

## Software today never stops

Modern software depends on libraries, frameworks, and platforms that are continuously changing.

Docker can package that world, but it preserves the idea that a small rendering function needs a whole application environment around it. QIP is for application output that needs to be portable, predictable, testable, and hard to break.

## Principles

A QIP Component is a self-contained WebAssembly module with strict input and output. One component's output can become the next component's input, so useful pieces can grow into repeatable recipes.

- **Quarantined:** no filesystem, network, secrets, environment, or package graph by default.
- **Reproducible:** same component, same input/uniforms/events, same output.
- **Portable:** the same `.wasm` runs in the browser, server, CLI, native apps, CI, mobile, and edge.
- **Composable:** components pipe together like Unix tools.
- **Agent-friendly:** small modules are easier to generate, review, benchmark, optimize, and replace.

Make a recipe you like? You can be confident it will work identically on mobile, in a browser, in your CI pipeline, on Windows, or whatever comes next. Because components are self-contained with no required dependencies, they can keep working for years.

Your users get small `.wasm` modules that load fast, and you get small amounts of code that are easy to review. You can run AI-generated code without handing it the keys to your machine.

A small function that transforms data should not need a whole application environment around it. Put the small, valuable transformations in QIP so they become portable, predictable, hard to break, and easy to test.

Components, AI coding, security: you can pick all three.

## FAQ

### How is QIP different from Flutter?

Flutter is a way to build an app. QIP is a way to package a small piece of deterministic work so it can run inside many apps.

Flutter helps you write one app for many platforms. QIP helps you write one component for many apps.

### How is QIP different from WASI?

WASI is useful when a WebAssembly program needs operating-system-like capabilities. QIP is narrower. A QIP component gets bytes from the host, transforms them, and returns bytes. It does not get filesystem, network, environment, clock, or secrets by default.

That smaller contract is the point. It makes components easier to run in browsers, mobile apps, servers, CI, and native hosts without giving them an operating-system-shaped API.

## Learn more

- [Why QIP](/docs)
- [Adopting QIP in existing apps](/docs/adopting-qip)
- [How QIP Works](/docs/how-it-works)
- [QIP Component Contract](/docs/component-contract)
- [Router Specification](/docs/router)
