#!/usr/bin/env bash
set -euo pipefail

INPUT=${INPUT:-../../README.md}
QIP=${QIP:-../../qip}

if [[ ! -f "$INPUT" ]]; then
  echo "missing input: $INPUT" >&2
  exit 1
fi

if [[ ! -x "$QIP" ]]; then
  echo "missing qip binary: $QIP" >&2
  exit 1
fi

run_cmd() {
  local name=$1
  local cmd=$2
  bash -lc "$cmd" > "out.$name.txt"
}

run_cmd zig_simple "./wordcount_simple.zig.bin < '$INPUT'"
run_cmd zig_optimized "./wordcount_optimized.zig.bin < '$INPUT'"
run_cmd c_simple "./wordcount_simple.c.bin < '$INPUT'"
run_cmd c_optimized "./wordcount_optimized.c.bin < '$INPUT'"
run_cmd go_simple "./wordcount_simple.go.bin < '$INPUT'"
run_cmd go_optimized "./wordcount_optimized.go.bin < '$INPUT'"
if command -v node >/dev/null 2>&1; then
  run_cmd node_simple "node ./wordcount_simple.mjs < '$INPUT'"
  run_cmd node_optimized "node ./wordcount_optimized.mjs < '$INPUT'"
  run_cmd node_wasmjs_zig "node ./wordcount_wasm_runner.mjs ./wordcount_zig_wasm.wasm < '$INPUT'"
  run_cmd node_wasmjs_c "node ./wordcount_wasm_runner.mjs ./wordcount_c_wasm.wasm < '$INPUT'"
fi
run_cmd wasm_qip_zig "'$QIP' run --timeout-ms 5000 -i '$INPUT' ./wordcount_zig_wasm.wasm"
run_cmd wasm_qip_c "'$QIP' run --timeout-ms 5000 -i '$INPUT' ./wordcount_c_wasm.wasm"

if command -v bun >/dev/null 2>&1; then
  run_cmd bun_simple "bun ./wordcount_simple.mjs < '$INPUT'"
  run_cmd bun_optimized "bun ./wordcount_optimized.mjs < '$INPUT'"
  run_cmd bun_wasmjs_zig "bun ./wordcount_wasm_runner.mjs ./wordcount_zig_wasm.wasm < '$INPUT'"
  run_cmd bun_wasmjs_c "bun ./wordcount_wasm_runner.mjs ./wordcount_c_wasm.wasm < '$INPUT'"
fi

if command -v deno >/dev/null 2>&1; then
  run_cmd deno_simple "deno run -A ./wordcount_simple.mjs < '$INPUT'"
  run_cmd deno_optimized "deno run -A ./wordcount_optimized.mjs < '$INPUT'"
  run_cmd deno_wasmjs_zig "deno run -A ./wordcount_wasm_runner.mjs ./wordcount_zig_wasm.wasm < '$INPUT'"
  run_cmd deno_wasmjs_c "deno run -A ./wordcount_wasm_runner.mjs ./wordcount_c_wasm.wasm < '$INPUT'"
fi

ref="out.go_simple.txt"
for f in out.*.txt; do
  if ! diff -u "$ref" "$f" >/dev/null; then
    echo "mismatch: $f differs from $ref" >&2
    diff -u "$ref" "$f" || true
    exit 1
  fi
done

echo "all outputs match"
