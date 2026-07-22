```
┏━━━┓ ━┳━ ┏━━━┓
┗━┳━┛  ┃  ┣━━━┛
  ╹   ━┻━ ╹
```

QIP Components are Quick to run/make/maintain, Isolated from network/disk/dependencies, and Portable across browser/server/native.

QIP Components are fast for you to create with coding agents and fast for users to run. Your users get small `.wasm` modules that load fast. You get small amounts of code that are easy to review.

We believe small functions should not need a massive application environment to run. QIP is for small pieces of software. Write or vibe Zig/C then compile to WebAssembly, and you get a deterministic puzzle piece that runs the same everywhere.

Use it for text, images, documents, archives, interactive UI, or any format. Components pass content in and content out, with  an optional MIME type for each side. You can pipe component into another step-by-step like a recipe.

Make a recipe you like? You can be confident it will work identically on mobile, in a browser, in your CI pipeline, on Windows, or whatever comes next. If it works here, it works there.

Modern software never stops moving. QIP components are self-contained, so you can worry less about supply-chain attacks, outdated libraries, remote-code execution, and environment drift.

QIP is built around a strict contract: same component, same input, same output. It does not read the clock, locale, filesystem, package graph, environment variables, OS, device, chipset, or network — unless you deliberately pass it in. Every input is explicit. This means if it works today, it’ll work tomorrow.

Components, AI coding, security: you can pick all three.

## Install CLI

```bash
go install github.com/royalicing/qip@latest
```

## Module contract

QIP does not use WASI or WIT, standards that have ballooned in complexity from scope creep. We want to get stuff done in today’s browsers so we pick a much smaller contract between hosts and modules:

- `input_ptr()` / `input_bytes_cap()`: where the host writes input.
- `output_ptr()` / `output_bytes_cap()`: where your module writes its output.
- `render(input_size)`: function to transform input and return output length in bytes.
- Optional `uniform_set_<key>(value)`: primitive integer or float parameters applied explicitly before rendering.

You can read more about the [Content component contract in our docs](./docs/content-component.md).

## CLI Usage

You can pipe the results of other CLI tools to stdin or pass files in via `-i`. You can also chain multiple QIP components together.

```bash
# Normalize phone number
echo "+1 (212) 555-0100" | qip run components/utf8/e164.wasm
# +12125550100

# Convert purple from rgb to hex
echo "rgb(101, 79, 240)" | qip run components/utf8/rgb-to-hex.wasm
# #654ff0

# Expand emoji shortcodes
echo "Run :rocket: WebAssembly components identically on any computer :sparkles:" | qip run components/utf8/shortcode-to-emoji.wasm
# Run 🚀 WebAssembly components identically on any computer ✨

# Create zlib bytes (dynamic Huffman, shown as base64)
echo "qip + wasm" | qip run components/bytes/zlib-compress-dynamic-huffman.wasm components/bytes/base64-encode.wasm
# eAEFwKENAAAMArBX8LtqcmIJBMH7VEcMsv4CEnkDbg==

# Round-trip zlib back to original text
echo "qip + wasm" | qip run components/bytes/zlib-compress-dynamic-huffman.wasm components/bytes/zlib-decompress.wasm
# qip + wasm

#  Load Hacker News, extractor all links with text
curl -s https://news.ycombinator.com | qip run components/text/html/html-link-extractor.wasm | grep "^https:"

# Render QIP logo to ICO
qip run -i qip-logo.svg components/image/svg+xml/svg-rasterize.wasm components/image/bmp/bmp-double.wasm components/image/bmp/bmp-to-ico.wasm > qip-logo.ico

# Render Switzerland flag SVG to ICO
echo '<svg width="32" height="32"><rect width="32" height="32" fill="#d52b1e" /><rect x="13" y="6" width="6" height="20" fill="#ffffff" /><rect x="6" y="13" width="20" height="6" fill="#ffffff" /></svg>' | qip run components/image/svg+xml/svg-rasterize.wasm components/image/bmp/bmp-to-ico.wasm > switzerland-flag.ico

# Rendering cannot loop forever
echo "x" | qip run components/utf8/infinite-loop.wasm
# Error: Wasm module exceeded the execution time limit (100ms)
```

## Guide to making QIP components

There are a few recommended languages for writing QIP components: Zig, C, or raw WebAssembly text format.

### Zig

Here we’ll write a QIP component for an E.164 canonicalizer that takes a phone number and converts it into a canonical international form.

