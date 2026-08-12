#!/usr/bin/env node

import source commonmarkModule from "../components/text/markdown/commonmark.0.31.2.wasm";
import { readFileSync, writeFileSync } from "node:fs";

function exportedI32(exports, name) {
  const value = exports[name];
  if (typeof value !== "function") throw new Error(`Wasm module must export ${name}() -> i32`);
  return value() >>> 0;
}

const input = readFileSync(0);
const instance = new WebAssembly.Instance(commonmarkModule, {});
const exports = instance.exports;
const inputPtr = exportedI32(exports, "input_ptr");
const inputCap = exportedI32(exports, "input_utf8_cap");
if (input.length > inputCap) throw new Error("input exceeds component capacity");
new Uint8Array(exports.memory.buffer, inputPtr, input.length).set(input);
const outputSize = exports.render(input.length) >>> 0;
if (outputSize > exportedI32(exports, "output_utf8_cap")) {
  throw new Error("output exceeds component capacity");
}
const outputPtr = exportedI32(exports, "output_ptr");
writeFileSync(
  1,
  new Uint8Array(exports.memory.buffer, outputPtr, outputSize),
);
