#!/usr/bin/env node

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync, realpathSync, statSync } from "node:fs";

const [
  resultsDir,
  trialsArgument,
  sourcePath,
  wasmPath,
  inputPath,
  nativeFastExecutable,
  nativeSmallExecutable,
  generatedExecutable,
  guardExecutable,
  boundsExecutable,
  qipExecutable,
  nodeExecutable,
] = process.argv.slice(2);

if (!nodeExecutable || !/^[1-9][0-9]*$/.test(trialsArgument)) {
  console.error(
    "usage: format-qip-component-to-c-source-bench.mjs results-dir trials source wasm " +
      "input native-fast-exe native-small-exe generated-exe guard-exe bounds-exe " +
      "qip-exe node-exe",
  );
  process.exit(2);
}

const trialCount = Number(trialsArgument);

function jsonFile(name) {
  return JSON.parse(readFileSync(`${resultsDir}/${name}`, "utf8"));
}

function text(name) {
  return readFileSync(`${resultsDir}/${name}`, "utf8");
}

function durationMs(value) {
  const match = /^([0-9.]+)(ns|µs|us|ms|s)$/.exec(value);
  if (!match) throw new Error(`cannot parse duration ${JSON.stringify(value)}`);
  const number = Number(match[1]);
  return number * { ns: 1e-6, "µs": 1e-3, us: 1e-3, ms: 1, s: 1000 }[
    match[2]
  ];
}

function parseQipBench(report) {
  const time = report.match(
    /Time \(mean ± stddev\): ([0-9.]+(?:ns|µs|us|ms|s)).*?p95: ([0-9.]+(?:ns|µs|us|ms|s))/,
  );
  const breakdown = report.match(
    /Breakdown: run mean ([^,]+), instantiation mean ([^,]+), compile ([^\n]+)/,
  );
  const memory = report.match(
    /Memory allocated: mean ([^,]+), peak ([^\n]+)/,
  );
  if (!time || !breakdown || !memory) {
    throw new Error("could not parse qip bench output");
  }
  return {
    warm_full: {
      mean_ms: durationMs(time[1]),
      p50_ms: null,
      p95_ms: durationMs(time[2]),
    },
    compile_ms: durationMs(breakdown[3].trim()),
    instantiate_ms: durationMs(breakdown[2].trim()),
    run_ms: durationMs(breakdown[1].trim()),
    linear_memory: memory[2].trim(),
  };
}

