#!/usr/bin/env bash
set -euo pipefail

INPUT=${INPUT:-../../README.md}
QIP=${QIP:-../../qip}
WARMUP_RUNS=${WARMUP_RUNS:-5}
RUNS=${RUNS:-20}
INNER_LOOPS=${INNER_LOOPS:-1}

if ! command -v hyperfine >/dev/null 2>&1; then
  echo "hyperfine not found" >&2
  exit 1
fi

if [[ ! -f "$INPUT" ]]; then
  echo "missing input: $INPUT" >&2
  exit 1
fi

if [[ ! -x "$QIP" ]]; then
  echo "missing qip binary: $QIP" >&2
  exit 1
fi

INPUT_ABS=$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")
QIP_ABS=$(cd "$(dirname "$QIP")" && pwd)/$(basename "$QIP")

INPUT="$INPUT" QIP="$QIP" ./verify.sh

CMDS=()
NAMES=()

add_cmd() {
  NAMES+=("$1")
  CMDS+=("$2")
}

bench_cmd() {
  local raw="$1"
  if [[ "$INNER_LOOPS" -le 1 ]]; then
    printf "%s > /dev/null" "$raw"
    return
  fi
  printf "for i in \$(seq 1 %s); do %s > /dev/null; done" "$INNER_LOOPS" "$raw"
}

add_cmd "zig-simple" "$(bench_cmd "./wordcount_simple.zig.bin < '$INPUT_ABS'")"
add_cmd "zig-optimized" "$(bench_cmd "./wordcount_optimized.zig.bin < '$INPUT_ABS'")"
add_cmd "c-simple" "$(bench_cmd "./wordcount_simple.c.bin < '$INPUT_ABS'")"
add_cmd "c-optimized" "$(bench_cmd "./wordcount_optimized.c.bin < '$INPUT_ABS'")"
add_cmd "go-simple" "$(bench_cmd "./wordcount_simple.go.bin < '$INPUT_ABS'")"
add_cmd "go-optimized" "$(bench_cmd "./wordcount_optimized.go.bin < '$INPUT_ABS'")"
if command -v node >/dev/null 2>&1; then
  add_cmd "node-simple" "$(bench_cmd "node ./wordcount_simple.mjs < '$INPUT_ABS'")"
  add_cmd "node-optimized" "$(bench_cmd "node ./wordcount_optimized.mjs < '$INPUT_ABS'")"
  add_cmd "node-wasm-zig" "$(bench_cmd "node ./wordcount_wasm_runner.mjs ./wordcount_zig_wasm.wasm < '$INPUT_ABS'")"
  add_cmd "node-wasm-c" "$(bench_cmd "node ./wordcount_wasm_runner.mjs ./wordcount_c_wasm.wasm < '$INPUT_ABS'")"
fi
add_cmd "qip-wasm-zig" "$(bench_cmd "'$QIP_ABS' run --timeout-ms 5000 -i '$INPUT_ABS' ./wordcount_zig_wasm.wasm")"
add_cmd "qip-wasm-c" "$(bench_cmd "'$QIP_ABS' run --timeout-ms 5000 -i '$INPUT_ABS' ./wordcount_c_wasm.wasm")"

if command -v bun >/dev/null 2>&1; then
  add_cmd "bun-simple" "$(bench_cmd "bun ./wordcount_simple.mjs < '$INPUT_ABS'")"
  add_cmd "bun-optimized" "$(bench_cmd "bun ./wordcount_optimized.mjs < '$INPUT_ABS'")"
  add_cmd "bun-wasm-zig" "$(bench_cmd "bun ./wordcount_wasm_runner.mjs ./wordcount_zig_wasm.wasm < '$INPUT_ABS'")"
  add_cmd "bun-wasm-c" "$(bench_cmd "bun ./wordcount_wasm_runner.mjs ./wordcount_c_wasm.wasm < '$INPUT_ABS'")"
fi

if command -v deno >/dev/null 2>&1; then
  add_cmd "deno-simple" "$(bench_cmd "deno run -A ./wordcount_simple.mjs < '$INPUT_ABS'")"
  add_cmd "deno-optimized" "$(bench_cmd "deno run -A ./wordcount_optimized.mjs < '$INPUT_ABS'")"
  add_cmd "deno-wasm-zig" "$(bench_cmd "deno run -A ./wordcount_wasm_runner.mjs ./wordcount_zig_wasm.wasm < '$INPUT_ABS'")"
  add_cmd "deno-wasm-c" "$(bench_cmd "deno run -A ./wordcount_wasm_runner.mjs ./wordcount_c_wasm.wasm < '$INPUT_ABS'")"
fi

echo "benchmarking ${#CMDS[@]} commands"

if [[ ${#CMDS[@]} -eq 0 ]]; then
  echo "no runnable commands found" >&2
  exit 1
fi

ARGS=()
for i in "${!CMDS[@]}"; do
  ARGS+=("-n" "${NAMES[$i]}" "${CMDS[$i]}")
done

echo "hyperfine settings: warmup=${WARMUP_RUNS} runs=${RUNS} inner_loops=${INNER_LOOPS}"
hyperfine -w "$WARMUP_RUNS" -r "$RUNS" "${ARGS[@]}"
