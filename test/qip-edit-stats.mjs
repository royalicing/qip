import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

let QIPEditElement = null;

globalThis.HTMLElement = class {
  constructor() {
    this.dataset = {};
  }
};

globalThis.customElements = {
  get() {
    return undefined;
  },
  define(name, elementClass) {
    if (name === "qip-edit") {
      QIPEditElement = elementClass;
    }
  },
};

vm.runInThisContext(
  readFileSync("embedded/qip-edit-client-runtime.js", "utf8"),
  { filename: "embedded/qip-edit-client-runtime.js" },
);

test("qip-edit formats pipeline stats like qip-play", () => {
  const element = new QIPEditElement();
  element._moduleBytesTotal = 4900;
  element._stages = [
    { exports: { memory: new WebAssembly.Memory({ initial: 2 }) } },
    { exports: { memory: new WebAssembly.Memory({ initial: 32 }) } },
  ];

  element.dataset.moduleBytesTotal = String(element._moduleBytesTotal);
  element._updateStats(2.46);

  assert.equal(element.dataset.moduleBytesTotal, "4900");
  assert.equal(element.dataset.memoryBytesTotal, String(34 * 65536));
  assert.equal(element.dataset.wasmSize, "4.9 kB");
  assert.equal(element.dataset.memorySize, "2.2 MB");
  assert.equal(element.dataset.renderTime, "2.5 ms");
});

test("qip-edit excludes stages without a live instance from memory", () => {
  const element = new QIPEditElement();
  element._stages = [
    { exports: { memory: new WebAssembly.Memory({ initial: 1 }) } },
    { exports: null },
  ];

  element._updateStats(0);

  assert.equal(element.dataset.memoryBytesTotal, "65536");
  assert.equal(element.dataset.memorySize, "65.5 kB");
  assert.equal(element.dataset.renderTime, "0.0 ms");
});

test("qip-edit after content uses the formatted stats", () => {
  const styles = readFileSync("recipes/text/markdown/styles.css", "utf8");

  assert.match(
    styles,
    /content:\s*"wasm " attr\(data-wasm-size\) " \| memory "\s*attr\(data-memory-size\) " \| render " attr\(data-render-time\);/,
  );
});
