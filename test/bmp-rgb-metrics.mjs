import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import { constants } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";

const modulePath = fileURLToPath(new URL("../components/image/bmp/bmp-rgb-metrics.wasm", import.meta.url));

function buildBMP(width, height, changed = false) {
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
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const offset = 54 + y * stride + x * 4;
      bmp.set([x * 11 & 0xff, y * 13 & 0xff, (x + y) * 7 & 0xff, 255], offset);
    }
  }
  if (changed) bmp[54 + 5 * stride + 7 * 4 + 2] ^= 0x7f;
  return bmp;
}

async function loadComponent(t) {
  try {
    await access(modulePath, constants.R_OK);
  } catch {
    t.skip("build components first");
    return null;
  }
  const wasm = await readFile(modulePath);
  return (await WebAssembly.instantiate(wasm, {})).instance.exports;
}

function compare(exports, first, second) {
  const input = Buffer.concat([first, second]);
  new Uint8Array(exports.memory.buffer, exports.input_ptr(), input.length).set(input);
  const size = exports.render(input.length);
  assert.ok(size > 0);
  return JSON.parse(Buffer.from(exports.memory.buffer, exports.output_ptr(), size).toString("utf8"));
}

test("bmp RGB metrics report exact identity and finite differences", async (t) => {
  const exports = await loadComponent(t);
  if (!exports) return;
  const reference = buildBMP(16, 16);

  const identical = compare(exports, reference, reference);
  assert.equal(identical.identical, true);
  assert.equal(identical.mse_rgb, 0);
  assert.equal(identical.psnr_rgb_db, null);
  assert.equal(identical.ssim_rgb, 1);

  const changed = compare(exports, reference, buildBMP(16, 16, true));
  assert.equal(changed.identical, false);
  assert.ok(changed.mse_rgb > 0);
  assert.ok(Number.isFinite(changed.psnr_rgb_db));
  assert.ok(changed.ssim_rgb > 0 && changed.ssim_rgb < 1);
});
