# Word Count Comparison

This directory contains comparable word-count programs across runtimes/languages.

Implementations:
- `wordcount_simple.zig` (native Zig)
- `wordcount_optimized.zig` (native Zig)
- `wordcount_zig_wasm.zig` (qip-compatible Zig Wasm module for direct Zig-vs-C Wasm comparison)
- `wordcount_c_wasm.c` (qip-compatible C Wasm module for direct Zig-vs-C Wasm comparison)
- `wordcount_simple.c` (native C)
- `wordcount_optimized.c` (native C)
- `wordcount_simple.go` (native Go)
- `wordcount_optimized.go` (native Go)
- `wordcount_simple.mjs` (Node/Bun/Deno)
- `wordcount_optimized.mjs` (Node/Bun/Deno)
- `wordcount_wasm_runner.mjs` (Node/Bun/Deno host wrapper for `wordcount_zig_wasm.wasm` or `wordcount_c_wasm.wasm`)

## Tokenization and output contract

All implementations must behave identically:

- Word characters are ASCII letters only: `[A-Za-z]`
- Words are lowercased ASCII
- Non-letter characters split words
- Output shows top 10 words by frequency (or fewer if fewer unique words)
- Tie-break by lexical ascending word
- Then print totals

Output format:

```text
<count>\t<word>
...
--
total\t<N>
unique\t<M>
```

## Build

```bash
cd benchmarks/word-count
make build
```

## Verify identical output

```bash
make verify INPUT=../../README.md
```

For larger inputs (for example `moby-dick.txt`), the scripts use a fixed 5000ms timeout for qip Wasm runs:

```bash
make verify INPUT=./moby-dick.txt
```

## Benchmark

```bash
make bench INPUT=../../README.md
```

The benchmark script uses `hyperfine` and only runs commands for runtimes detected on your machine.
It includes both `qip-wasm-zig` and `qip-wasm-c`, plus JS-hosted Wasm variants for Node/Bun/Deno.
You can tune stability with:

```bash
WARMUP_RUNS=5 RUNS=20 INNER_LOOPS=10 make bench INPUT=../../README.md
```

## Memory

```bash
make memory INPUT=../../README.md
```

This reports peak resident set size (`max_rss_mb`) for each runnable implementation.
It relies on OS process metrics (`time` and/or `ps`) and may fail in restricted sandboxes.