- `+1 (212) 555-0100` -> `+12125550100`
- `  1212-555-0100  ` -> `+12125550100`

#### 1. Create `e164.zig`

```zig
// The input is maximum 64KiB
const INPUT_CAP: usize = 64 * 1024;
// The output is maximum 64KiB
const OUTPUT_CAP: usize = 64 * 1024;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

// Export functions so qip runner can read these values.
// WebAssembly supports multiple return values but Zig and C unfortunately don’t.
export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&output_buf)));
}

export fn output_utf8_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

export fn render(input_size_in: u32) u32 {
    // TODO: we should trap if input is too large
    const input_size: usize = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);

    // Emit '+' then append only digits.
    output_buf[0] = '+';
    var output_size: usize = 1;

    var i: usize = 0;
    while (i < input_size) : (i += 1) {
        const c = input_buf[i];

        if (!isDigit(c)) continue;

        if (output_size >= OUTPUT_CAP) @panic("output buffer overflow");

        output_buf[output_size] = c;
        output_size += 1;
    }

    // If just '+' then return empty string.
    if (output_size == 1) return 0;

    return @as(u32, @intCast(out));
}
```

#### 2. Compile it to WebAssembly

```bash
zig build-exe e164.zig \
  -target wasm32-freestanding \
  -O ReleaseSmall \
  -fno-entry \
  --export=render \
  --export=input_ptr \
  --export=input_utf8_cap \
  --export=output_ptr \
  --export=output_utf8_cap \
  -femit-bin=e164.wasm
```

#### 3. Run it with `qip`

```bash
echo "+1 (212) 555-0100" | qip run e164.wasm
# +12125550100

echo "  1212-555-0100  " | qip run e164.wasm
# +12125550100

# TODO: show how to run with Node.js
```

### C

We’ll write some C to trim leading and trailing whitespace.

#### 1. Create `trim.c`

```c
#include <stdint.h>

#define INPUT_CAP (4u * 1024u * 1024u)
#define OUTPUT_CAP (4u * 1024u * 1024u)

static char input_buffer[INPUT_CAP];
static char output_buffer[OUTPUT_CAP];

__attribute__((export_name("input_ptr")))
uint32_t input_ptr() {
    return (uint32_t)(uintptr_t)input_buffer;
}

__attribute__((export_name("input_utf8_cap")))
uint32_t input_utf8_cap() {
    return sizeof(input_buffer);
}

__attribute__((export_name("output_ptr")))
uint32_t output_ptr() {
    return (uint32_t)(uintptr_t)output_buffer;
}

__attribute__((export_name("output_utf8_cap")))
uint32_t output_utf8_cap() {
    return sizeof(output_buffer);
}

static int is_space(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

__attribute__((export_name("render")))
uint32_t render(uint32_t input_size) {
    if (input_size > INPUT_CAP) {
        // TODO: we should trap if input is too large
        input_size = INPUT_CAP;
    }

    uint32_t start = 0;
    while (start < input_size && is_space(input_buffer[start])) {
        start++;
    }

    uint32_t end = input_size;
    while (end > start && is_space(input_buffer[end - 1])) {
        end--;
    }

    uint32_t out_len = end - start;
    if (out_len > OUTPUT_CAP) {
        // TODO: We should trap.
        return 0;
    }

    for (uint32_t i = 0; i < out_len; i++) {
        output_buffer[i] = input_buffer[start + i];
    }

    return out_len;
}
```

#### 2. Compile it to WebAssembly

```bash
zig cc trim.c \
  -target wasm32-freestanding \
  -nostdlib \
  -Wl,--no-entry \
  -Wl,--export=render \
  -Wl,--export-memory \
  -Wl,--export=input_ptr \
  -Wl,--export=input_utf8_cap \
  -Wl,--export=output_ptr \
  -Wl,--export=output_utf8_cap \
  -Oz \
  -o trim.wasm
```

#### 3. Run it with `qip`

```bash
echo "   hello world   " | qip run trim.wasm
# hello world

printf "\t  line one  \n" | qip run trim.wasm
# line one

# TODO: show how to run with Node.js
```

### Raw WebAssembly

You can also write raw WebAssembly text format which compiles directly to `.wasm`. Here is a hello world example:

