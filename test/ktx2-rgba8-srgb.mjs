import { renderSize as qipRenderSize, renderedOutputPointer as qipRenderedOutputPointer } from "./lib/content-component-host.mjs";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { access, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileP = promisify(execFile);
const qip = fileURLToPath(new URL("../qip", import.meta.url));
const bmpToRgba8 = fileURLToPath(new URL("../components/image/bmp/bmp-b8g8r8a8-srgb-to-ktx2-r8g8b8a8-srgb.wasm", import.meta.url));
const rgba8ToBmp = fileURLToPath(new URL("../components/image/ktx2/ktx2-r8g8b8a8-srgb-to-bmp-b8g8r8a8-srgb.wasm", import.meta.url));
const rgba8ToFloat = fileURLToPath(new URL("../components/image/ktx2/ktx2-r8g8b8a8-srgb-to-ktx2-rgba32float.wasm", import.meta.url));
const floatToRgba8 = fileURLToPath(new URL("../components/image/ktx2/ktx2-rgba32float-to-ktx2-r8g8b8a8-srgb.wasm", import.meta.url));

const modules = [bmpToRgba8, rgba8ToBmp, rgba8ToFloat, floatToRgba8];

async function ensurePrerequisites(t) {
  try {
    await access(qip, constants.X_OK);
    for (const module of modules) await access(module, constants.R_OK);
  } catch {
    t.skip("build ./qip and the RGBA8 sRGB KTX2 components first");
  }
}

function buildBMP(width, height, pixelAt, topDown = false) {
  const bmp = Buffer.alloc(54 + width * height * 4);
  bmp.write("BM", 0, "ascii");
  bmp.writeUInt32LE(bmp.length, 2);
  bmp.writeUInt32LE(54, 10);
  bmp.writeUInt32LE(40, 14);
  bmp.writeInt32LE(width, 18);
  bmp.writeInt32LE(topDown ? -height : height, 22);
  bmp.writeUInt16LE(1, 26);
  bmp.writeUInt16LE(32, 28);
  for (let y = 0; y < height; y += 1) {
    const storedY = topDown ? y : height - 1 - y;
    for (let x = 0; x < width; x += 1) {
      const [r, g, b, a] = pixelAt(x, y);
      bmp.set([b, g, r, a], 54 + (storedY * width + x) * 4);
    }
  }
  return bmp;
}

function logicalRgba(bmp) {
  const width = bmp.readInt32LE(18);
  const signedHeight = bmp.readInt32LE(22);
  const height = Math.abs(signedHeight);
  const result = [];
  for (let y = 0; y < height; y += 1) {
    const storedY = signedHeight < 0 ? y : height - 1 - y;
    for (let x = 0; x < width; x += 1) {
      const p = 54 + (storedY * width + x) * 4;
      result.push(bmp[p + 2], bmp[p + 1], bmp[p], bmp[p + 3]);
    }
  }
  return result;
}

async function runPipeline(pipeline, inputPath, outputPath) {
  await execFileP(qip, ["run", ...pipeline, "-i", inputPath, "-o", outputPath]);
  return readFile(outputPath);
}

test("BMP converts to canonical VK_FORMAT_R8G8B8A8_SRGB KTX2", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-ktx2-rgba8-"));
  const bmp = buildBMP(3, 2, (x, y) => [20 + x * 61, 30 + y * 83, 40 + x * 7 + y * 13, 50 + x * 31]);
  const input = join(dir, "in.bmp");
  await writeFile(input, bmp);
  const ktx = await runPipeline([bmpToRgba8], input, join(dir, "out.ktx2"));

  assert.equal(ktx.readUInt32LE(12), 43, "VK_FORMAT_R8G8B8A8_SRGB");
  assert.equal(ktx.readUInt32LE(16), 1);
  assert.equal(ktx[118], 2, "KHR_DF_TRANSFER_SRGB");
  assert.equal(ktx[135], 0, "first DFD sample is red");
  assert.equal(Number(ktx.readBigUInt64LE(80)), 224);
  assert.equal(ktx.subarray(215, 218).toString("ascii"), "rd\0");
  assert.deepEqual([...ktx.subarray(224)], logicalRgba(bmp));
});

