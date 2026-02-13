# `qip`

Pipelines of safe determinism in a probabilistic generative world.

`qip` lets you compose small modules for text and images. Modules do one thing well and can be piped together to make powerful replayable tools.

- **Quarantined**: modules run in a secure sandbox, with explicit input and output.
- **Immutable**: modules are self-contained compiled .wasm units and usually avoid constant dependency updates.
- **Portable**: WebAssembly pipelines run identically across platforms.

These attribute make agentic coding a great fit for creating modules. WebAssembly is designed from the ground up for web browsers to be strongly isolated from the rest of the system. And you can use C or Zig to get near-native performance.

![qip logo](qip-logo.svg)

## Install

```
go install github.com/royalicing/qip@latest
```

By default no wasm modules are included. You can clone this repo to use the `./examples` that are provided.

## Usage

You can pipe the results of other tools to stdin or pass files in via `-i`. You can then chain multiple wasm modules together.

```bash
# Normalize phone number
echo "+1 (212) 555-0100" | qip run examples/e164.wasm
# +12125550100

# Convert WebAssembly purple from rgb to hex
echo "rgb(101, 79, 240)" | qip run examples/rgb-to-hex.wasm
# #654ff0

# Create zlib bytes (dynamic Huffman, shown as base64)
echo "qip + wasm" | qip run examples/zlib-compress-dynamic-huffman.wasm examples/base64-encode.wasm
# eAEFwKENAAAMArBX8LtqcmIJBMH7VEcMsv4CEnkDbg==

# Round-trip zlib back to original text
echo "qip + wasm" | qip run examples/zlib-compress-dynamic-huffman.wasm examples/zlib-decompress.wasm
# qip + wasm

# Expand emoji shortcodes
echo "Run :rocket: WebAssembly pipelines identically on any computer :sparkles:" | qip run examples/shortcode-to-emoji.wasm
# Run 🚀 WebAssembly pipelines identically on any computer ✨

#  Load Hacker News, extractor all links with text
curl -s https://news.ycombinator.com | qip run examples/html-link-extractor.wasm | grep "^https:"

# Render .svg to .ico
qip run -i qip-logo.svg examples/svg-rasterize.wasm examples/bmp-double.wasm examples/bmp-to-ico.wasm > qip-logo.ico

# Render Switzerland flag svg to .ico
echo '<svg width="32" height="32"><rect width="32" height="32" fill="#d52b1e" /><rect x="13" y="6" width="6" height="20" fill="#ffffff" /><rect x="6" y="13" width="20" height="6" fill="#ffffff" /></svg>' | qip run examples/svg-rasterize.wasm examples/bmp-to-ico.wasm > switzerland-flag.ico
```

### Benchmark and compare modules

### Compare Compression Ratios

Use the comparison harness to measure ratio and speed across `qip`, Python, Go, Bun, and available PATH tools.

```bash
# Compare on existing files
./tools/compare-deflate.py --runs 5 --warmup 1 README.md main.go

# Compare on synthetic data
head -c 262144 /dev/zero > /tmp/qip-bench-zeros-256k.bin
head -c 262144 /dev/urandom > /tmp/qip-bench-random-256k.bin
./tools/compare-deflate.py --runs 5 --warmup 1 /tmp/qip-bench-zeros-256k.bin /tmp/qip-bench-random-256k.bin
```

Benchmark the performance of one or more modules. If you compare multiple modules then it’ll check each output is exactly the same. This is great for porting say from C to Zig or asking your AI agent to implement optimizations and verifying that it works exactly the same as before.

```bash
# Benchmark module for two seconds
echo "World" | qip bench -i - --benchtime=2s examples/hello.wasm
# bench: outputs match

# Benchmark two modules against each other and verify identical output
echo "World" | qip bench -i - --benchtime=2s examples/hello.wasm examples/hello-c.wasm
# bench: outputs match

# Benchmark three modules against each other and verify identical output
echo "World" | qip bench -i - --benchtime=2s examples/hello.wasm examples/hello-c.wasm examples/hello-zig.wasm
# bench: outputs match
```

