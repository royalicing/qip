import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function readI32Export(exports, name) {
  const value = exports[name];
  return typeof value === "function" ? value() : value.value;
}

function writeInput(exports, text) {
  const bytes = encoder.encode(text);
  const inputPtr = readI32Export(exports, "input_ptr");
  const inputCap = readI32Export(exports, "input_utf8_cap");
  assert.ok(bytes.length <= inputCap);
  new Uint8Array(exports.memory.buffer, inputPtr, bytes.length).set(bytes);
  return bytes.length;
}

function renderText(exports, text) {
  const inputLen = writeInput(exports, text);
  const outputLen = exports.render(inputLen);
  const outputPtr = readI32Export(exports, "output_ptr");
  return decoder.decode(new Uint8Array(exports.memory.buffer, outputPtr, outputLen));
}

test("html-id-validator traps on invalid input and recovers on the same instance", async () => {
  const { instance } = await WebAssembly.instantiate(
    await readFile("modules/text/html/html-id-validator.wasm"),
    {},
  );
  const exports = instance.exports;

  for (const invalid of ["", "   ", "main content"]) {
    const inputLen = writeInput(exports, invalid);
    assert.throws(() => exports.render(inputLen), WebAssembly.RuntimeError);
  }

  assert.equal(renderText(exports, " main-content "), "main-content");
});