function mean(values) {
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function trialJson(prefix) {
  const values = Array.from(
    { length: trialCount },
    (_, index) => jsonFile(`${prefix}-${index + 1}.json`),
  );
  const first = values[0];
  return {
    ...first,
    max_rss_bytes: Math.max(...values.map((value) => value.max_rss_bytes ?? 0)),
    process_rss_bytes: Math.max(
      ...values.map((value) => value.process_rss_bytes ?? 0),
    ),
    compile_ms:
      first.compile_ms === undefined
        ? undefined
        : mean(values.map((value) => value.compile_ms)),
    instantiate_ms:
      first.instantiate_ms === undefined
        ? undefined
        : mean(values.map((value) => value.instantiate_ms)),
    warm_full: {
      mean_ms: mean(values.map((value) => value.warm_full.mean_ms)),
      p50_ms: mean(values.map((value) => value.warm_full.p50_ms)),
      p95_ms: mean(values.map((value) => value.warm_full.p95_ms)),
    },
    reset_init_full:
      first.reset_init_full === undefined
        ? undefined
        : {
            mean_ms: mean(
              values.map((value) => value.reset_init_full.mean_ms),
            ),
          },
    cold_instantiate_full:
      first.cold_instantiate_full === undefined
        ? undefined
        : {
            mean_ms: mean(
              values.map((value) => value.cold_instantiate_full.mean_ms),
            ),
          },
  };
}

function trialQipBench() {
  const values = Array.from(
    { length: trialCount },
    (_, index) => parseQipBench(text(`qip-warm-${index + 1}.txt`)),
  );
  return {
    ...values[0],
    compile_ms: mean(values.map((value) => value.compile_ms)),
    instantiate_ms: mean(values.map((value) => value.instantiate_ms)),
    run_ms: mean(values.map((value) => value.run_ms)),
    warm_full: {
      mean_ms: mean(values.map((value) => value.warm_full.mean_ms)),
      p50_ms: null,
      p95_ms: mean(values.map((value) => value.warm_full.p95_ms)),
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

function size(path) {
  return statSync(path).size;
}

function version(command, args) {
  try {
    return execFileSync(command, args, { encoding: "utf8" }).trim().split("\n")[0];
  } catch {
    return "unavailable";
  }
}

const nativeFastWarm = trialJson("native-fast-warm");
const nativeSmallWarm = trialJson("native-small-warm");
const generatedWarm = trialJson("generated-warm");
const guardWarm = trialJson("guard-warm");
const boundsWarm = trialJson("bounds-warm");
const nodeWarm = trialJson("node-warm");
const qipWarm = trialQipBench();

const nativeFastStartup = jsonFile("native-fast-startup.json");
const nativeSmallStartup = jsonFile("native-small-startup.json");
const generatedStartup = jsonFile("generated-startup.json");
const guardStartup = jsonFile("guard-startup.json");
const boundsStartup = jsonFile("bounds-startup.json");
const nodeStartup = jsonFile("node-startup.json");
const qipStartup = jsonFile("qip-startup.json");

const wasmBytes = readFileSync(wasmPath);
const inputBytes = readFileSync(inputPath);
const outputBytes = readFileSync(`${resultsDir}/native-fast-output`);
const outputHash = createHash("sha256").update(outputBytes).digest("hex");
const nativeFastLabel = sourcePath.endsWith(".zig")
  ? "Source → native (`ReleaseFast`)"
  : "Source → native (`-O3`)";
const nativeSmallLabel = sourcePath.endsWith(".zig")
  ? "Source → native (`ReleaseSmall`)"
  : "Source → native (`-Os`)";

const rows = [
  {
    name: nativeFastLabel,
    comparable: true,
    warm: nativeFastWarm,
    startup: nativeFastStartup,
    rss: nativeFastWarm.max_rss_bytes,
    executable: size(nativeFastExecutable),
    wasm: null,
    host: null,
  },
  {
    name: nativeSmallLabel,
    comparable: true,
    warm: nativeSmallWarm,
    startup: nativeSmallStartup,
    rss: nativeSmallWarm.max_rss_bytes,
    executable: size(nativeSmallExecutable),
    wasm: null,
    host: null,
  },
  {
    name: "Wasm → QIP C (bounds + dirty)",
    comparable: true,
    warm: generatedWarm,
    startup: generatedStartup,
    rss: generatedWarm.max_rss_bytes,
    executable: size(generatedExecutable),
    wasm: wasmBytes.length,
    host: null,
  },
  {
    name: "Wasm → wasm2c guard",
    comparable: true,
    warm: guardWarm,
    startup: guardStartup,
    rss: guardWarm.max_rss_bytes,
    executable: size(guardExecutable),
    wasm: wasmBytes.length,
    host: null,
  },
  {
    name: "Wasm → wasm2c bounds",
    comparable: true,
    warm: boundsWarm,
    startup: boundsStartup,
    rss: boundsWarm.max_rss_bytes,
    executable: size(boundsExecutable),
    wasm: wasmBytes.length,
    host: null,
  },
  {
    name: "Wasm → Node/V8",
    comparable: true,
    warm: nodeWarm,
    startup: nodeStartup,
    rss: nodeWarm.process_rss_bytes,
    executable: null,
    wasm: wasmBytes.length,
    host: size(realpathSync(nodeExecutable)),
  },
  {
    name: "Wasm → QIP/wazero",
    comparable: false,
    warm: qipWarm,
    startup: qipStartup,
    rss: null,
    executable: null,
    wasm: wasmBytes.length,
    host: size(qipExecutable),
  },
];

console.log(`Benchmark: \`${sourcePath}\``);
console.log("");
console.log(
  `Input: \`${inputPath}\` (${bytes(inputBytes.length)}); output: ` +
    `${bytes(outputBytes.length)}, SHA-256 \`${outputHash}\`.`,
);
console.log("");
console.log(
  `Tools: Zig ${version(process.env.ZIG ?? "zig", ["version"])}, ` +
    `${version(process.env.CC ?? "cc", ["--version"])}, ` +
    `WABT ${version(process.env.WASM2C ?? "wasm2c", ["--version"])}, ` +
    `Node ${process.versions.node} / V8 ${process.versions.v8}.`,
);
console.log("");
console.log(
  "| Implementation | Warm mean | vs native | p50 | p95 | Warm RSS | " +
    "process startup | startup RSS | compiled artifact | Wasm input/payload | " +
    "shared runtime |",
);
console.log("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|");
for (const row of rows) {
  const ratio = row.comparable
    ? `${(row.warm.warm_full.mean_ms / nativeFastWarm.warm_full.mean_ms).toFixed(2)}×`
    : "—";
  console.log(
    `| ${row.name} | ${milliseconds(row.warm.warm_full.mean_ms)} | ` +
      `${ratio} | ` +
      `${milliseconds(row.warm.warm_full.p50_ms)} | ` +
      `${milliseconds(row.warm.warm_full.p95_ms)} | ${bytes(row.rss)} | ` +
      `${milliseconds(row.startup.mean_ms)} | ` +
      `${bytes(row.startup.mean_max_rss_bytes)} | ${bytes(row.executable)} | ` +
      `${bytes(row.wasm)} | ` +
      `${bytes(row.host)} |`,
  );
}

console.log("");
console.log("Additional lifecycle measurements:");
console.log("");
console.log("| Implementation | compile | instantiate/reset + render | linear memory |");
console.log("|---|---:|---:|---:|");
console.log(
  `| Wasm → QIP C | — | ${milliseconds(generatedWarm.reset_init_full.mean_ms)} | ` +
    `${bytes(generatedWarm.linear_memory_bytes)} |`,
);
console.log(
  `| Wasm → wasm2c guard | — | ${milliseconds(guardWarm.cold_instantiate_full.mean_ms)} | ` +
    `${bytes(guardWarm.linear_memory_bytes)} |`,
);
console.log(
  `| Wasm → wasm2c bounds | — | ${milliseconds(boundsWarm.cold_instantiate_full.mean_ms)} | ` +
    `${bytes(boundsWarm.linear_memory_bytes)} |`,
);
console.log(
  `| Wasm → Node/V8 | ${milliseconds(nodeWarm.compile_ms)} | ` +
    `${milliseconds(nodeWarm.instantiate_ms)} | ${bytes(nodeWarm.linear_memory_bytes)} |`,
);
console.log(
  `| Wasm → QIP/wazero | ${milliseconds(qipWarm.compile_ms)} | ` +
    `${milliseconds(qipWarm.instantiate_ms)} | ${qipWarm.linear_memory} |`,
);
console.log("");
console.log(
  `Warm values average ${trialCount} trial${trialCount === 1 ? "" : "s"}. ` +
  "Compiled executable is the stripped standalone program. Wasm is the AOT " +
    "translation input for generated-C rows and the shipped payload for " +
    "shared-runtime rows. Process startup includes stdin/stdout and a complete " +
    "fresh process. QIP/wazero warm samples intentionally use its normal " +
    "fresh-instance boundary; the other warm rows reuse initialized state.",
);
