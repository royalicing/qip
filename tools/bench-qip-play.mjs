import fs from "node:fs";
import { webcrypto } from "node:crypto";
import { performance } from "node:perf_hooks";

const paths = process.argv.slice(2);
if (paths.length === 0) {
  console.error("Usage: node tools/bench-qip-play.mjs <module.wasm> [module2.wasm ...]");
  process.exit(2);
}

const warmup = Number(process.env.QIP_PLAY_BENCH_WARMUP || 20);
const runs = Number(process.env.QIP_PLAY_BENCH_RUNS || 120);

function percentile(sorted, p) {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.max(0, Math.ceil(sorted.length * p) - 1));
  return sorted[idx];
}

function mean(values) {
  return values.reduce((acc, n) => acc + n, 0) / values.length;
}

function stddev(values, avg) {
  const variance = values.reduce((acc, n) => {
    const d = n - avg;
    return acc + d * d;
  }, 0) / values.length;
  return Math.sqrt(variance);
}

async function bench(path) {
  const bytes = fs.readFileSync(path);
  const instantiated = await WebAssembly.instantiate(bytes, {});
  const instance = instantiated.instance || instantiated;
  const exports = instance.exports;
  for (const name of [
    "output_ptr",
    "output_rgba8_srgb_bytes",
    "render_width_px",
    "render_height_px",
    "tick",
    "render",
  ]) {
    if (!(name in exports)) throw new Error(`${path}: missing ${name}`);
  }

  exports.tick(0n);
  for (let i = 0; i < warmup; i++) exports.render(0);

  const samples = [];
  for (let i = 0; i < runs; i++) {
    const start = performance.now();
    exports.render(0);
    samples.push(performance.now() - start);
  }
  samples.sort((a, b) => a - b);

  const avg = mean(samples);
  const ptr = Number(exports.output_ptr());
  const len = Number(exports.output_rgba8_srgb_bytes());
  const output = new Uint8Array(exports.memory.buffer, ptr, len);
  const hash = await webcrypto.subtle.digest("SHA-256", output);
  const digest = [...new Uint8Array(hash)].map((n) => n.toString(16).padStart(2, "0")).join("");

  return {
    path,
    bytes: bytes.byteLength,
    width: Number(exports.render_width_px()),
    height: Number(exports.render_height_px()),
    mean: avg,
    stddev: stddev(samples, avg),
    min: samples[0],
    p50: percentile(samples, 0.5),
    p95: percentile(samples, 0.95),
    max: samples[samples.length - 1],
    sha256: digest,
  };
}

const results = [];
for (const path of paths) results.push(await bench(path));

const firstHash = results[0].sha256;
const outputsMatch = results.every((r) => r.sha256 === firstHash);
console.log(outputsMatch ? "qip-play bench: outputs match" : "qip-play bench: outputs differ");
console.log(`  warmup: ${warmup}`);
console.log(`  runs:   ${runs}`);
console.log("");
for (const r of results) {
  console.log(r.path);
  console.log(`  canvas: ${r.width}x${r.height}`);
  console.log(`  wasm:   ${r.bytes} bytes`);
  console.log(`  render: mean ${r.mean.toFixed(3)} ms +/- ${r.stddev.toFixed(3)} ms [min ${r.min.toFixed(3)}, p50 ${r.p50.toFixed(3)}, p95 ${r.p95.toFixed(3)}, max ${r.max.toFixed(3)}]`);
  console.log(`  sha256: ${r.sha256}`);
  console.log("");
}
