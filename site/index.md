<title>qip: fast zig/c as composable wasm</title>

<style>
h1 { text-align: center; }
</style>

# `qip`

## _write (or vibe) code that runs quickly & securely everywhere_

A tiny runtime that runs composable WebAssembly modules securely in the browser, server, and native.

```bash
go install github.com/royalicing/qip@latest

qip run hand-coded-c.wasm
qip run vibe-coded-zig.wasm
qip run a.wasm b.wasm c.wasm > out.png

qip comply vibe-coded-commonmark.wasm --with commonmark-spec.wasm

qip dev ./site --recipes ./recipes
```

## The problem with software today

Much software today is built like Matryoshka dolls, using frameworks that depend on libraries that depend on more libraries that depend on OS libs. This can feel incredibly productive at first, but has lead to increasingly complex apps that need constant updates from devs and feel bloated to users.

The large number of layers and moving parts has expanded the surface areas for security attacks. A developer can no longer fit the actually-running code in their head, and AI agents needs more context and tools to verify what they have generated. This increases iteration time and surface for exploits. A culture of countless dependencies has made us prone to supply-chain attacks. Any line of a package or AI-generated code could be reading SSH keys, mining bitcoin, remotely executing code, or infiltrating private data.

Software is less predictable and harder to debug, both for humans and for AI.

## High expressivity meets low level

Two recent technologies change this: WebAssembly and AI coding.

With WebAssembly we get light cross-platform executables. We can really write once and run anywhere. We can create stable, self-contained binaries that don’t depend on anything external. We can sandbox them so they don’t have any access to the outside world: no file system, no network, not even the current time. This makes them deterministic, a property that makes software more predictable, reliable, and easy to test.

## AI needs hard boundaries

With agentic coding we get the ability to quickly mass produce software. But most programming languages today have wide capabilities that make untrustworthy code risky. Any generated line could hack the system or exploit the user. We need hard constraints, especially if we are no longer closely reviewing code.

Coding agents are now good enough that you can vibe code C or Zig modules that compile into super fast assembly.

`qip` forces you to break code into clear boundaries. Modules follow a dead-simple contract: there’s some input written to WebAssembly memory, and there’s some output that is read. Since this contract is deterministic and modules are self-contained and immutable we can cache easily using the input and module as a key. Connect these modules together and you get a fully deterministic pipeline. Weave these pipelines together and you get a predictable, understandable system.

## Old guardrails

Paradigms like functional or object-oriented or garbage collection become less relevant in this new world. These were patterns that allowed teams of humans to consistently make sense of the modular parts they wove into software. To a LLM, imperative is just as easy as any other paradigm to author. Static allocation is no harder than `malloc`/`free` or garbage collection.

Memory is copied between qip modules so within it can mutate memory as much as it likes, which lets you (or your agent) find the most optimal algorithm. If we align code written to the underlying computing model of the von-Neumann-architecture we can get predictably faster performance. We get pockets of speed safely sewn together.

## Content-first formats & encodings

We believe in using formats that have stood the test of time. Need a simple uncompressed image format? `image/bmp`. Need vector graphics? `image/svg+xml`. Need a snapshot of a directory of files? `application/x-tar`. Need a snapshot of a website? `application/warc`. Need a collection of structured data? `application/vnd.sqlite3`. All text should be `UTF-8`.

qip prefers adding functionality via swappable modules rather than building it into qip itself. This then means our aim is to use open formats that are easily consumed and produced.

