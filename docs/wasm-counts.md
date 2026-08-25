# Counting A WebAssembly Module

`wasm-counts.wasm` turns a WebAssembly module into deterministic long-form
CSV. It reports factual static counts for comparing builds; it does not assign
a score or decide whether a module is acceptable.

```sh
make -j qip components/application/wasm/wasm-counts.wasm

qip run \
  -i components/text/e164.wasm \
  -- components/application/wasm/wasm-counts.wasm
```

The output has one integer measurement per row:

```csv
metric,value
module_bytes,304
functions_defined,5
functions_imported,0
instructions,75
loops,1
branches,5
simd_instructions,0
```

Rows are always emitted in the same order, including zero values. This makes
the output useful with `diff`, spreadsheets, and databases without treating a
missing row as zero.

## What It Counts

The report covers module structure, functions, control flow, calls, SIMD,
declared memory, data segments, and instructions that can trap directly based
on their operands or bounds.

- `loops` counts structured `loop` instructions.
- `branches` counts `br`, `br_if`, and `br_table` instructions.
- `conditional_branches` counts `if`, `br_if`, and `br_table` instructions.
- `simd_instructions` counts instructions in the SIMD opcode space.
- `v128_types` counts `v128` occurrences in function and global types.
- `potentially_trapping_instructions` combines explicit traps, integer
  division and remainder, trapping float-to-integer conversion, bounded
  memory and table operations, and indirect or reference calls.

The trapping count describes instruction sites, not executions. A load that
is provably in bounds still counts, while an ordinary direct call does not
count merely because its callee might trap.

Memory rows report declared capacity and initial data. They do not measure
allocator use, working set, stack depth, or peak memory; those require running
or instrumenting the module.

## Load It Into SQLite

SQLite's shell can import the output directly:

```sh
qip run -i a.wasm -- components/application/wasm/wasm-counts.wasm > a.csv

sqlite3 counts.db
```

Then use the shell's CSV mode:

```text
.mode csv
.headers on
CREATE TABLE a_counts (metric TEXT PRIMARY KEY, value INTEGER NOT NULL);
.import --skip 1 a.csv a_counts
SELECT * FROM a_counts WHERE metric IN ('loops', 'branches', 'simd_instructions');
```

For comparisons across many modules, add the module name as a column while
loading each file into a shared `(module, metric, value)` table.

## When Not To Use It

Use WABT's `wasm-stats` when you need a full frequency table for every opcode
and immediate value. Use runtime profiling when you need to know which code is
hot or how much memory an execution actually touches. Counts alone do not
predict either result.
