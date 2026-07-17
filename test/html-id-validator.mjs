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

function writeBytes(exports, bytes) {
  const inputPtr = readI32Export(exports, "input_ptr");
  const inputCap = readI32Export(exports, "input_utf8_cap");
  assert.ok(bytes.length <= inputCap);
  new Uint8Array(exports.memory.buffer, inputPtr, bytes.length).set(bytes);
  return bytes.length;
}

async function load(name) {
  return (await WebAssembly.instantiate(
    await readFile(`components/text/html/${name}.wasm`),
    {},
  )).instance.exports;
}

function renderText(exports, text) {
  const inputLen = writeInput(exports, text);
  const outputLen = exports.render(inputLen);
  const outputPtr = readI32Export(exports, "output_ptr");
  return decoder.decode(new Uint8Array(exports.memory.buffer, outputPtr, outputLen));
}

test("html-id-validator traps on invalid input and recovers on the same instance", async () => {
  const exports = await load("html-id-validator");

  for (const invalid of ["", "   ", "main content"]) {
    const inputLen = writeInput(exports, invalid);
    assert.throws(() => exports.render(inputLen), WebAssembly.RuntimeError);
  }

  assert.equal(renderText(exports, "main-content"), "main-content");
  assert.equal(renderText(exports, "main:content"), "main:content");
  assert.equal(renderText(exports, "主要内容"), "主要内容");
});

test("html-input-name-validator accepts the HTML form name syntax", async () => {
  const exports = await load("html-input-name-validator");

  for (const valid of ["full name", "items[0].email", "名前 😀"]) {
    assert.equal(renderText(exports, valid), valid);
  }
  assert.throws(() => exports.render(0), WebAssembly.RuntimeError);
  const invalidUtf8Length = writeBytes(exports, Uint8Array.of(0xc0, 0xaf));
  assert.throws(() => exports.render(invalidUtf8Length), WebAssembly.RuntimeError);
  assert.equal(renderText(exports, "email"), "email");
});

test("html-tag-validator recognizes HTML and valid custom element names", async () => {
  const exports = await load("html-tag-validator");

  for (const builtin of ["div", "DIV", "search", "selectedcontent"]) {
    assert.equal(renderText(exports, builtin), "builtin");
  }
  for (const custom of ["x-widget", "math-α", "emotion-😍"]) {
    assert.equal(renderText(exports, custom), "custom");
  }
  for (const invalid of ["", "frobnicate", "annotation-xml", "X-widget", "x_widget", " x-widget "]) {
    const inputLen = writeInput(exports, invalid);
    assert.throws(() => exports.render(inputLen), WebAssembly.RuntimeError);
  }
  assert.equal(renderText(exports, "button"), "builtin");
});
