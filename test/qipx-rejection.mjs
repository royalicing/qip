import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import test from "node:test";

import { newComponent, render } from "../npm/qipx/qipx.mjs";

test("qipx accepts and rejects fallible Content renders", async () => {
  const wasm = await readFile("components/utf8/utf8-must-be-valid.wasm");
  const { instance } = await WebAssembly.instantiate(wasm);
  const component = newComponent(instance, { label: "utf8 validator" });

  assert.equal(render(component, "hello").outputString, "hello");
  assert.throws(
    () => render(component, new Uint8Array([0x41, 0xc3, 0x28])),
    /rejected input at input offset 2/,
  );

  // Recoverable rejection leaves the same instance ready for another render.
  assert.equal(render(component, "again").outputString, "again");
});

test("qipx Compliance supports must_reject", () => {
  const run = spawnSync(process.execPath, [
    "npm/qipx/qipx.mjs",
    "comply",
    "components/utf8/utf8-must-be-valid.wasm",
    "--with",
    "compliance/reject-invalid-utf8.wasm",
  ], { encoding: "utf8" });

  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /10 cases/);
  assert.match(run.stdout, /pass=2 fail=0 total=2/);
});
