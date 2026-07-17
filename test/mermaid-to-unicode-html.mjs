import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { runComplianceComponent } from "./lib/compliance-harness.mjs";

const moduleUrl = new URL(
  "../components/text/vnd.mermaid/mermaid-to-unicode-html.wasm",
  import.meta.url,
);
const complianceUrl = new URL(
  "../compliance/mermaid-to-unicode-html.comply.wasm",
  import.meta.url,
);
const [moduleBytes, complianceBytes] = await Promise.all([
  readFile(moduleUrl),
  readFile(complianceUrl),
]);

function readString(exports, ptrName, sizeName) {
  return Buffer.from(
    exports.memory.buffer,
    exports[ptrName](),
    exports[sizeName](),
  ).toString();
}

function render(exports, input) {
  new Uint8Array(
    exports.memory.buffer,
    exports.input_ptr(),
    input.length,
  ).set(input);
  const outputSize = exports.render(input.length);
  return Buffer.from(
    exports.memory.buffer,
    exports.output_ptr(),
    outputSize,
  );
}

test("declares Mermaid input and HTML output", async () => {
  const { instance } = await WebAssembly.instantiate(moduleBytes);
  assert.equal(
    readString(instance.exports, "input_content_type_ptr", "input_content_type_size"),
    "text/vnd.mermaid",
  );
  assert.equal(
    readString(instance.exports, "output_content_type_ptr", "output_content_type_size"),
    "text/html",
  );
});

test("one instance satisfies every equality case across repeated renders", async () => {
  const { cases } = await runComplianceComponent(complianceBytes);
  const { instance } = await WebAssembly.instantiate(moduleBytes);
  for (const entry of cases.filter((entry) => entry.expected !== null)) {
    assert.deepEqual(render(instance.exports, entry.input), entry.expected);
  }
});

test("invalid UTF-8 traps", async () => {
  const { instance } = await WebAssembly.instantiate(moduleBytes);
  assert.throws(() => render(instance.exports, Buffer.from([0xc3, 0x28])));
});

test("renderer stays substantially smaller than the 163 KB reference", () => {
  assert.ok(moduleBytes.length < 32 * 1024, `module grew to ${moduleBytes.length} bytes`);
});
