import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("base64 encoder fits and returns its maximum advertised input", async () => {
  const { instance } = await WebAssembly.instantiate(
    await readFile("components/bytes/base64-encode.wasm"),
    {},
  );
  const wasm = instance.exports;
  const inputSize = wasm.input_bytes_cap();
  const expectedSize = 4 * Math.ceil(inputSize / 3);
  assert.equal(wasm.output_utf8_cap(), expectedSize);

  const input = new Uint8Array(wasm.memory.buffer, wasm.input_ptr(), inputSize);
  for (let i = 0; i < input.length; i += 1) input[i] = i & 0xff;

  const outputSize = wasm.render(inputSize);
  assert.equal(outputSize, expectedSize);
  const output = Buffer.from(
    new Uint8Array(wasm.memory.buffer, wasm.output_ptr(), outputSize),
  );
  assert.equal(output.toString(), Buffer.from(input).toString("base64"));
  assert.throws(() => wasm.render(inputSize + 1), WebAssembly.RuntimeError);
});

test("CRC-32 has fixed output and does not retain render state", async () => {
  const { instance } = await WebAssembly.instantiate(
    await readFile("components/bytes/crc32-hex.wasm"),
    {},
  );
  const wasm = instance.exports;
  const input = new Uint8Array(wasm.memory.buffer, wasm.input_ptr(), 3);
  input.set(Buffer.from("abc"));

  assert.equal(wasm.render(3), 8);
  const first = Buffer.from(
    new Uint8Array(wasm.memory.buffer, wasm.output_ptr(), 8),
  ).toString();
  assert.equal(first, "352441c2");

  assert.equal(wasm.render(0), 8);
  assert.equal(
    Buffer.from(
      new Uint8Array(wasm.memory.buffer, wasm.output_ptr(), 8),
    ).toString(),
    "00000000",
  );

  input.set(Buffer.from("abc"));
  assert.equal(wasm.render(3), 8);
  assert.equal(
    Buffer.from(
      new Uint8Array(wasm.memory.buffer, wasm.output_ptr(), 8),
    ).toString(),
    first,
  );
  assert.throws(
    () => wasm.render(wasm.input_bytes_cap() + 1),
    WebAssembly.RuntimeError,
  );
});

test("trim output cannot exceed its maximum input", async () => {
  const { instance } = await WebAssembly.instantiate(
    await readFile("components/utf8/trim.wasm"),
    {},
  );
  const wasm = instance.exports;
  const inputSize = wasm.input_utf8_cap();
  assert.equal(wasm.output_utf8_cap(), inputSize);

  const input = new Uint8Array(wasm.memory.buffer, wasm.input_ptr(), inputSize);
  input.fill(0x78);
  assert.equal(wasm.render(inputSize), inputSize);

  const output = new Uint8Array(
    wasm.memory.buffer,
    wasm.output_ptr(),
    inputSize,
  );
  assert.equal(output[0], 0x78);
  assert.equal(output[output.length - 1], 0x78);
  assert.throws(() => wasm.render(inputSize + 1), WebAssembly.RuntimeError);
});