For example, our static site builder produces a [Web Archive](<https://en.wikipedia.org/wiki/WARC_(file_format)>) — it’s up to you to decide how that would be turned into a collection of files. Perhaps you want trailing/ slashes/ in your URLs. Perhaps you don’t. Maybe you want to upload the content straight to a S3 bucket with no intermediate files touching disk. Or you prefer running it using Nginx. This is left up to you. qip produces a full archive of every page route, and then it’s up to you and the ecosystem to determine how to use that.

qip is content-first not file-first. Web pages are made of served content, and that content might be dynamic: there might not be a file representation backing what users see. This unlocks flexibility with the ability to pipeline any content together. Files need a name, permissions, a file system for it to live in. We just want the content inside so then we can create wasm modules that consume and produce that type of content.

## Benefits

- **Composable:** swappable units that you author either with AI or by hand.
- **Secure:** isolated from fs/network/env.
- **Small**: lean core instead of giant runtime or framework.
- **Deterministic:** input/output contracts that are easy to test and cache.
- **Portable:** execution that works identically across platforms.
- **Boring**: simple conventions, predictable, reproducible, maintainable.

## Philosophy

Good tools should be:

- easy to compose
- secure by default
- cheap to replace
- rapid to test and iterate
- work on the web, on native, and as a cli
- runnable by both agents and users

## Tech choices

`qip` favors explicit simple contracts and plain directory layouts over magic.

The `qip` cli is built in Go using its venerable standard library for file system access, HTTP server, and common format decoding/encoding. The [wazero](https://wazero.io) library is used to run WebAssembly modules in a secure sandbox. WebAssembly modules can be authored in C, Zig, WAT, or any language that targets wasm32.

It decidedly does not use WASI, a standard due to scope creep has ballooned in complexity. To get stuff done and to support browsers we use a much smaller contract between hosts and modules.

## What qip does:

- Run tiny, focused modules to process or create text, bytes, and images.
- Compose those modules into deterministic pipelines.
- Reuse the same modules in CLI, browser, server, and mobile.
- Provide a stable contract that is simpler than WASI.
- Web file router with everything as replaceable wasm plugins.

What qip does not do:

- It does not have package manager with nested dependencies.
- It does not give modules fs/network/env access.

If you know popular tools, think:

- **Unix pipes**: data flows stage-by-stage.
- **React components**: qip modules are swappable units with clean contracts.
- **GitHub Actions**: qip recipes have explicitly order steps.

Think of them as “React components for more than just rendering HTML that run anywhere.” Everything on this site has been made using coding agents and qip, from the Markdown HTML renderer through to syntax highlighting.

Read the full walkthrough in [`/docs/how-it-works`](/docs/how-it-works).

## Examples

<form aria-labelledby="form-wc-heading">
    <h3 id="form-wc-heading">Word count (wc.wasm running in browser)</h3>
    <blockquote><p>Coding agent prompt: Write a wc.zig module like /usr/bin/wc</p></blockquote>
    <qip-preview>
        <source src="/modules/utf8/wc.wasm" type="application/wasm" />
        <textarea name="input" rows="2" cols="40">There are eight words here. Try typing more… </textarea>
        <output name="output"></output>
    </qip-preview>
</form>

### Word count (same wc.wasm running via cli)

```bash
echo -n "There are eight words here. Try typing more… " | qip run modules/utf8/wc.wasm
#        0       8      47
```

---

<form aria-labelledby="form-markdown-heading">
    <h3 id="form-markdown-heading">Recolor svg icon as orange and convert to favicon (js)</h3>
    <qip-preview>
        <source src="/modules/image/svg+xml/svg-recolor-current-color.wasm" type="application/wasm" data-uniform-color_rgba />
        <source src="/modules/image/svg+xml/svg-rasterize.wasm" type="application/wasm" />
        <source src="/modules/image/bmp/bmp-to-ico.wasm" type="application/wasm" />
        <textarea name="input" rows="9" cols="40">&lt;svg class=&quot;lucide lucide-smile&quot; xmlns=&quot;http://www.w3.org/2000/svg&quot; width=&quot;24&quot; height=&quot;24&quot; viewBox=&quot;0 0 24 24&quot; fill=&quot;none&quot; stroke=&quot;currentColor&quot; stroke-width=&quot;2&quot; stroke-linecap=&quot;round&quot; stroke-linejoin=&quot;round&quot;
&gt;
  &lt;circle cx=&quot;12&quot; cy=&quot;12&quot; r=&quot;10&quot; /&gt;
  &lt;path d=&quot;M8 14s1.5 2 4 2 4-2 4-2&quot; /&gt;
  &lt;line x1=&quot;9&quot; x2=&quot;9.01&quot; y1=&quot;9&quot; y2=&quot;9&quot; /&gt;
  &lt;line x1=&quot;15&quot; x2=&quot;15.01&quot; y1=&quot;9&quot; y2=&quot;9&quot; /&gt;
&lt;/svg&gt;</textarea>
        <input type="color" name="uniform-color_rgba" value="#ff7722" />
        <output name="output" style="zoom: 2; image-rendering: pixelated"></output>
    </qip-preview>
</form>

### Recolor svg icon as orange and convert to favicon (cli)

```bash
curl https://unpkg.com/lucide-static@0.575.0/icons/smile.svg \
| qip run modules/image/svg+xml/svg-recolor-current-color.wasm '?color_rgba=0xff7722ff' \
modules/image/svg+xml/svg-rasterize.wasm \
modules/image/bmp/bmp-to-ico.wasm \
> cog.ico
```

---

<form aria-labelledby="form-markdown-heading">
    <h3 id="form-markdown-heading">Markdown to HTML (js)</h3>
    <qip-preview>
        <source src="/modules/text/markdown/commonmark.0.31.2.wasm" type="application/wasm" />
        <textarea name="input" rows="7" cols="40"># Write some CommonMark *Markdown*
&#10;- Here’s a [link](https&colon;//example.com) in a list
&#10;```bash
qip help run
```</textarea>
    <output name="output"></output>
    </qip-preview>
</form>

### Markdown to HTML (cli)

```bash
echo '# Write some CommonMark *Markdown*' | qip run modules/text/markdown/commonmark.0.31.2.wasm
# <h1>Write some CommonMark <em>Markdown</em></h1>
```

---

## Turing-complete specs for your agents to iterate against

Here’s how to implement CommonMark using Codex and `qip comply`:

1. Download the CommonMark [spec.txt](https://raw.githubusercontent.com/commonmark/commonmark-spec/0.31.2/spec.txt).
2. Ask a coding agent like Codex or Claude Code to generate a qip compliance module from the spec. This creates cases with inputs and expected outputs in fast WebAssembly.
3. Ask your coding agent to implement a new CommonMark from scratch in Zig and iterate until `qip comply` passes.

```bash
# 1) Download CommonMark spec text
curl -L https://raw.githubusercontent.com/commonmark/commonmark-spec/0.31.2/spec.txt -o compliance/commonmark-spec-0.31.2.txt

# 2) Tell your AI to create a qip compliance module using the txt
agent 'Create a `qip comply` module `compliance/commonmark-spec-0.31.2.wasm` in zig from `commonmark-spec-0.31.2.txt`. Run `qip help comply` to learn how to create a compliance module.'

# 3) Tell your AI to create a qip module and keep iterating until compliance passes
agent 'Implement a CommonMark implementation in zig using the comply module to check'

# 4) Your new shiny should PASS your generated spec
qip comply modules/text/markdown/commonmark.0.31.2.wasm \
  --with compliance/commonmark-spec-0.31.2.wasm

# 5) Run your module with whatever markdown you like
echo '# It works!' | qip run modules/text/markdown/commonmark.0.31.2.wasm
# <h1>It works!</h1>
```

---

## Make websites that never go stale

```bash
# List site content
$ ls -R1 site
about.md
favicon.ico
index.md

docs:
first.md
second.md
third.md

# List module pipeline to transform site content
$ ls -R1 recipes
recipes/text/markdown:
10-markdown.wasm
10-markdown.zig
20-highlight-syntax-highlight-bash.wasm
20-highlight-syntax-highlight-bash.zig
29-add-highlight-stylesheet-night-owl.wasm
29-add-highlight-stylesheet-night-owl.zig
70-add-fathom-analytics-script.wasm
70-add-fathom-analytics-script.zig
80-html-page-wrap.wasm
80-html-page-wrap.zig
footer.html
header.html
highlight-night-owl.css
styles.css

# Build site as Web Archive then convert that to static HTML with no trailing slashes
$ qip router warc ./site --recipes recipes \
| qip run modules/application/warc/warc-to-static-tar-no-trailing-slash.wasm \
> site-static.tar
$ mkdir -p site-static && tar -xvf site-static.tar -C site-static
```

---

## Vibe once, run everywhere

TODO: explain why we’d want to invest into a particular implementation and run that everywhere.