test("RGBA8 KTX2 round trips BMP pixels and both BMP row orders", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-ktx2-rgba8-bmp-"));
  for (const topDown of [false, true]) {
    const bmp = buildBMP(19, 7, (x, y) => [x * 13, y * 37, (x * 17 + y * 19) & 255, (x * 23 + y * 29) & 255], topDown);
    const input = join(dir, `${topDown ? "top" : "bottom"}.bmp`);
    await writeFile(input, bmp);
    const output = await runPipeline([bmpToRgba8, rgba8ToBmp], input, join(dir, `${topDown ? "top" : "bottom"}-out.bmp`));
    assert.deepEqual(logicalRgba(output), logicalRgba(bmp));
  }
});

test("RGBA8 to RGBA32F to RGBA8 is byte-exact", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-ktx2-rgba8-float-"));
  const bmp = buildBMP(17, 9, (x, y) => [x * 15, y * 29, (x * 7 + y * 13) & 255, (x * 19 + y * 5) & 255]);
  const input = join(dir, "in.bmp");
  await writeFile(input, bmp);
  const original = await runPipeline([bmpToRgba8], input, join(dir, "original.ktx2"));
  const roundTrip = await runPipeline([rgba8ToFloat, floatToRgba8], join(dir, "original.ktx2"), join(dir, "round-trip.ktx2"));
  assert.deepEqual(roundTrip, original);
});

test("KTX2 bit-depth converters use one in-place buffer", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-ktx2-in-place-"));
  const bmpPath = join(dir, "in.bmp");
  await writeFile(bmpPath, buildBMP(1, 1, () => [64, 96, 128, 255]));
  const rgba8 = await runPipeline([bmpToRgba8], bmpPath, join(dir, "rgba8.ktx2"));
  const rgba32 = await runPipeline([rgba8ToFloat], join(dir, "rgba8.ktx2"), join(dir, "rgba32.ktx2"));
  for (const [module, input] of [[rgba8ToFloat, rgba8], [floatToRgba8, rgba32]]) {
    const bytes = await readFile(module);
    const { instance } = await WebAssembly.instantiate(bytes, {});
    new Uint8Array(instance.exports.memory.buffer, instance.exports.input_ptr(), input.length).set(input);
    qipRenderSize(instance.exports, input.length);
    assert.equal(instance.exports.input_ptr(), qipRenderedOutputPointer(instance.exports));
    assert.equal(instance.exports.input_bytes_cap(), instance.exports.output_bytes_cap());
  }
});

test("RGBA8 decoder rejects BGRA8 and non-rd profiles", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-ktx2-rgba8-invalid-"));
  const bmpPath = join(dir, "in.bmp");
  await writeFile(bmpPath, buildBMP(1, 1, () => [80, 90, 100, 110]));
  const canonical = await runPipeline([bmpToRgba8], bmpPath, join(dir, "valid.ktx2"));

  const bgra = Buffer.from(canonical);
  bgra.writeUInt32LE(50, 12);
  await writeFile(join(dir, "bgra.ktx2"), bgra);
  await assert.rejects(execFileP(qip, ["run", rgba8ToBmp, "-i", join(dir, "bgra.ktx2"), "-o", join(dir, "out.bmp")]));

  const ru = Buffer.from(canonical);
  ru[216] = "u".charCodeAt(0);
  await writeFile(join(dir, "ru.ktx2"), ru);
  await assert.rejects(execFileP(qip, ["run", rgba8ToFloat, "-i", join(dir, "ru.ktx2"), "-o", join(dir, "out.ktx2")]));
});
