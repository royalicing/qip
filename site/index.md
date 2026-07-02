<title>QIP: secure cross-platform components</title>

<style>
.hero-left {
    padding-bottom: 1lh;

    a {
        text-align: center;
        display: inline-block;
        padding: 0.5lh 1.5em;
        border: 1px solid currentColor;
        border-radius: 10000px;
        text-decoration: none;

        &:hover {
            background: rgba(255, 255, 255, 0.125);
        }
    }
}

@media (min-width: 940px) {
    .hero-left {
        max-width: 48%;
        float: left;
    }
    .hero-right {
        max-width: 48%;
        float: right;
    }
    hr { clear: both }
}
</style>

<section class="hero-left">

<h1>Easy to write, fast to run, hard to break.</h1>

<p>QIP components are Quick, Isolated & Portable.</p>

<a href="/docs">Read the docs</a>

</section>

<section class="hero-right">

## QIP components render identically across browser, server, cli, and native.

They are fast for you to create with coding agents and fast for users to run. You can add them to existing applications or use QIP Router to create websites just like this one.

WebAssembly provides strong isolation with no filesystem, network, or secrets access. Strict component contracts bring determinism that means everything renders predictably alike everywhere.

It’s secure for users, cross-platform for developers, and fast for everyone.

</section>

---

## Render any content

```bash
du -h modules/text/markdown/commonmark.0.31.2.wasm
# 48K    modules/text/markdown/commonmark.0.31.2.wasm

echo "# A Markdown renderer that works identically cross-platform!" \
| qip run modules/text/markdown/commonmark.0.31.2.wasm
# <h1>A Markdown renderer that works identically cross-platform!<h1>
```

QIP components can convert text, images, or any MIME type. A pipeline can turn Markdown into HTML, URLs into QR codes, SVG into bitmap images, or WARC archives into deployable websites. Missing something? Just prompt it and add it to your component collection.

## Browser rendering

Load the exact same Markdown component in the browser with the `<qip-preview>` custom HTML element:

<pre><code class="language-html">&lt;form aria-label=&quot;Markdown to HTML&quot;&gt;
    &lt;qip-preview&gt;
        &lt;source src=&quot;/components/text/markdown/commonmark.0.31.2.wasm&quot; type=&quot;application/wasm&quot; /&gt;
        &lt;textarea name=&quot;input&quot; rows=&quot;3&quot; placeholder=&quot;Write some Markdown&quot;
        &gt;# A Markdown renderer that works identically cross-platform! Try typing…&lt;/textarea&gt;
        &lt;output name=&quot;output&quot;&gt;&lt;/output&gt;
    &lt;/qip-preview&gt;
&lt;/form&gt;
</code></pre>

<form aria-label="Markdown to HTML">
    <qip-preview>
        <source src="/components/text/markdown/commonmark.0.31.2.wasm" type="application/wasm" />
        <textarea name="input" rows="3" placeholder="Write some Markdown"
        ># A Markdown renderer that works identically cross-platform! Try typing…</textarea>
        <output name="output"></output>
    </qip-preview>
</form>

## Interactive components

Interactive QIP Components receive keyboard & pointer events and render out pixels.

<qip-play log>
  <source src="/components/interactive/sudoku.wasm" type="application/wasm" />
</qip-play>

See [`/play`](/play) for more interactive examples, or [`/charts`](/charts) for chart-focused components.

## Private utilities

These pages run QIP components in your browser:

- [Markdown to HTML](/markdown-to-html)
- [JSON prettifier](/json-prettify)
- [CSS minifier](/css-minifier)
- [JPEG location stripper](/jpeg-location-stripper)
- [Image color palette extractor](/image-color-palette)

## Interactive explainers

- [Cache-Control request chains](/cache-control)
- [Flexbox and SwiftUI layout](/layout-systems)
- [Browser security: CORS, CSRF, and XSS](/browser-security)
- [Web mechanics: TLS, DNS, page loading, and cookies](/web-mechanics)
- [Page load waterfall](/page-load-waterfall)

## Pluggable web router

QIP can also take Markdown files and render a website:

```txt
site/
  index.md
  docs/router.md
  _recipes/text/markdown/10-markdown-basic.wasm
  _components/interactive/sudoku.wasm
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

Recipes allow each MIME type to be processed by a series of QIP component steps. Each source file is transformed by the recipe and become a webpage route. The same components can be rendered in the browser via custom HTML elements.

## Software today never stops

Modern software depends on libraries, frameworks, and platforms that are continuously changing.

Docker can package that world, but it requires lots of moving pieces that require constant patches. We believe a small function to transform some data should not need a whole application environment to run.

## Components that are small, isolated, and deterministic across platforms

**QIP component** are self-contained WebAssembly modules with strict input and output. The output of one then becomes the input of the next, allowing you to compose them together into deterministic pipelines. These will work identically across platforms and will not bitrot due to outdated dependencies.

- **Quarantined:** components run in a sandbox isolated from the host (no filesystem, network, or environment access).
- **Immutable:** components are self-contained with no dependencies required, so once you have a working component it stays working.
- **Portable:** components run identically across platforms using Core WebAssembly.
- **Agent-friendly:** components are small, making them easy to generate, review, benchmark, and replace.
- **Deterministic:** the same component and input are guaranteed to produce the same output no matter where or when you run it.
- **Composable:** components pipe together like Unix tools and run everywhere like React.

All these properties combined give you predictability. Agent-friendly combined with quarantined means you can experiment with the latest AI tools or programming language without concerns of leaking data. Cross-platform combined with determinism gives you confidence it’ll work the same everywhere, making testing faster. Composable together with immutable means a sophisticated pipeline of components you’ve created will just continue working the same as it did last week.

You break things into small pieces amenable to agentic coding, and those pieces run securely protecting you and your users, and work the same over time and across platforms. Components, AI coding, security — you can pick all three.

## Learn more

- [Why QIP](/docs)
- [How QIP Works](/docs/how-it-works)
- [QIP Component Contract](/docs/component-contract)
- [Router Specification](/docs/router)