```wasm
(module $YourTextModule
;; Memory must be exported with name "memory"
  ;; First page empty, input at 0x10000, output at 0x20000
  (memory (export "memory") 3)

  ;; Internal buffer constants with function exports for qip integration
  (global $input_ptr i32 (i32.const 0x10000))
  (global $input_utf8_cap i32 (i32.const 0x10000))
  (global $output_ptr i32 (i32.const 0x20000))
  (global $output_utf8_cap i32 (i32.const 0x10000))

  (func (export "input_ptr") (result i32)
    (global.get $input_ptr))
  (func (export "input_utf8_cap") (result i32)
    (global.get $input_utf8_cap))
  (func (export "output_ptr") (result i32)
    (global.get $output_ptr))
  (func (export "output_utf8_cap") (result i32)
    (global.get $output_utf8_cap))

  ;; Required export: render(input_size) -> output_size
  ;; Input is at input_ptr, output goes to output_ptr
  ;; Return length of output written
  (func (export "render") (param i32 $input_size) (result i32)
    ;; Write "Hello, World" as i64 + i32
    ;; "Hello, W" as i64 (little-endian: 0x57202c6f6c6c6548)
    (i64.store (global.get $output_ptr) (i64.const 0x57202c6f6c6c6548))
    ;; "orld" as i32 (little-endian: 0x646c726f)
    (i32.store (i32.add (global.get $output_ptr) (i32.const 8)) (i32.const 0x646c726f))
    ;; Return size of output: 12 UTF-8 octets
    (i32.const 12)
  )
)
```

## Router

The `qip` cli comes with a file router for making static websites:

1. Put website source content in a directory (Markdown, HTML, images, CSS, etc.).
2. Add recipe QIP components to transform source files by MIME type. For example you could create a `_recipes/text/markdown/10-markdown-to-html.wasm` to render Markdown to HTML.
3. Preview locally with `qip router dev`.
4. Export as static files with `qip router warc`.

Example content:

```text
docs/
  index.md
  about.md
  images/logo.png
docs/_recipes/
  text/markdown/10-markdown-to-html.wasm
  text/markdown/20-html-page-wrap.wasm
```

Preview in dev mode:

```bash
qip router dev ./docs -p 4000
open http://localhost:4000
```

Resolve a single path through the same router pipeline:

```bash
# GET /about
qip router get ./docs /about
# HEAD /about
qip router head ./docs /about
# List all routes
qip router list ./docs
```

Build static tar from the site:

```bash
qip router warc ./docs \
  | qip run components/application/warc/warc-to-static-tar-no-trailing-slash.wasm \
  > site.tar

tar -tf site.tar

ls ./site
```

## Documentation

- [QIP Component Contracts](docs/component-contract.md)
- [Content Component Contract](docs/content-component.md)
- [Interactive Component Contract](docs/interactive-component.md)
- [Uniforms](docs/uniforms.md)
- [QIP Component Patterns](docs/module-patterns.md)
- [Writing QIP Components in Zig](docs/zig-components.md)
- [Building C Libraries as QIP Components](docs/c-wasm-toolchains.md)
- [Hard Limits](docs/hard-limits.md)
- [Provable Loops](docs/provable-loops.md)
- [Running In JavaScript](docs/esm-integration.md)
- [qip CLI](docs/qip-cli.md)
- [QIP Component Compliance](docs/comply.md)

----

## Required build and test tools

If you are contributing components or running the full `Makefile` in this repo, install these tools:

- `make` and standard POSIX command-line tools such as `find`, `diff`, `tar`, `perl`, and `xxd`
- Go (required for `qip` CLI): https://go.dev/doc/install
- Zig (used for `.zig` and `.c` -> `.wasm` builds): https://ziglang.org/download/
- `wat2wasm` from WABT (used for `.wat` -> `.wasm` builds): https://github.com/WebAssembly/wabt
- Node.js 20+ (used by `make test-node` and the default `make test` path): https://nodejs.org/
- Deno (optional, used by `make test-deno`): https://deno.com/

Quick installs:

```bash
# macOS (Homebrew)
brew install go zig wabt node

# Ubuntu/Debian (install Node.js 20+ from your preferred Node distribution)
sudo apt-get update
sudo apt-get install -y build-essential golang-go wabt perl vim-common
```

After installing dependencies, build in parallel:

```bash
make -j components recipes
```

Run the test targets through the Makefile:

```bash
make -j test-node
make -j test-deno
make -j test-go
make -j test
```

`test/trace-with.mjs` is included in both `make -j test-node` and `make -j test-deno`. To run it directly with Node:

```bash
make -j qip components/application/wasm/wasm-trace-instrument.wasm
node --test test/trace-with.mjs
```

To run it directly with Deno, pass the same permissions used by `make test-deno`:

