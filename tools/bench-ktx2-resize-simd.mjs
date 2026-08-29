#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { basename } from "node:path";
import { cpus } from "node:os";
import { performance } from "node:perf_hooks";

function usage() {
  console.error(
    "Usage: node tools/bench-ktx2-resize-simd.mjs <input.ktx2> <width> <height> <component.wasm> [component.wasm ...]",
  );
  process.exit(2);
}

const [inputPath, widthText, heightText, ...modulePaths] = process.argv.slice(2);
const width = Number(widthText);
const height = Number(heightText);
if (
  !inputPath ||
  modulePaths.length < 2 ||
  !Number.isSafeInteger(width) ||
  width <= 0 ||
  !Number.isSafeInteger(height) ||
  height <= 0
) usage();

const warmupRuns = 10;
const measuredRuns = 30;
const input = readFileSync(inputPath);

function resultParts(bits) {
  const value = BigInt.asUintN(64, bits);
  if ((value & (1n << 63n)) !== 0n) throw new Error("component rejected the resize");
  return {
    size: Number(value & 0xffff_ffffn),
    pointer: Number((value >> 32n) & 0x7fff_ffffn),
  };
}

function createState(path) {
  const exports = new WebAssembly.Instance(
    new WebAssembly.Module(readFileSync(path)),
    {},
  ).exports;
  exports._initialize?.();
  if (
    typeof exports.input_ptr !== "function" ||
    typeof exports.uniform_set_width !== "function" ||
    typeof exports.uniform_set_height !== "function" ||
    typeof exports.render !== "function"
  ) throw new Error(`${path}: missing resize component exports`);
  return { path, exports, samples: [], output: undefined };
}

function render(state) {
  const { exports } = state;
  const started = performance.now();
  new Uint8Array(exports.memory.buffer, exports.input_ptr() >>> 0, input.length).set(input);
  exports.uniform_set_width(width);
  exports.uniform_set_height(height);
  const { pointer, size } = resultParts(exports.render(input.length));
  if (!state.output || state.output.length !== size) state.output = new Uint8Array(size);
  state.output.set(new Uint8Array(exports.memory.buffer, pointer, size));
  return performance.now() - started;
}

function percentile(sorted, fraction) {
  return sorted[Math.ceil(sorted.length * fraction) - 1];
}

const states = modulePaths.map(createState);
for (const state of states) {
  for (let run = 0; run < warmupRuns; run++) render(state);
}
globalThis.gc?.();

let expected;
for (let run = 0; run < measuredRuns; run++) {
  const order = run % 2 === 0 ? states : states.toReversed();
  for (const state of order) {
    state.samples.push(render(state));
    if (!expected) expected = Uint8Array.from(state.output);
    else if (
      state.output.length !== expected.length ||
      !state.output.every((byte, index) => byte === expected[index])
    ) {
      throw new Error(`${state.path}: output differs from the first component`);
    }
  }
}

console.log(`${inputPath}: ${input.length.toLocaleString()} bytes -> ${width}x${height}`);
console.log(`${process.version} / V8 ${process.versions.v8} / ${cpus()[0]?.model ?? "unknown CPU"}`);
console.log(`${warmupRuns} warmup runs, ${measuredRuns} measured runs, reused instances`);
console.log(`Output SHA-256 ${createHash("sha256").update(expected).digest("hex")}`);

for (const state of states) {
  const sorted = state.samples.toSorted((a, b) => a - b);
  const mean = sorted.reduce((total, sample) => total + sample, 0) / sorted.length;
  console.log(
    `${basename(state.path)}\n` +
    `  mean ${mean.toFixed(2)} ms | p50 ${percentile(sorted, 0.5).toFixed(2)} ms | ` +
    `p95 ${percentile(sorted, 0.95).toFixed(2)} ms | min ${sorted[0].toFixed(2)} ms`,
  );
}
