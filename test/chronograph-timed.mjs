import { renderSize, renderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const wasm = await readFile("components/interactive/chronograph.wasm");

function instantiate() {
  return new WebAssembly.Instance(new WebAssembly.Module(wasm), {}).exports;
}

function output(exports, size) {
  return new Uint8Array(exports.memory.buffer, renderedOutputPointer(exports), size);
}

function digest(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

test("chronograph exposes a Timed canonical KTX2 component", () => {
  const exports = instantiate();
  assert.equal(exports.input_bytes_cap(), 0);
  assert.equal(typeof exports.begin_update_at, "function");
  assert.equal(typeof exports.finish_update, "function");
  assert.equal(typeof exports.uniform_set_current_seconds, "function");
  assert.equal(exports.key_event, undefined);
  assert.equal(exports.pointer_event, undefined);

  const contentType = new TextDecoder().decode(new Uint8Array(
    exports.memory.buffer,
    exports.output_content_type_ptr(),
    exports.output_content_type_size(),
  ));
  assert.equal(contentType, "image/ktx2");

  assert.ok(Math.abs(exports.uniform_set_current_seconds(75.39) - 15.2) < 0.001);
  const size = renderSize(exports, 0);
  const bytes = output(exports, size);
  const header = new DataView(bytes.buffer, bytes.byteOffset, 104);
  assert.equal(size, 224 + 360 * 360 * 4);
  assert.equal(header.getUint32(12, true), 43);
  assert.equal(header.getUint32(20, true), 360);
  assert.equal(header.getUint32(24, true), 360);
  assert.equal(bytes[224 + 3], 0, "outer background should be transparent");
  assert.equal(bytes[224 + (180 * 360 + 180) * 4 + 3], 255, "dial should remain opaque");
});

test("current_seconds changes the hand and updates publish only through render", () => {
  const exports = instantiate();
  exports.uniform_set_current_seconds(14);
  const size = renderSize(exports, 0);
  const fourteen = digest(output(exports, size));

  exports.begin_update_at(1n);
  exports.uniform_set_current_seconds(14.2);
  assert.equal(exports.finish_update(), 201n);
  assert.equal(digest(output(exports, size)), fourteen);

  assert.equal(renderSize(exports, 0), size);
  const nextStep = digest(output(exports, size));
  assert.notEqual(nextStep, fourteen);

  exports.uniform_set_current_seconds(14.2);
  assert.equal(renderSize(exports, 0), size);
  assert.equal(digest(output(exports, size)), nextStep);
});

test("one clock uniform seeds autonomous Timed updates", () => {
  const exports = instantiate();
  exports.uniform_set_current_seconds(14);
  const size = renderSize(exports, 0);
  const initial = digest(output(exports, size));

  exports.begin_update_at(1n);
  exports.uniform_set_current_seconds(14);
  assert.equal(exports.finish_update(), 201n);
  exports.uniform_set_current_seconds(14);
  assert.equal(renderSize(exports, 0), size);
  assert.equal(digest(output(exports, size)), initial);

  exports.begin_update_at(201n);
  exports.uniform_set_current_seconds(14);
  assert.equal(exports.finish_update(), 401n);
  exports.uniform_set_current_seconds(14);
  assert.equal(renderSize(exports, 0), size);
  assert.notEqual(digest(output(exports, size)), initial);
});

test("chronograph traps on Timed lifecycle misuse", () => {
  const exports = instantiate();
  assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
  renderSize(exports, 0);
  assert.throws(() => exports.finish_update(), WebAssembly.RuntimeError);
  exports.begin_update_at(1n);
  assert.throws(() => renderSize(exports, 0), WebAssembly.RuntimeError);
  assert.equal(exports.finish_update(), 201n);
  assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
});
