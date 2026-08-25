import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

let QIPPlayElement = null;

globalThis.HTMLElement = class {
  constructor() { this.children = []; }
  hasAttribute() { return false; }
  getAttribute() { return ""; }
  querySelector() { return null; }
  addEventListener() {}
  removeEventListener() {}
  replaceChildren() {}
};

globalThis.customElements = {
  get() { return undefined; },
  define(name, elementClass) {
    if (name === "qip-play") QIPPlayElement = elementClass;
  },
};

globalThis.document = {
  baseURI: "http://example.test/",
  hidden: false,
  createElement() { return { setAttribute() {}, style: {}, textContent: "" }; },
};
globalThis.getComputedStyle = () => ({ getPropertyValue() { return ""; } });

vm.runInThisContext(readFileSync("site/_elements/qip-play.js", "utf8"), {
  filename: "site/_elements/qip-play.js",
});

function node(localName, attributes = {}, children = []) {
  return {
    localName,
    children,
    getAttribute(name) { return attributes[name] ?? ""; },
    getAttributeNames() { return Object.keys(attributes); },
  };
}

function instantiate(path) {
  const bytes = readFileSync(path);
  return {
    bytes: bytes.byteLength,
    exports: new WebAssembly.Instance(new WebAssembly.Module(bytes), {}).exports,
  };
}

test("qip-step groups ordered stages while sources remain alternatives", () => {
  const primary = node("source", { src: "/interactive/macintosh-1bit.wasm", type: "application/wasm" });
  const ignored = node("source", { src: "/unsupported", type: "application/example" });
  const effect = node("source", { src: "/image/duotone.wasm", type: "application/wasm" });
  const play = node("qip-play", {}, [
    node("qip-step", { name: "desktop" }, [primary]),
    node("qip-step", { name: "duotone" }, [ignored, effect]),
  ]);
  const steps = qipPlaySourceSteps(play);
  assert.equal(steps.length, 2);
  assert.equal(steps[0].sourceElement, primary);
  assert.equal(steps[1].sourceElement, effect);

  play.children.push(node("source", { src: "/ambiguous.wasm" }));
  assert.throws(() => qipPlaySourceSteps(play), /cannot mix direct <source>/);
});

test("finite post-processing runs after the Interactive render and reports each step", () => {
  const primaryModule = instantiate("components/interactive/macintosh-1bit.wasm");
  const effectModule = instantiate("components/image/ktx2/ktx2-duotone-to-ktx2-rgba32float-display-p3-linear.wasm");
  const primarySource = node("source");
  const effectSource = node("source");
  const primary = {
    label: "desktop",
    sourceElement: primarySource,
    exports: primaryModule.exports,
    memory: primaryModule.exports.memory,
    moduleBytes: primaryModule.bytes,
    outputCapacity: primaryModule.exports.output_bytes_cap(),
    renderN: 0,
    lastRenderMS: 0,
  };
  const effect = {
    label: "duotone",
    sourceElement: effectSource,
    exports: effectModule.exports,
    memory: effectModule.exports.memory,
    moduleBytes: effectModule.bytes,
    outputCapacity: effectModule.exports.output_bytes_cap(),
    inputCapacity: effectModule.exports.input_bytes_cap(),
    inputPtr: effectModule.exports.input_ptr(),
    renderN: 0,
    lastRenderMS: 0,
  };

  const element = new QIPPlayElement();
  element._exports = primary.exports;
  element._memory = primary.memory;
  element._sourceElement = primarySource;
  element._uniforms = [];
  element._outputCapacity = primary.outputCapacity;
  element._steps = [primary, effect];
  element._postStages = [effect];
  element._wasmByteLength = primary.moduleBytes + effect.moduleBytes;
  element._debugStats = true;
  element._stats = { textContent: "" };

  const initial = element._runInitialContentRender();
  const parsed = element._readKTX2Output(initial.rendered);
  assert.equal(parsed.width, 512);
  assert.equal(parsed.height, 342);
  assert.equal(parsed.profile.pixelFormat, "rgba-float32");
  assert.equal(primary.renderN, 1);
  assert.equal(effect.renderN, 1);

  const floats = parsed.pixels;
  let foundShadow = false;
  let foundHighlight = false;
  for (let offset = 0; offset < floats.length; offset += 4) {
    foundShadow ||= Math.abs(floats[offset] - 0.004) < 0.0001;
    foundHighlight ||= Math.abs(floats[offset] - 2.40) < 0.0001;
    if (foundShadow && foundHighlight) break;
  }
  assert.equal(foundShadow, true);
  assert.equal(foundHighlight, true);

  element._updateStats();
  assert.match(element._stats.textContent, /\ndesktop \| wasm .* \| memory .* \| render\s+1 /);
  assert.match(element._stats.textContent, /\nduotone \| wasm .* \| memory .* \| render\s+1 /);
});
