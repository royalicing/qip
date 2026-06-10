<title>QIP: sandboxed components that run anywhere</title>

<style>
.hero-left {
    max-width: 50%;
    float: left;

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
.hero-right {
    max-width: 50%;
    float: right;
}
hr { clear: both }
</style>

<section class="hero-left">

<h1>Small WebAssembly components with hard boundaries</h1>

<p><strong>QIP:</strong> Quarantined. Immutable. Portable.</p>

<a href="/docs">Read the docs</a>

</section>

<section class="hero-right">

## QIP components run sandboxed on browser, server, and native.

QIP components are WebAssembly modules with a small explicit contract: bytes in, bytes out, no filesystem, no network, no environment, and explicit composition.

They are quick for coding agents to create and quick for users to run. You can plonk them into existing applications or use QIP Router to create websites like this one.

</section>

---

## The problem

Modern software often depends on ambient state: packages, framework runtime behavior, environment variables, filesystem layout, network services, clocks, and containers that try to freeze all of it.

Docker can package that world, but it does not make the code small or easy to reason about. A small transform or preview should not need a whole application environment to run predictably.

## The QIP approach

QIP makes the unit of composition a **QIP component**: a small self-contained WebAssembly module with explicit memory exports and no ambient authority.

- **Quarantined:** components run in a deterministic sandbox with zero access to the host (no filesystem, network, or environment).
- **Immutable:** components are self-contained with no required dependencies, so once you have a working component it keeps working with no updates required.
- **Portable:** components run identically across web and native hosts through the same QIP contract.
- **Composable:** pipe components together like CLI tools.
- **Deterministic:** the same component and input are guaranteed to produce the same output.
- **Agent-friendly:** components are small enough to generate, review, benchmark, and replace.

## What you can build

### Content pipelines

```bash
echo "rgb(101, 79, 240)" \
| qip run modules/utf8/rgb-to-hex.wasm
# #654ff0
```

Content components can convert, assert, or refine text and bytes. A pipeline can turn Markdown into HTML, SVG into an icon, URLs into QR codes, or WARC archives into deployable site artifacts.

### Browser previews

<form aria-labelledby="form-wc-heading">
    <h3 id="form-wc-heading">Word count</h3>
    <p><code>text/plain -> text/plain</code></p>
    <blockquote><p>Coding agent prompt: Write a wc.zig QIP component like /usr/bin/wc</p></blockquote>
    <qip-preview>
        <source src="/components/utf8/wc.wasm" type="application/wasm" />
        <textarea name="input" rows="2" cols="40">There are eight words here. Try typing more...</textarea>
        <output name="output"></output>
    </qip-preview>
</form>

The browser runtime loads the same component shape as the CLI. There is no separate plugin model for previewing small tools.

### Interactive components

Interactive QIP components render full frames and receive explicit key, pointer, and tick events.

See [`/play-sudoku`](/play-sudoku), [`/play-side-scroller-platformer`](/play-side-scroller-platformer), and [`/play-liars-dice`](/play-liars-dice) for examples.

## Site routing without a config file

QIP can also route a content tree:

```txt
site/
  index.md
  docs/router.md
  _recipes/text/markdown/10-markdown-basic.wasm
  _components/interactive/sudoku.wasm
```

```bash
qip dev ./site
qip router warc ./site --view-source
```

Content files become request paths. Recipes transform content by MIME type. Browser-loadable components are served from `/components/*`. The source layout stays explicit because the filesystem is the specification.

## Learn the model

- [How QIP Works](/docs/how-it-works)
- [QIP Component Contract](/docs/module-contract)
- [Router Specification](/docs/router)
- [Why QIP Exists](/docs/why-qip)