### Dev server

```bash
# Preview this Markdown README as HTML page
qip dev -i README.md -p 4000 -- ./examples/markdown-basic.wasm ./examples/html-page-wrap.wasm

# Preview rendering qip-logo.svg to .ico in browser
qip dev -i qip-logo.svg -p 4001 -- examples/svg-rasterize.wasm examples/bmp-to-ico.wasm
```

### Image

You can process images through a chain of rgba shaders. It breaks the work into 64x64 tiles.

```bash
qip image -i examples/images/SAAM-2015.54.2_1.jpg -o tmp/k.png examples/rgba/black-and-white.wasm examples/rgba/invert.wasm examples/rgba/vignette.wasm
```

## TODO

- [ ] Add digest pinning for remote modules (for example `https://...#sha256=<hex>`), and fail fast when fetched bytes do not match the pinned digest.
- [ ] Update docs to encourage hard failure with traps instead of returning empty output which could lead to data loss.

## Documentation

- [Module Memory Guide](docs/module-memory.md)
- [Module Patterns (including error semantics)](docs/module-patterns.md)
- [Security Model](docs/security-model.md)

---

## Guide to making modules

There are a few recommended ways to write a qip module: Zig, C, or even raw WebAssembly text format.

### Zig

Here is a concrete, useful module you can build in a few minutes: an E.164 canonicalizer.

Goal: turn noisy phone input into `+` followed by digits.

- `+1 (212) 555-0100` -> `+12125550100`
- `  1212-555-0100  ` -> `+12125550100`

#### 1. Create `e164.zig`

```zig
const INPUT_CAP: usize = 64 * 1024;
const OUTPUT_CAP: usize = 64 * 1024;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

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

export fn run(input_size_in: u32) u32 {
    const input_size: usize = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);

    // Emit '+' then append only digits.
    output_buf[0] = '+';
    var out: usize = 1;

    var i: usize = 0;
    while (i < input_size) : (i += 1) {
        const c = input_buf[i];
        if (!isDigit(c)) continue;

        if (out >= OUTPUT_CAP) return 0;
        output_buf[out] = c;
        out += 1;
    }

    // Invalid when no digits were present.
    if (out == 1) return 0;
    return @as(u32, @intCast(out));
}
```

#### 2. Compile it to WebAssembly

```bash
zig build-exe e164.zig \
  -target wasm32-freestanding \
  -O ReleaseSmall \
  -fno-entry \
  --export=run \
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
```

#### 4. Understand the contract

- `input_ptr` / `input_utf8_cap`: where `qip` writes input bytes.
- `output_ptr` / `output_utf8_cap`: where your module writes output bytes.
- `run(input_size)`: process input and return output length in bytes.

### C

Here is a compact C module that trims leading/trailing ASCII whitespace.

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

__attribute__((export_name("run")))
uint32_t run(uint32_t input_size) {
    if (input_size > INPUT_CAP) {
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
  -Wl,--export=run \
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
```

#### 4. Understand the contract

- `input_ptr` / `input_utf8_cap`: where `qip` writes input bytes.
- `output_ptr` / `output_utf8_cap`: where your module writes output bytes.
- `run(input_size)`: process input and return output length in bytes.
- In this module, `run` trims leading/trailing whitespace and returns the length of the trimmed slice.

### Raw WebAssembly

You can write WebAssembly by hand, or AI coding tools work great too.

The contract looks like:

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

  ;; Required export: run(input_size) -> output_size
  ;; Input is at input_ptr, output goes to output_ptr
  ;; Return length of output written
  (func (export "run") (param i32 $input_size) (result i32)
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

## WebAssembly module contract

### `input_utf8_cap` / `input_bytes_cap`

Use `input_utf8_cap` for UTF-8 text input and `input_bytes_cap` for binary input.

### `output_utf8_cap` / `output_bytes_cap`

Use `output_utf8_cap` for UTF-8 text output and `output_bytes_cap` for binary output.

If omitted, then the return value of `run` is used as the result.

If exported, then the return value of `run` is used as the size of the output.
