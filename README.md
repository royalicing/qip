# `qip`

Pipelines of safe determinism in a probabilistic generative world.

![qip logo](qip-logo.svg)

`qip` lets you compose small modules for text and images. Modules do one thing well and can be piped together to make powerful replayable tools.

- **Quick**: each module does one thing well, and you can quickly make new ones.
- **Isolated**: modules run in a secure sandbox.
- **Portable**: WebAssembly pipelines run identically across platforms.

## Install

```
brew install RoyalIcing/tap/qip
```

## Usage

```bash
# Validate/normalize a fictional movie/TV-style 555 number
echo "+1 (212) 555-0100" | ./qip run examples/e164.wasm
# +12125550100

# Convert WebAssembly purple from RGB to hex
echo "101,79,240" | ./qip run examples/rgb-to-hex.wasm
# #654ff0

# Expand emoji shortcodes
echo "Run :rocket: WebAssembly pipelines identically on any computer :sparkles:" | ./qip run examples/shortcode-to-emoji.wasm
# Run 🚀 WebAssembly pipelines identically on any computer ✨

# Render qip-logo.svg to .ico
./qip run -i qip-logo.svg examples/svg-rasterize.wasm examples/bmp-double.wasm examples/bmp-to-ico.wasm > qip-logo.ico

# Render Switzerland flag svg to .ico
echo '<svg width="32" height="32"><rect width="32" height="32" fill="#d52b1e" /><rect x="13" y="6" width="6" height="20" fill="#ffffff" /><rect x="6" y="13" width="20" height="6" fill="#ffffff" /></svg>' | ./qip run examples/svg-rasterize.wasm examples/bmp-to-ico.wasm > switzerland-flag.ico
```

Dev server

```bash
# Preview this Markdown README as HTML page
qip dev -i README.md -p 4000 -- ./examples/markdown-basic.wasm ./examples/html-page-wrap.wasm

# Preview rendering qip-logo.svg to .ico in browser
qip dev -i qip-logo.svg -p 4001 -- examples/svg-rasterize.wasm examples/bmp-to-ico.wasm
```

---

## Making modules

There are a few recommended way to write a qip module: Zig, C, or even raw WebAssembly text format.

### C

Your C file must return functions that return the buffers pointers and capacity.

```c
// hello-c.c
#include <stdint.h>

// Static memory buffers for input and output
static char input_buffer[65536];   // 64KB
static char output_buffer[65536];  // 64KB

// Export memory pointer functions (qip will call these)
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

// Simple memcpy
static void copy_bytes(char* dest, const char* src, uint32_t n) {
    for (uint32_t i = 0; i < n; i++) {
        dest[i] = src[i];
    }
}

// Main entry point
__attribute__((export_name("run")))
uint32_t run(uint32_t input_size) {
    const char* prefix = "Hello, ";
    copy_bytes(output_buffer, prefix, 7);

    if (input_size > 0) {
        copy_bytes(output_buffer + 7, input_buffer, input_size);
        return 7 + input_size;
    }

    copy_bytes(output_buffer + 7, "World", 5);
    return 12;
}
```

Compile with a WebAssembly-enabled clang:

```bash
zig cc hello-c.c -target wasm32-freestanding -nostdlib -Wl,--no-entry -Wl,--export=run -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_ptr -Wl,--export=output_utf8_cap -O3 -o hello-c.wasm
```

### Zig

Write your module in Zig targeting `wasm32-freestanding`:

```zig
// hello-zig.zig
const std = @import("std");

// Memory layout
const INPUT_CAP: u32 = 0x10000;
const OUTPUT_CAP: u32 = 0x10000;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&output_buf)));
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

// Get input/output slices
fn getInput(size: u32) []u8 {
    return input_buf[0..@as(usize, @intCast(size))];
}

fn getOutput() []u8 {
    return output_buf[0..];
}

// Main entry point
export fn run(input_size: u32) u32 {
    const input = getInput(input_size);
    const output = getOutput();

    // Example: prepend "Hello, " to input
    const prefix = "Hello, ";
    @memcpy(output[0..prefix.len], prefix);

    if (input_size > 0) {
        // Copy input after prefix
        @memcpy(output[prefix.len..][0..input_size], input);
        return prefix.len + input_size;
    } else {
        // Default to "World" if no input
        const default_name = "World";
        @memcpy(output[prefix.len..][0..default_name.len], default_name);
        return prefix.len + default_name.len;
    }
}
```

Compile with:

```bash
zig build-exe hello-zig.zig -target wasm32-freestanding -O ReleaseSmall -fno-entry --export=run --export=input_ptr --export=input_utf8_cap --export=output_ptr --export=output_utf8_cap
```

### LLM generated WebAssembly

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
