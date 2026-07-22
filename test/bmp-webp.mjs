import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import { constants } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";

const modulePath = fileURLToPath(new URL("../components/image/bmp/bmp-to-webp-lossy.wasm", import.meta.url));

function buildBMP(width, height) {
  const stride = width * 4;
  const bmp = Buffer.alloc(54 + stride * height);
  bmp.write("BM", 0, "ascii");
  bmp.writeUInt32LE(bmp.length, 2);
  bmp.writeUInt32LE(54, 10);
  bmp.writeUInt32LE(40, 14);
  bmp.writeInt32LE(width, 18);
  bmp.writeInt32LE(height, 22);
  bmp.writeUInt16LE(1, 26);
  bmp.writeUInt16LE(32, 28);
  for (let fileY = 0; fileY < height; fileY += 1) {
    const y = height - 1 - fileY;
    for (let x = 0; x < width; x += 1) {
      const offset = 54 + fileY * stride + x * 4;
      bmp[offset] = (x * 13 + y * 3) & 0xff;
      bmp[offset + 1] = (x * 5 + y * 17) & 0xff;
      bmp[offset + 2] = (x * 19 + y * 7) & 0xff;
      bmp[offset + 3] = 255;
    }
  }
  return bmp;
}

function exportedString(exports, ptrName, sizeName) {
  return Buffer.from(exports.memory.buffer, exports[ptrName](), exports[sizeName]()).toString("utf8");
}

test("bmp-to-webp-lossy emits deterministic VP8 with bounded arena telemetry", async (t) => {
  try {
    await access(modulePath, constants.R_OK);
  } catch {
    t.skip("build components first");
    return;
  }

  const wasm = await readFile(modulePath);
  const { instance: { exports } } = await WebAssembly.instantiate(wasm, {});
  exports._initialize?.();

  assert.equal(exports.input_bytes_cap(), 25_000_000 * 4 + 64 * 1024);
  assert.equal(exports.output_bytes_cap(), 32 * 1024 * 1024);
  assert.equal(exportedString(exports, "input_content_type_ptr", "input_content_type_size"), "image/bmp");
  assert.equal(exportedString(exports, "output_content_type_ptr", "output_content_type_size"), "image/webp");
  assert.equal(exports.uniform_set_quality(95), 95);
  assert.equal(exports.uniform_set_method(4), 4);
  assert.equal(exports.uniform_set_sharp_yuv(1), 1);
  assert.equal(exports.uniform_set_low_memory(1), 1);

  const input = buildBMP(64, 48);
  const memory = new Uint8Array(exports.memory.buffer);
  const inputPtr = exports.input_ptr();
  memory.fill(0, inputPtr, inputPtr + 54);
  assert.equal(exports.render(54), 0, "invalid BMP must produce no output");

  memory.set(input, inputPtr);
  const outputSize = exports.render(input.length);
  assert.ok(outputSize > 20);
  const output = Buffer.from(exports.memory.buffer, exports.output_ptr(), outputSize);
  assert.equal(output.subarray(0, 4).toString("ascii"), "RIFF");
  assert.equal(output.subarray(8, 12).toString("ascii"), "WEBP");
  assert.equal(output.subarray(12, 16).toString("ascii"), "VP8 ");
  assert.deepEqual([...output.subarray(23, 26)], [0x9d, 0x01, 0x2a]);
  assert.equal(output.readUInt16LE(26) & 0x3fff, 64);
  assert.equal(output.readUInt16LE(28) & 0x3fff, 48);
  assert.ok(exports.arena_peak_bytes() > 0);
  assert.ok(exports.arena_allocation_count() > 0);
  assert.ok(exports.arena_free_count() > 0);
  assert.equal(exports.arena_free_count(), exports.arena_free_matched_count());
  assert.equal(exports.arena_free_unmatched_count(), 0);
  assert.equal(exports.arena_failed_allocation(), 0);

  const first = Buffer.from(output);
  memory.set(input, inputPtr);
  const secondSize = exports.render(input.length);
  const second = Buffer.from(exports.memory.buffer, exports.output_ptr(), secondSize);
  assert.deepEqual(second, first, "reused instance must encode deterministically");
});
