import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

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
  assert.ok(exports.commit() >= 0n);
  const outputPtr = readI32Export(exports, "output_ptr");
  return decoder.decode(new Uint8Array(exports.memory.buffer, outputPtr, outputLen));
}

test("luhn rejects invalid input and recovers on the same instance", async () => {
  const { instance } = await WebAssembly.instantiate(
    await readFile("components/utf8/luhn.wasm"),
    {},
  );
  const exports = instance.exports;

  for (const invalid of ["", "   ", "4", "49927398717", "49927398x16", "4992\t7398716"]) {
    const inputLen = writeInput(exports, invalid);
    assert.equal(exports.render(inputLen), 0);
    assert.ok(exports.commit() < 0n);
  }

  assert.equal(renderText(exports, " 4992-7398 716 "), "49927398716");
  assert.equal(readI32Export(exports, "input_ptr"), readI32Export(exports, "output_ptr"));
});
