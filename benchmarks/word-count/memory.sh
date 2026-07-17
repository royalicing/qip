#!/usr/bin/env bash
set -euo pipefail

INPUT=${INPUT:-../../README.md}
QIP=${QIP:-../../qip}
TIME_BIN=${TIME_BIN:-/usr/bin/time}

if [[ ! -f "$INPUT" ]]; then
  echo "missing input: $INPUT" >&2
  exit 1
fi

if [[ ! -x "$QIP" ]]; then
  echo "missing qip binary: $QIP" >&2
  exit 1
fi

TIME_MODE=""
TIME_ARGS=()
if [[ -x "$TIME_BIN" ]]; then
  true_bin=$(command -v true || true)
  if [[ -n "$true_bin" ]] && "$TIME_BIN" -l "$true_bin" >/dev/null 2>&1; then
    TIME_MODE="bsd"
    TIME_ARGS=(-l)
  elif [[ -n "$true_bin" ]] && "$TIME_BIN" -v "$true_bin" >/dev/null 2>&1; then
    TIME_MODE="gnu"
    TIME_ARGS=(-v)
  fi
fi

INPUT_ABS=$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")
QIP_ABS=$(cd "$(dirname "$QIP")" && pwd)/$(basename "$QIP")

CMDS=()
NAMES=()

add_cmd() {
  NAMES+=("$1")
  CMDS+=("$2")
}

