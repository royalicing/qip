import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { access, writeFile, readFile, mkdtemp } from "node:fs/promises";
import { constants } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import zlib from "node:zlib";

const execFileP = promisify(execFile);

const qip = fileURLToPath(new URL("../qip", import.meta.url));
const bmpToPng = fileURLToPath(new URL("../components/image/bmp/bmp-to-png.wasm", import.meta.url));
const pngToBmp = fileURLToPath(new URL("../components/image/png/png-to-bmp.wasm", import.meta.url));

async function ensurePrerequisites(t) {
  try {
    await access(qip, constants.X_OK);
    await access(bmpToPng, constants.R_OK);
    await access(pngToBmp, constants.R_OK);
  } catch {
    t.skip("build ./qip and components first");
  }
}

function buildBMP(width, height, pixelAt) {
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
      // bottom-up rows, BGRA bytes
      const [r, g, b, a] = pixelAt(x, height - 1 - y);
      bmp.set([b, g, r, a], 54 + y * stride + x * 4);
    }
  }
  return bmp;
}

async function runPipeline(modules, inputPath, outputPath) {
  await execFileP(qip, ["run", ...modules, "-i", inputPath, "-o", outputPath]);
  return readFile(outputPath);
}

test("bmp to png emits valid RGBA PNG that round-trips pixel-exact", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-bmp-png-"));
  const width = 37;
  const height = 23;
  const bmp = buildBMP(width, height, (x, y) => [x * 7 & 0xff, y * 11 & 0xff, (x ^ y) & 0xff, 255 - (x & 0x1f)]);
  const bmpPath = join(dir, "in.bmp");
  await writeFile(bmpPath, bmp);

  const png = await runPipeline([bmpToPng], bmpPath, join(dir, "out.png"));
  assert.deepEqual([...png.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
  assert.equal(png.readUInt32BE(16), width);
  assert.equal(png.readUInt32BE(20), height);
  assert.equal(png[24], 8, "bit depth");
  assert.equal(png[25], 6, "color type RGBA");

  // Full round trip back through the decoder must reproduce the pixels.
  const back = await runPipeline([bmpToPng, pngToBmp], bmpPath, join(dir, "back.bmp"));
  assert.deepEqual(back.subarray(54), bmp.subarray(54), "pixel data differs after round trip");
  assert.equal(back.readUInt16LE(28), 32);
});

test("png IDAT inflates to correctly filtered scanlines", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-bmp-png-"));
  const bmp = buildBMP(16, 4, (x, y) => [x * 16, y * 60, 128, 255]);
  const bmpPath = join(dir, "in.bmp");
  await writeFile(bmpPath, bmp);
  const png = await runPipeline([bmpToPng], bmpPath, join(dir, "out.png"));

  let pos = 8;
  let idat = Buffer.alloc(0);
  while (pos + 12 <= png.length) {
    const len = png.readUInt32BE(pos);
    const type = png.subarray(pos + 4, pos + 8).toString("ascii");
    if (type === "IDAT") {
      idat = Buffer.concat([idat, png.subarray(pos + 8, pos + 8 + len)]);
    }
    pos += 12 + len;
  }
  const raw = zlib.inflateSync(idat);
  assert.equal(raw.length, (1 + 16 * 4) * 4, "one filter byte plus RGBA per row");
  for (let y = 0; y < 4; y += 1) {
    assert.ok(raw[y * (1 + 64)] <= 4, "valid filter type per scanline");
  }
});

test("png to bmp rejects a corrupted chunk CRC", async (t) => {
  await ensurePrerequisites(t);
  const dir = await mkdtemp(join(tmpdir(), "qip-bmp-png-"));
  const bmpPath = join(dir, "in.bmp");
  await writeFile(bmpPath, buildBMP(8, 8, (x, y) => [x * 30, y * 30, 0, 255]));
  const png = await runPipeline([bmpToPng], bmpPath, join(dir, "out.png"));

  png[png.length - 20] ^= 0xff; // corrupt inside the IDAT chunk
  const badPath = join(dir, "bad.png");
  await writeFile(badPath, png);

  const outPath = join(dir, "bad.bmp");
  await execFileP(qip, ["run", pngToBmp, "-i", badPath, "-o", outPath]);
  const out = await readFile(outPath);
  assert.equal(out.length, 0, "corrupted PNG must produce no output");
});