```bash
deno test --allow-read --allow-write --allow-run --allow-sys --allow-env test/trace-with.mjs
```

You can clone this repo to use the components provided in `./components`.

The component layout groups by content type (or by encoding such as UTF-8):

```text
components/
  bytes/
  image/svg+xml/
  text/css/
  text/html/
  text/javascript/
  text/markdown/
  text/x-c/
  rgba/
  utf8/
```

## Notes: Compare Compression Ratios

Use the comparison harness to measure ratio and speed across `qip`, Python, Go, Bun, and available PATH tools.

```bash
# Compare on existing files
./tools/compare-deflate.py --runs 5 --warmup 1 README.md main.go

# Compare on synthetic data
head -c 262144 /dev/zero > /tmp/qip-bench-zeros-256k.bin
head -c 262144 /dev/urandom > /tmp/qip-bench-random-256k.bin
./tools/compare-deflate.py --runs 5 --warmup 1 /tmp/qip-bench-zeros-256k.bin /tmp/qip-bench-random-256k.bin
```

Benchmark the performance of one or more QIP components. If you compare multiple components then it’ll check each output is exactly the same. This is useful for porting from C to Zig, or asking your AI agent to implement optimizations and verifying that the result still behaves the same.

```bash
# Benchmark one component for two seconds
echo "World" | qip bench -i - --benchtime=2s components/utf8/hello.wasm
# bench: outputs match

# Benchmark two components against each other and verify identical output
echo "World" | qip bench -i - --benchtime=2s components/utf8/hello.wasm components/utf8/hello-c.wasm
# bench: outputs match

# Benchmark three components against each other and verify identical output
echo "World" | qip bench -i - --benchtime=2s components/utf8/hello.wasm components/utf8/hello-c.wasm components/utf8/hello-zig.wasm
# bench: outputs match
```

## TODO

- [ ] Update to latest Zig
- [ ] Consider making `qip comply --declarative-checkers` the default after all supported Compliance components satisfy it; keep the explicit flag available for reproducible older workflows.
- [ ] Wrap `<source>` with `<qip-step>` as multiple `<source>` elements are meant to be alternatives to each other.
  - [ ] Add conditional sources with a step, such as to support bmp or png or jpeg upload with `<input type="file">`.
- [ ] Add support for nested `<qip-render component="bytes/base64">` that can be substituted at compile-time. This would allow something akin to React or Astro components doing server (or static) rendering.
- [ ] Add a signal for `<qip-view>` marking pre-rendered output as authoritative so activation can skip the initial render (perhaps a `rendered` attribute). It must be an explicit marker, never inferred from non-empty output, since empty output is a valid result.
- [ ] Retire the web-shaped `Form` component contract.
  - [ ] Add `submit(input_size)` export
    - [ ] Input is either `application/x-www-form-urlencoded` or `multipart/form-data`
    - [ ] Have demo with `FormData` that works in client and on server
    - [ ] Will be like an uncontrolled form in React, where every keypress does NOT need a re-render. Only do this on submit.
    - [ ] See how it could work with the Interactive component contract, and HTML-in-canvas
  - [ ] In favor of a future cross-host `Prompt` contract: sequential prompts with recoverable failure, `submit(input_size, now_ms)` for state changes, and `render(0)` for the current semantic projection/output.
- [ ] Add Command Palette example, combining `<input>` and `<canvas>`
- [ ] Add CSV to chart SVG example
- [ ] Add TCP simulator example, showing segments and allowing you to test failure.
- [ ] Add more shader examples from https://github.com/paper-design/shaders/tree/main/packages/shaders/src/shaders:
  - [x] God rays
  - [ ] Metaballs, dithering, grain gradient, mesh gradient, heatmap, liquid metal, and halftone
  - See https://shaders.paper.design
- [ ] Add `application/edifact` example
- [ ] Add Wuffs example
  - See: https://github.com/google/wuffs/blob/main/doc/getting-started.md
  - See roadmap of examples: https://github.com/google/wuffs/blob/main/doc/roadmap.md
- [ ] Allow `qip comply` to be run against arbitrary shell command. This would internally call out to the underlying command by copying the input when the comply task calls `impl.render`.
- [ ] Add Email render example (do we use an existing layout system?)
  - See https://www.joshwcomeau.com/react/wonderful-emails-with-mjml-and-mdx/
  - See https://react.email/components and https://demo.react.email/preview/05-Studio/welcome