measure_rss_bytes() {
  local raw="$1"
  local rss=""
  local rss_bytes=""

  if [[ -n "$TIME_MODE" ]]; then
    local tmp
    tmp=$(mktemp)
    if "$TIME_BIN" "${TIME_ARGS[@]}" bash -lc "$raw > /dev/null" 2>"$tmp"; then
      rss=$(awk '
        BEGIN { val = "" }
        tolower($0) ~ /maximum resident set size/ {
          for (i = 1; i <= NF; i++) {
            t = $i
            gsub(/[^0-9]/, "", t)
            if (t ~ /^[0-9]+$/ && t != "") {
              val = t
            }
          }
        }
        END {
          if (val != "") {
            print val
          }
        }
      ' "$tmp")
    else
      rm -f "$tmp"
      return 1
    fi
    rm -f "$tmp"
  fi

  if [[ -n "$rss" ]]; then
    if [[ "$TIME_MODE" == "bsd" ]]; then
      rss_bytes="$rss"
    else
      rss_bytes=$((rss * 1024))
    fi
    printf "%s" "$rss_bytes"
    return 0
  fi

  local pid
  local max_rss_kb=0
  local sample
  local pid_csv
  local children_csv
  local child
  local loops=5

  bash -lc "for _qip_mem_i in \$(seq 1 $loops); do $raw > /dev/null; done" &
  pid=$!
  while true; do
    pid_csv="$pid"
    children_csv=$(pgrep -P "$pid" 2>/dev/null | paste -sd, - || true)
    if [[ -n "$children_csv" ]]; then
      pid_csv="$pid,$children_csv"
    fi
    while IFS= read -r sample; do
      sample=$(echo "$sample" | tr -d '[:space:]')
      if [[ "$sample" =~ ^[0-9]+$ ]] && (( sample > max_rss_kb )); then
        max_rss_kb=$sample
      fi
    done < <(ps -o rss= -p "$pid_csv" 2>/dev/null || true)

    if [[ -n "$children_csv" ]]; then
      for child in ${children_csv//,/ }; do
        while IFS= read -r sample; do
          sample=$(echo "$sample" | tr -d '[:space:]')
          if [[ "$sample" =~ ^[0-9]+$ ]] && (( sample > max_rss_kb )); then
            max_rss_kb=$sample
          fi
        done < <(ps -o rss= -p "$(pgrep -P "$child" 2>/dev/null | paste -sd, -)" 2>/dev/null || true)
      done
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.005
  done

  if ! wait "$pid"; then
    return 1
  fi
  if (( max_rss_kb <= 0 )); then
    return 1
  fi
  printf "%s" "$((max_rss_kb * 1024))"
}

add_cmd "zig-simple" "./wordcount_simple.zig.bin < '$INPUT_ABS'"
add_cmd "zig-optimized" "./wordcount_optimized.zig.bin < '$INPUT_ABS'"
add_cmd "c-simple" "./wordcount_simple.c.bin < '$INPUT_ABS'"
add_cmd "c-optimized" "./wordcount_optimized.c.bin < '$INPUT_ABS'"
add_cmd "go-simple" "./wordcount_simple.go.bin < '$INPUT_ABS'"
add_cmd "go-optimized" "./wordcount_optimized.go.bin < '$INPUT_ABS'"
if command -v node >/dev/null 2>&1; then
  add_cmd "node-simple" "node ./wordcount_simple.mjs < '$INPUT_ABS'"
  add_cmd "node-optimized" "node ./wordcount_optimized.mjs < '$INPUT_ABS'"
  add_cmd "node-wasm-zig" "node ./wordcount_wasm_runner.mjs ./wordcount_zig_wasm.wasm < '$INPUT_ABS'"
  add_cmd "node-wasm-c" "node ./wordcount_wasm_runner.mjs ./wordcount_c_wasm.wasm < '$INPUT_ABS'"
fi
add_cmd "qip-wasm-zig" "'$QIP_ABS' run --timeout-ms 5000 -i '$INPUT_ABS' ./wordcount_zig_wasm.wasm"
add_cmd "qip-wasm-c" "'$QIP_ABS' run --timeout-ms 5000 -i '$INPUT_ABS' ./wordcount_c_wasm.wasm"

if command -v bun >/dev/null 2>&1; then
  add_cmd "bun-simple" "bun ./wordcount_simple.mjs < '$INPUT_ABS'"
  add_cmd "bun-optimized" "bun ./wordcount_optimized.mjs < '$INPUT_ABS'"
  add_cmd "bun-wasm-zig" "bun ./wordcount_wasm_runner.mjs ./wordcount_zig_wasm.wasm < '$INPUT_ABS'"
  add_cmd "bun-wasm-c" "bun ./wordcount_wasm_runner.mjs ./wordcount_c_wasm.wasm < '$INPUT_ABS'"
fi

if command -v deno >/dev/null 2>&1; then
  add_cmd "deno-simple" "deno run -A ./wordcount_simple.mjs < '$INPUT_ABS'"
  add_cmd "deno-optimized" "deno run -A ./wordcount_optimized.mjs < '$INPUT_ABS'"
  add_cmd "deno-wasm-zig" "deno run -A ./wordcount_wasm_runner.mjs ./wordcount_zig_wasm.wasm < '$INPUT_ABS'"
  add_cmd "deno-wasm-c" "deno run -A ./wordcount_wasm_runner.mjs ./wordcount_c_wasm.wasm < '$INPUT_ABS'"
fi

if [[ ${#CMDS[@]} -eq 0 ]]; then
  echo "no runnable commands found" >&2
  exit 1
fi

results_tmp=$(mktemp)
trap 'rm -f "$results_tmp"' EXIT

for i in "${!CMDS[@]}"; do
  if ! rss_bytes=$(measure_rss_bytes "${CMDS[$i]}"); then
    echo "failed to measure max RSS for ${NAMES[$i]} (time/ps unavailable?)" >&2
    exit 1
  fi
  printf "%s\t%s\n" "${NAMES[$i]}" "$rss_bytes" >>"$results_tmp"
done

printf "%-16s %12s\n" "name" "max_rss_mb"
printf "%-16s %12s\n" "----" "----------"
sort -t $'\t' -k2,2n "$results_tmp" | awk -F $'\t' '{ printf "%-16s %12.2f\n", $1, ($2 / 1000000) }'
