![qip logo](qip-logo.svg)

QIP Components are Quick to run/make/maintain, Isolated from network/disk/dependencies, and Portable across browser/server/native.

You write or vibe C/Zig, compile it to WebAssembly and have a deterministic puzzle piece that will run the same everywhere. These components can work with text, images, or any binary data, and then be composed into predictable recipes. Make a recipe you like? You can be confident it’ll work identically on mobile, in a browser, in your CI pipeline, on Windows, or whatever comes next.

Because they are self-contained with no required dependencies they will keep working for years to come. This means you can worry less about supply-chain attacks, outdated libraries, remote-code-execution, and environment or file-system access.

Your users get small `.wasm` modules that load fast, you get small amounts of code that is easy to review.

## Install CLI

```bash
go install github.com/royalicing/qip@latest
```

## Module contract

QIP does not use WASI or WIT, standards that have ballooned in complexity from scope creep. We want to get stuff done in today’s browsers so we pick a much smaller contract between hosts and modules:

- `input_ptr()` / `input_bytes_cap()`: where the host writes input.
- `output_ptr()` / `output_bytes_cap()`: where your module writes its output.
- `render(input_size)`: function to transform input and return output length in bytes.

You can read more about the [component contract in our docs](./docs/component-contract.md#qip-component-contract).

## CLI Usage

You can pipe the results of other CLI tools to stdin or pass files in via `-i`. You can also chain multiple QIP components together.

```bash
# Normalize phone number
echo "+1 (212) 555-0100" | qip run modules/utf8/e164.wasm
# +12125550100

# Convert purple from rgb to hex
echo "rgb(101, 79, 240)" | qip run modules/utf8/rgb-to-hex.wasm
# #654ff0

# Expand emoji shortcodes
echo "Run :rocket: WebAssembly components identically on any computer :sparkles:" | qip run modules/utf8/shortcode-to-emoji.wasm
# Run 🚀 WebAssembly components identically on any computer ✨

# Create zlib bytes (dynamic Huffman, shown as base64)
echo "qip + wasm" | qip run modules/bytes/zlib-compress-dynamic-huffman.wasm modules/bytes/base64-encode.wasm
# eAEFwKENAAAMArBX8LtqcmIJBMH7VEcMsv4CEnkDbg==

# Round-trip zlib back to original text
echo "qip + wasm" | qip run modules/bytes/zlib-compress-dynamic-huffman.wasm modules/bytes/zlib-decompress.wasm
# qip + wasm

#  Load Hacker News, extractor all links with text
curl -s https://news.ycombinator.com | qip run modules/text/html/html-link-extractor.wasm | grep "^https:"

# Render QIP logo to ICO
qip run -i qip-logo.svg modules/image/svg+xml/svg-rasterize.wasm modules/image/bmp/bmp-double.wasm modules/image/bmp/bmp-to-ico.wasm > qip-logo.ico

# Render Switzerland flag SVG to ICO
echo '<svg width="32" height="32"><rect width="32" height="32" fill="#d52b1e" /><rect x="13" y="6" width="6" height="20" fill="#ffffff" /><rect x="6" y="13" width="20" height="6" fill="#ffffff" /></svg>' | qip run modules/image/svg+xml/svg-rasterize.wasm modules/image/bmp/bmp-to-ico.wasm > switzerland-flag.ico

# Rendering cannot loop forever
echo "x" | qip run modules/utf8/infinite-loop.wasm
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

  ;; Required globals for qip integration
  (global $input_ptr (export "input_ptr") i32 (i32.const 0x10000))
  (global $input_utf8_cap (export "input_utf8_cap") i32 (i32.const 0x10000))
  (global $output_ptr (export "output_ptr") i32 (i32.const 0x20000))
  (global $output_utf8_cap (export "output_utf8_cap") i32 (i32.const 0x10000))

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
3. Preview locally with `qip dev`.
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
qip dev ./docs -p 4000
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
  | qip run modules/application/warc/warc-to-static-tar-no-trailing-slash.wasm \
  > site.tar

tar -tf site.tar

ls ./site
```

## Documentation

- [QIP Component Contract](docs/component-contract.md)
- [QIP Component Patterns](docs/module-patterns.md)
- [Writing QIP Components in Zig](docs/zig-components.md)
- [WebAssembly ES Module Integration](docs/esm-integration.md)
- [Security Model](docs/security-model.md)
- [QIP Component Compliance](docs/comply.md)

----

## Required build tools

If you are contributing modules or running the full `Makefile` in this repo, install these tools:

- Go (required for `qip` CLI): https://go.dev/doc/install
- Zig (used for `.zig` and `.c` -> `.wasm` builds): https://ziglang.org/download/
- `wat2wasm` from WABT (used for `.wat` -> `.wasm` builds): https://github.com/WebAssembly/wabt

Quick installs:

```bash
# macOS (Homebrew)
brew install go zig wabt

# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y golang-go wabt
```

After installing dependencies, build in parallel:

```bash
make -j modules recipes
```

You can clone this repo to use the modules that are provided in `./modules`.

Current module layout groups by content type (or by encoding such as utf-8):

```text
modules/
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
echo "World" | qip bench -i - --benchtime=2s modules/utf8/hello.wasm
# bench: outputs match

# Benchmark two components against each other and verify identical output
echo "World" | qip bench -i - --benchtime=2s modules/utf8/hello.wasm modules/utf8/hello-c.wasm
# bench: outputs match

# Benchmark three components against each other and verify identical output
echo "World" | qip bench -i - --benchtime=2s modules/utf8/hello.wasm modules/utf8/hello-c.wasm modules/utf8/hello-zig.wasm
# bench: outputs match
```

## TODO

- [ ] Add TypeScript-to-JavaScript type stripper.
- [ ] Document uniforms properly `qip image -i fixtures/SAAM-2015.54.2_1.jpg -o tmp/halftone.png modules/rgba/color-halftone.wasm '?max_radius=2.0' modules/rgba/brightness.wasm '?brightness=0.2'`
- [ ] Add CDN example to allow this to run server-side: `qip image -i fixtures/SAAM-2015.54.2_1.jpg -o tmp/halftone.png modules/rgba/color-halftone.wasm '?max_radius=2.0' modules/rgba/brightness.wasm '?brightness=0.2'`
- [ ] Add IEEE 754 Floating-Point example letting me see mantissa, toggle bits, toggle negative, see formatted hexadecimal and decimal, and what ever else would be useful for understanding f32 and f64.
- [ ] Add application/wasm verifier that checks no dynamic memory allocation, all loops have a fixed upper bound, no recursion. A subset of https://en.wikipedia.org/wiki/The_Power_of_10:_Rules_for_Developing_Safety-Critical_Code
- [ ] Add tracing by modifying modules:
  - [ ] Trace unreachable by adding calls to memory reads of input so we can check last read which will likely be source reason for the trap.
  - [ ] Trace any loops by adding calls to an imported function in each iteration. e.g. `trace_loop($func_n, $loop_n)`
  - [ ] Trace any internal calls by adding calls to an imported function. e.g. `trace_will_call($func_n, $call_n)`
  - [ ] Trace any branches by adding calls to an imported function. e.g. `trace_if($func_n, $if_n)` and `trace_block($func_n, $block_n)`
  - [ ] Trace any memory reads/write by adding calls to an imported function. e.g. `trace_will_read_memory($func_n, $read_n)` and `trace_will_write_memory($func_n, $write_n)`
- [ ] Extend `paint` example with `animate` that is like Flash or After Effects with a simple keyframe and tween editor of graphics. We could have a limited number of layers (8?) and text input.
- [ ] Add spreadsheet example.
- [ ] Add bar charts.
- [ ] Add pixel editor.
- [ ] Add Cover Flow example.
- [ ] Add Figma vector networks example.
- [ ] Add localized example in multiple languages.
- [ ] Add a split interactive pipeline mode with two collaborative modules: state/tick module writes an internal scene buffer, renderer module consumes it via `render(input_size)` with a simple `memcpy` handoff between module instances, enabling presentation variants like language/locale, dark or light mode, font size, DPI scaling, and accessibility-focused rendering.
- [x] Change render contract to extend existing contract:
  - [x] Interactive modules use `export fn render(input_size: i32) i32`
  - [x] Interactive modules use `export fn output_rgba8_srgb_bytes() u32` as the primary output-byte export.
- [ ] Have separate `pointermove` event handler so we can skip expensive `pointermove` listeners and rendering if not needed??
- [ ] Retire the web-shaped `Form` framing in favor of a future cross-host `Prompt` contract: sequential prompts with recoverable failure, `submit(input_size, now_ms)` for state changes, and `render(0)` for the current semantic projection/output.
- [ ] Add digest pinning for remote modules (for example `https://...#sha256=<hex>`), and fail fast when fetched bytes do not match the pinned digest.
- [ ] Update docs to encourage hard failure with traps instead of returning empty output which could lead to data loss.
- [ ] Convert soft-failure validators to trap on invalid input, then add invalid-then-valid same-instance recovery tests:
  - [ ] `modules/text/css/css-class-validator.wasm`
  - [ ] `modules/text/html/html-id-validator.wasm`
  - [ ] `modules/text/html/html-input-name-validator.wasm`
  - [ ] `modules/text/html/html-tag-validator.wasm`
  - [ ] `modules/utf8/tld-validator.wasm`
  - [ ] `modules/utf8/luhn.wasm`
- [x] Use `qip router` as the routing/export CLI command for consistent "Qip Router" branding.
- [x] Add symlink support for reading recipes. This means we can have a single implementation and then link it into the recipes directory.
- [ ] Add `qip dry run ...pipeline.wasm` that validate pipeline is compatible and outputs memory usage (summing all input/output buffers).
- [ ] Add `qip serve` command that runs the server in `prod` mode by default, and includes a module upload endpoint.
- [ ] Add `random_ptr` and `random_size` to modules that the host can detect and fill in with random data. It can choose to seed with determinism or use a cryptographic source of randomness — it’s up to the host.
- [ ] Add `--postcondition` or `--outmust` flag to `qip run` that verifies the final output conforms to a particular module e.g. `--postcondition valid-xml-1.0.wasm`.
- [ ] Add first-stage content-type guards: either lightweight ingress sniffing (check initial bytes against expected type) or validator modules (for example `validate-html.wasm`) that accept untrusted input and re-emit it with asserted MIME type on success.
- [ ] Add `qip photocopy` command that observes an existing tool’s input/output behavior and generates a behaviorally similar QIP module implementation in wasm, then validates it with duel/fuzz tests and reports divergences.
- [ ] Add optimization where if the `output_ptr >= input_ptr && (output_ptr + output_size < input_ptr + input_cap)` then we can do a slice of our existing input we passed in instead of copying out the output. This would need an update to docs/component-contract.md where `output_ptr()` MUST be read only after calling `run` to allow. This is because this optimization from the module might depend on what input is passed in.
- [ ] Revisit numeric outputs as SIMD-aware tensors instead of restoring the old `output_i32_cap` directly. Useful proof cases are batched CRC, histograms, offset arrays, masks, and matrices. Keep element type, logical shape, and physical layout separate; Mojo's scalar-as-one-lane-SIMD and explicit layout model is pertinent prior art.
- [ ] Finish migrating QIP contract exports to zero-arg functions only. Convert remaining WAT modules that export pointer/cap globals, then remove "global or function" support and wording from the Go runtime, comply checks, and docs.
