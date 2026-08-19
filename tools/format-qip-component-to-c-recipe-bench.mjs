#!/usr/bin/env node

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync, realpathSync, statSync } from "node:fs";

const [
  resultsDir,
  trialsArgument,
  inputPath,
  canonicalOutputPath,
  sharedExecutable,
  dedicatedExecutable,
  guardExecutable,
  boundsExecutable,
  qipExecutable,
  nodeExecutable,
  wazeroExecutable,
  ...wasmPaths
] = process.argv.slice(2);

if (
  !wazeroExecutable ||
  wasmPaths.length < 2 ||
  !/^[1-9][0-9]*$/.test(trialsArgument)
) {
  console.error(
    "usage: format-qip-component-to-c-recipe-bench.mjs results trials input output " +
      "shared-exe dedicated-exe guard-exe bounds-exe qip node wazero wasm ...",
  );
  process.exit(2);
}

const trialCount = Number(trialsArgument);

function jsonFile(name) {
  return JSON.parse(readFileSync(`${resultsDir}/${name}`, "utf8"));
}

function mean(values) {
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function trials(prefix) {
  const values = Array.from(
    { length: trialCount },
    (_, index) => jsonFile(`${prefix}-${index + 1}.json`),
  );
  const first = values[0];
  return {
    ...first,
    compile_ms:
      first.compile_ms === undefined
        ? undefined
        : mean(values.map((value) => value.compile_ms)),
    instantiate_ms:
      first.instantiate_ms === undefined
        ? undefined
        : mean(values.map((value) => value.instantiate_ms)),
    initial_rss_bytes: Math.max(
      ...values.map((value) => value.initial_rss_bytes ?? 0),
    ),
    first_rss_bytes: Math.max(
      ...values.map((value) => value.first_rss_bytes ?? 0),
    ),
    final_rss_bytes: Math.max(
      ...values.map((value) => value.final_rss_bytes ?? 0),
    ),
    max_rss_bytes: Math.max(
      ...values.map((value) => value.max_rss_bytes ?? 0),
    ),
    warm_recipe: {
      mean_ms: mean(values.map((value) => value.warm_recipe.mean_ms)),
      p50_ms: mean(values.map((value) => value.warm_recipe.p50_ms)),
      p95_ms: mean(values.map((value) => value.warm_recipe.p95_ms)),
    },
  };
}

function bytes(value) {
  if (value === null || value === undefined) return "—";
  const units = ["B", "KiB", "MiB", "GiB"];
  let number = value;
  let unit = 0;
  while (number >= 1024 && unit < units.length - 1) {
    number /= 1024;
    unit += 1;
  }
  const digits = unit === 0 ? 0 : number >= 100 ? 0 : number >= 10 ? 1 : 2;
  return `${number.toFixed(digits)} ${units[unit]}`;
}

function milliseconds(value) {
  if (value === null || value === undefined) return "—";
  if (value < 0.001) return `${(value * 1e6).toFixed(0)} ns`;
  if (value < 1) return `${(value * 1000).toFixed(1)} µs`;
  return `${value.toFixed(value >= 10 ? 2 : 3)} ms`;
}

function version(command, args) {
  try {
    return execFileSync(command, args, { encoding: "utf8" })
      .trim()
      .split("\n")[0];
  } catch {
    return "unavailable";
  }
}

const canonicalOutput = readFileSync(canonicalOutputPath);
const outputHash = createHash("sha256").update(canonicalOutput).digest("hex");
const input = readFileSync(inputPath);
const wasmBytes = wasmPaths.reduce(
  (total, path) => total + statSync(path).size,
  0,
);

const shared = trials("shared");
const dedicated = trials("dedicated");
const guard = trials("guard");
const bounds = trials("bounds");
const node = trials("node");
const wazero = trials("wazero");

for (const [name, result] of [
  ["Node/V8", node],
  ["QIP/wazero", wazero],
]) {
  if (result.output_sha256 !== outputHash) {
    throw new Error(
      `${name} output ${result.output_sha256} differs from QIP ${outputHash}`,
    );
  }
}

const rows = [
  {
    name: "QIP C, shared workspace",
    result: shared,
    artifact: statSync(sharedExecutable).size,
    runtime: null,
  },
  {
    name: "QIP C, dedicated workspaces",
    result: dedicated,
    artifact: statSync(dedicatedExecutable).size,
    runtime: null,
  },
  {
    name: "WABT wasm2c, guard pages",
    result: guard,
    artifact: statSync(guardExecutable).size,
    runtime: null,
  },
  {
    name: "WABT wasm2c, explicit bounds",
    result: bounds,
    artifact: statSync(boundsExecutable).size,
    runtime: null,
  },
  {
    name: "Node/V8",
    result: node,
    artifact: wasmBytes,
    runtime: statSync(realpathSync(nodeExecutable)).size,
  },
  {
    name: "QIP/wazero, reused instances",
    result: wazero,
    artifact: wasmBytes,
    runtime: statSync(qipExecutable).size,
  },
];

console.log(`Recipe benchmark: ${wasmPaths.length} Content components`);
console.log("");
for (const [index, path] of wasmPaths.entries()) {
  console.log(`${index + 1}. \`${path}\``);
}
console.log("");
console.log(
  `Input: \`${inputPath}\` (${bytes(input.length)}); output: ` +
    `${bytes(canonicalOutput.length)}, SHA-256 \`${outputHash}\`.`,
);
console.log("");
console.log(
  `Tools: ${version(process.env.CC ?? "cc", ["--version"])}, ` +
    `WABT ${version(process.env.WASM2C ?? "wasm2c", ["--version"])}, ` +
    `Node ${process.versions.node} / V8 ${process.versions.v8}.`,
);
console.log("");
console.log(
  "| Implementation | Time mean | vs shared | p50 | p95 | Initial RSS | " +
    "After first recipe | End RSS | linear memory | compiled artifact / payload | " +
    "shared runtime |",
);
console.log("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|");
for (const row of rows) {
  const result = row.result;
  console.log(
    `| ${row.name} | ${milliseconds(result.warm_recipe.mean_ms)} | ` +
      `${(result.warm_recipe.mean_ms / shared.warm_recipe.mean_ms).toFixed(2)}× | ` +
      `${milliseconds(result.warm_recipe.p50_ms)} | ` +
      `${milliseconds(result.warm_recipe.p95_ms)} | ` +
      `${bytes(result.initial_rss_bytes)} | ${bytes(result.first_rss_bytes)} | ` +
      `${bytes(result.final_rss_bytes)} | ${bytes(result.linear_memory_bytes)} | ` +
      `${bytes(row.artifact)} | ${bytes(row.runtime)} |`,
  );
}

console.log("");
console.log("| Runtime | Compile once | Instantiate all steps once |");
console.log("|---|---:|---:|");
console.log(
  `| Node/V8 | ${milliseconds(node.compile_ms)} | ` +
    `${milliseconds(node.instantiate_ms)} |`,
);
console.log(
  `| QIP/wazero | ${milliseconds(wazero.compile_ms)} | ` +
    `${milliseconds(wazero.instantiate_ms)} |`,
);
console.log("");
console.log(
  `Warm values average ${trialCount} trial${trialCount === 1 ? "" : "s"}. ` +
    "Each row reuses initialized process state. The QIP generated-C shared row " +
    "moves each intermediate within one workspace; other runtimes retain one " +
    "linear memory per component. Artifact/payload is a stripped executable for " +
    "translated-C rows and the combined Wasm modules for shared runtimes.",
);
