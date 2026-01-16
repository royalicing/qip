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
(func (export "run") (param i32 $input_size) (result i32))
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
