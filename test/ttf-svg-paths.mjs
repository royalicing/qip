import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";

const execFileAsync = promisify(execFile);
const root = process.cwd();
const qip = join(root, "qip");
const fixture = join(
  root,
  "fixtures/dejavu-fonts-ttf-2.37/ttf/DejaVuSans.ttf",
);
const csvComponent = join(
  root,
  "components/font/ttf/ttf-to-svg-paths-csv.wasm",
);
const defsComponent = join(
  root,
  "components/font/ttf/ttf-to-svg-path-defs.wasm",
);

async function convert(component, first, last) {
  const { stdout } = await execFileAsync(qip, [
    "run",
    "-i",
    fixture,
    "--",
    component,
    `?first_codepoint=${first}&last_codepoint=${last}`,
  ]);
  return stdout;
}

test("extracts a proportional glyph as SVG path CSV", async () => {
  const csv = await convert(csvComponent, 65, 65);
  const lines = csv.trimEnd().split("\n");
  assert.equal(lines.length, 2);
  assert.match(lines[0], /^codepoint,hex,glyph_id,advance_x,/);
  assert.match(lines[1], /^65,U\+0041,36,1401,16,/);
  assert.match(lines[1], /,"M [^"]+ Z"$/);
});

test("resolves a compound glyph and gives its SVG path a codepoint ID", async () => {
  const svg = await convert(defsComponent, 0x00e9, 0x00e9);
  assert.match(svg, /^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg"/);
  assert.match(svg, /<path id="u-00E9" data-codepoint="U\+00E9"/);
  assert.match(svg, / d="M [^"]+ Z"\/>/);
  assert.equal((svg.match(/<path /g) ?? []).length, 1);
  assert.match(svg.trimEnd(), /<\/defs><\/svg>$/);
});

test("rejects a codepoint range above the fixed limit", async () => {
  await assert.rejects(convert(csvComponent, 0, 4096));
});
