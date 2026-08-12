#!/usr/bin/env node

import { readFileSync, writeFileSync } from "node:fs";

const [wasmPath, outputPath] = process.argv.slice(2);
if (!wasmPath || !outputPath) {
  console.error(
    "usage: make-content-node-inline.mjs component.wasm output.mjs",
  );
  process.exit(2);
}

const base64 = readFileSync(wasmPath).toString("base64");
const source = `#!/usr/bin/env node
import { readFileSync, writeFileSync } from "node:fs";

function exportedI32(exports, name) {
  const value = exports[name];
  if (typeof value !== "function") throw new Error(\`Wasm module must export \${name}() -> i32\`);
  return value() >>> 0;
}

const input = readFileSync(0);
const wasm = Buffer.from("${base64}", "base64");
const module = new WebAssembly.Module(wasm);
const instance = new WebAssembly.Instance(module, {});
const exports = instance.exports;
const inputPtr = exportedI32(exports, "input_ptr");
const inputCap = exportedI32(
  exports,
  exports.input_utf8_cap ? "input_utf8_cap" : "input_bytes_cap",
);
if (input.length > inputCap) throw new Error("input exceeds component capacity");
new Uint8Array(exports.memory.buffer, inputPtr, input.length).set(input);
const outputSize = exports.render(input.length) >>> 0;
const outputCap = exportedI32(
  exports,
  exports.output_utf8_cap ? "output_utf8_cap" : "output_bytes_cap",
);
if (outputSize > outputCap) throw new Error("output exceeds component capacity");
const outputPtr = exportedI32(exports, "output_ptr");
writeFileSync(
  1,
  new Uint8Array(exports.memory.buffer, outputPtr, outputSize),
);
`;

writeFileSync(outputPath, source);