- [ ] Add MathML https://www.w3.org/TR/mathml-core/ `<math>` renderer
  - See https://github.com/KaTeX/KaTeX
  - See https://www.intmath.com/cg5/katex-mathjax-comparison.php?processor=MathJax3
  - See https://andrewlock.net/rendering-math-in-html-mathml-mathml-core-and-asciimath/
  - See https://developer.mozilla.org/en-US/docs/Web/MathML/Reference/Element/semantics
  - See https://asciimath.org/#syntax
  - Have `/math-to-html` demo like https://katex.org/#demo
- [ ] Increase recipe order prefix from `nn` to `nnn`.
- [ ] Add dev/CI QIP Vitals for pipelines: harness metrics that zoom in on time to first render bytes (read/fetch, compile, instantiate, first `render`), per-stage render time, full pipeline render time, interactive event-to-frame-bytes latency, frame-budget miss rate, output hash, wasm/compressed size, input/output byte sizes, memory pages/max memory, trap/timeout rate, and host/runtime/device metadata. Report p50/p95/p99 so timings stay measurable and comparable when output bytes still match.
- [ ] Add optional field telemetry for deployed QIP components: user-experience metrics such as component hash, host/runtime/device class, time to first QIP paint p75/p95/p99, render-to-paint delay p75/p95/p99, interactive event-to-painted-frame p75/p95/p99, sampled pipeline render p95/p99, frame-budget miss rate, trap/timeout rate, and slowest device classes so production performance can be compared without changing the component contract.
- [ ] Add TypeScript-to-JavaScript type stripper.
- [x] Document uniforms properly `qip image -i fixtures/SAAM-2015.54.2_1.jpg -o tmp/halftone.png components/rgba/color-halftone.wasm '?max_radius=2.0' components/rgba/brightness.wasm '?brightness=0.2'`
- [ ] Add CDN example to allow this to run server-side: `qip image -i fixtures/SAAM-2015.54.2_1.jpg -o tmp/halftone.png components/rgba/color-halftone.wasm '?max_radius=2.0' components/rgba/brightness.wasm '?brightness=0.2'`
- [ ] Add DOOM example.
  - See https://github.com/Daivuk/PureDOOM
- [ ] Add monochrome rendering `output_monochrome_bytes() -> i32`
- [x] Add application/wasm verifier for fixed memory, fixed-bound loop evidence, and no recursion. This is a conservative subset of https://en.wikipedia.org/wiki/The_Power_of_10:_Rules_for_Developing_Safety-Critical_Code: loops must compile to a visible counter, monotonic update, and exit bound.
- [ ] Add a `wasm-fuel-instrument` component that injects deterministic fuel metering as a wasm-to-wasm transform: a decrementing fuel global checked at each loop backedge and call, trapping at zero. Prior art: wasmtime fuel/epochs and Parity's wasm-metering gas injection. Fuel is deterministic (same input, same fuel spend on every host), unlike wall-clock `--timeout-ms`, and browsers cannot preempt a wasm call on the main thread. This gives modules whose loops the static checker cannot prove (for example `commonmark`) a metered tier, while statically proven modules keep the strict tier.
- [ ] Add tracing by modifying modules:
  - [ ] Trace unreachable by adding calls to memory reads of input so we can check last read which will likely be source reason for the trap.
  - [ ] Trace any loops by adding calls to an imported function in each iteration. e.g. `trace_loop($func_n, $loop_n)`
  - [ ] Trace any internal calls by adding calls to an imported function. e.g. `trace_will_call($func_n, $call_n)`
  - [ ] Trace any branches by adding calls to an imported function. e.g. `trace_if($func_n, $if_n)` and `trace_block($func_n, $block_n)`
  - [x] Trace scalar Wasm32 memory loads/stores with before/after callbacks.
  - [ ] Extend memory tracing to SIMD, atomic, and bulk-memory operations.
