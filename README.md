# qip

Pockets of safe determinism in a probabilistic, generative world.

Run quarantined immutable portable WebAssembly modules from the web.

- **Quarantined** with sandbox isolated from the host.
- **Immutable** with SHA256 digest checked for integrity before execution.
- **Portable** WebAssembly modules that run identically on every platform.

## Install

```
brew install qip
```

## Usage

```bash
echo "abc" | piq run qip.dev@<hash>
# Returns CRC of "abc": 1200128334
cat README.md | piq run qip.dev@<hash>
piq get qip.dev@<hash> > crc32.wasm
cat README.md | piq run ./crc32.wasm
```

## Making modules

There are a few recommended way to write a module to work with qip: raw WebAssembly, C, or Zig.

### LLM generated WebAssembly

You can write WebAssembly by hand, but with coding tools becoming more capable.

The contract looks like:

```wasm
(module $YourModule
;; Memory must be exported with name "memory"
  ;; At least 3 pages needed: input at 0x10000, output at 0x20000
  (memory (export "memory") 3)

  ;; Required globals for qip integration
  (global $input_ptr (export "input_ptr") i32 (i32.const 0x10000))
  (global $input_cap (export "input_cap") i32 (i32.const 0x10000))
  (global $output_ptr (export "output_ptr") i32 (i32.const 0x20000))
  (global $output_cap (export "output_cap") i32 (i32.const 0x10000))

  ;; Required export: run(input_size) -> output_size
  ;; Input is at input_ptr, output goes to output_ptr
  ;; Return 0 for no output, or the length of output written
  (func (export "run") (param i32 $input_size) (result i32)
    ;; Write "Hello, World" as i64 + i32
    ;; "Hello, W" as i64 (little-endian: 0x57202c6f6c6c6548)
    (i64.store (global.get $output_ptr) (i64.const 0x57202c6f6c6c6548))
    ;; "orld" as i32 (little-endian: 0x646c726f)
    (i32.store (i32.add (global.get $output_ptr) (i32.const 8)) (i32.const 0x646c726f))
    ;; Return size of output: 12 UTF-8 bytes
    (i32.const 12)
  )
)
```

### C

```c
uint32_t run(uint32_t input_size) {
    // Your program
}
```

### Zig

```zig
// TODO
```

## WebAssembly module exports

### `output_cap`

If omitted, then the return value of `run` is used as the result.

If exported, then the return value of `run` is used as the size of the output.