- [ ] Extend `paint` example with `animate` that is like Flash or After Effects with a simple keyframe and tween editor of graphics. We could have a limited number of layers (8?) and text input.
- [x] Add spreadsheet example.
- [x] Add bar charts.
- [ ] Add scatter plot charts.
- [x] Add pixel editor.
- [x] Add Cover Flow example.
- [ ] Add Figma vector networks example.
- [x] Add localized example in multiple languages.
- [ ] Add a split interactive pipeline mode with two collaborative modules: state/tick module writes an internal scene buffer, renderer module consumes it via `render(input_size)` with a simple `memcpy` handoff between module instances, enabling presentation variants like language/locale, dark or light mode, font size, DPI scaling, and accessibility-focused rendering.
- [ ] Have separate `pointermove` event handler so we can skip expensive `pointermove` listeners and rendering if not needed??
- [ ] Refine the interactive tick result contract: events return accepted/ignored, but `tick()` currently returns only `next_wake_at_ms`; define how tick also communicates whether `render(0)` is necessary without losing scheduled wakeups. Specify pointer leave/cancel coordinates and button state consistently across hosts.
- [ ] Add digest pinning for remote modules (for example `https://...#sha256=<hex>`), and fail fast when fetched bytes do not match the pinned digest.
- [x] Update docs to encourage hard failure with traps instead of returning empty output which could lead to data loss.
- [ ] Convert soft-failure validators to trap on invalid input, then add invalid-then-valid same-instance recovery tests:
  - [ ] `components/text/css/css-class-validator.wasm`
  - [x] `components/text/html/html-id-validator.wasm`
  - [x] `components/text/html/html-input-name-validator.wasm`
  - [x] `components/text/html/html-tag-validator.wasm`
  - [ ] `components/utf8/tld-validator.wasm`
  - [x] `components/utf8/luhn.wasm`
- [x] Add `qip dry run ...pipeline.wasm` that validates pipeline compatibility and outputs memory usage (summing all input/output buffers).
- [ ] Add `qip serve` command that runs the server in `prod` mode by default, and includes a module upload endpoint.
- [ ] Add `random_ptr` and `random_size` to modules that the host can detect and fill in with random data. It can choose to seed with determinism or use a cryptographic source of randomness — it’s up to the host.
- [ ] Add `--postcondition` or `--outmust` flag to `qip run` that verifies the final output conforms to a particular module e.g. `--postcondition valid-xml-1.0.wasm`.
- [ ] Add first-stage content-type guards: either lightweight ingress sniffing (check initial bytes against expected type) or validator modules (for example `validate-html.wasm`) that accept untrusted input and re-emit it with asserted MIME type on success.
- [ ] Add `qip photocopy` command that observes an existing tool’s input/output behavior and generates a behaviorally similar QIP module implementation in wasm, then validates it with duel/fuzz tests and reports divergences.
- [ ] Finish **Compliance components** as a first-class component type alongside `Content`, `Interactive`, `Tile`, and `Form`. The host bridge streams one case at a time, supports procedurally generated oracles and mutation loops, and keeps checker memory separate from implementation memory.
  - [ ] Case identity = bridge-call ordinal. Checkers are deterministic, so "case 987 of the CommonMark suite" is reproducible by re-running the checker and skipping the first 986 interactions (host returns pass without executing the impl until the target ordinal). `qip comply --case 987` prints that case's name/input/expected without needing any failure ABI; `--continue` counts all divergences instead of stopping.
  - [ ] Corpus extraction for non-QIP implementations: run the checker against a null impl (host records every declared case instead of executing anything) and export the ordered corpus as a tar archive (simple, streaming, ordered, arbitrary binary entries; the repo already speaks tar). Any external harness — a Go test dueling x/text, a Node script dueling `toLocaleLowerCase`, a CLI duel over stdin/stdout — consumes the tar. This makes the emit-a-corpus design a *host feature* of the bridge design rather than a separate module shape.
  - [x] Migrate all repository checkers, including Luhn, E.164, `preserve-*`, and `trap-*`, to the bridge.
  - [ ] Move the Compliance-component meta-contract checks into `qip comply` base validation (the way static contract checks already run for render components): deterministic declarations across a double null-impl run, sequential u64 ordinals, examination open/continue/close discipline, and seed-varies-fuzz-only. Per-component harnesses must not each re-verify these; `test/lib/compliance-harness.mjs` is the interim JS reference implementation of both the bridge and the generic checks.
- [ ] Add optimization where if the `output_ptr >= input_ptr && (output_ptr + output_size < input_ptr + input_cap)` then we can do a slice of our existing input we passed in instead of copying out the output. This would need an update to docs/component-contract.md where `output_ptr()` MUST be read only after calling `run` to allow. This is because this optimization from the module might depend on what input is passed in.
- [ ] Revisit numeric outputs as SIMD-aware tensors instead of restoring the old `output_i32_cap` directly. Useful proof cases are batched CRC, histograms, offset arrays, masks, and matrices. Keep element type, logical shape, and physical layout separate; Mojo's scalar-as-one-lane-SIMD and explicit layout model is pertinent prior art.

![qip logo](qip-logo.svg)
