import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

let QIPPlayElement = null;

globalThis.HTMLElement = class {
  constructor() {
    this._listeners = [];
  }

  hasAttribute() {
    return false;
  }

  getAttribute() {
    return "";
  }

  querySelector() {
    return null;
  }

  addEventListener(type, listener, options) {
    this._listeners.push({ type, listener, options });
  }

  removeEventListener(type, listener, options) {
    this._listeners = this._listeners.filter((entry) => {
      return (
        entry.type !== type ||
        entry.listener !== listener ||
        entry.options !== options
      );
    });
  }

  replaceChildren() {}
};

globalThis.customElements = {
  get() {
    return undefined;
  },
  define(name, elementClass) {
    if (name === "qip-play") {
      QIPPlayElement = elementClass;
    }
  },
};

globalThis.document = {
  baseURI: "http://example.test/",
  createElement() {
    return {
      setAttribute() {},
      style: {},
      textContent: "",
    };
  },
};

globalThis.getComputedStyle = () => ({
  getPropertyValue() {
    return "";
  },
});

vm.runInThisContext(
  readFileSync("site/_elements/qip-play.js", "utf8"),
  { filename: "site/_elements/qip-play.js" },
);

function makePlayElement(debugStats, outputPtr = 0, outputLen = 4, imageOffset = 0) {
  const memory = new WebAssembly.Memory({ initial: 1 });
  const bytes = new Uint8Array(memory.buffer, outputPtr, outputLen);
  for (let i = 0; i < outputLen; i++) {
    bytes[i] = i + 1;
  }

  let putImageDataN = 0;
  const element = new QIPPlayElement();
  element._debugStats = debugStats;
  element._exports = {
    render() {
      return outputLen;
    },
  };
  element._memory = memory;
  element._outputPtr = outputPtr;
  element._expectedOutputBytes = outputLen;
  element._imageData = {
    data: new Uint8ClampedArray(new ArrayBuffer(outputLen + imageOffset), imageOffset, outputLen),
  };
  element._ctx = {
    putImageData() {
      putImageDataN++;
    },
  };
  element._stats = { textContent: "" };

  return {
    element,
    bytes,
    putImageDataN: () => putImageDataN,
  };
}

function makeEventTarget() {
  return {
    listeners: [],
    focusN: 0,
    addEventListener(type, listener, options) {
      this.listeners.push({ type, listener, options });
    },
    removeEventListener(type, listener, options) {
      this.listeners = this.listeners.filter((entry) => {
        return (
          entry.type !== type ||
          entry.listener !== listener ||
          entry.options !== options
        );
      });
    },
    focus() {
      this.focusN++;
    },
  };
}

function godRaysUniforms(speed = "0.75") {
  return Object.entries({
    density: "0.3",
    spotty: "0.3",
    mid_size: "0.2",
    mid_intensity: "0.4",
    intensity: "0.8",
    bloom: "0.4",
    colors_count: "4",
    color_back: "0x000000ff",
    color_bloom: "0x0000ffff",
    color_1: "0xa600ff6e",
    color_2: "0x6200fff0",
    color_3: "0xffffffff",
    color_4: "0x33fff5ff",
    color_5: "0",
    fit: "1",
    scale: "1",
    rotation: "0",
    origin_x: "0.5",
    origin_y: "0.5",
    offset_x: "0",
    offset_y: "-0.55",
    world_width: "0",
    world_height: "0",
    pixel_ratio: "1",
    speed,
    frame: "0",
  }).map(([key, value]) => ({ key, value }));
}

test("qip-play debug stats count unchanged renders without skipping canvas draws", () => {
  const { element, bytes, putImageDataN } = makePlayElement(true);

  element._renderN++;
  assert.equal(element._presentPixels(bytes, 0).unchanged, false);
  element._renderN++;
  assert.equal(element._presentPixels(bytes, 0).unchanged, true);
  bytes[3] = 5;
  element._renderN++;
  assert.equal(element._presentPixels(bytes, 0).unchanged, false);

  assert.equal(element._renderN, 3);
  assert.equal(element._unchangedRenderN, 1);
  assert.equal(element._drawN, 3);
  assert.equal(putImageDataN(), 3);
  assert.match(
    element._stats.textContent,
    /^wasm 0 B \| memory 65\.5 kB \| update {3}0 \d+\.\d ms \| render {3}3 \d+\.\d ms \| unchanged renders 1 \| compare \d+\.\d ms$/,
  );
  assert.doesNotMatch(element._stats.textContent, /\binit\b/);
  assert.doesNotMatch(element._stats.textContent, /\| renders /);
  assert.doesNotMatch(element._stats.textContent, /\bdraws?\b/);
  assert.match(element._stats.textContent, /unchanged renders 1/);
  assert.match(element._stats.textContent, /compare \d+\.\d ms/);
});

test("qip-play unchanged render comparison is disabled outside debug stats", () => {
  const { element, bytes, putImageDataN } = makePlayElement(false);

  element._renderN++;
  assert.equal(element._presentPixels(bytes, 0).unchanged, false);
  element._renderN++;
  assert.equal(element._presentPixels(bytes, 0).unchanged, false);

  assert.equal(element._renderN, 2);
  assert.equal(element._unchangedRenderN, 0);
  assert.equal(element._drawN, 2);
  assert.equal(putImageDataN(), 2);
  assert.match(
    element._stats.textContent,
    /^wasm 0 B \| memory 65\.5 kB \| update {3}0 \d+\.\d ms \| render {3}2 \d+\.\d ms$/,
  );
  assert.doesNotMatch(element._stats.textContent, /\binit\b/);
  assert.doesNotMatch(element._stats.textContent, /\| renders /);
  assert.doesNotMatch(element._stats.textContent, /unchanged renders/);
  assert.doesNotMatch(element._stats.textContent, /\bdraws?\b/);
});

test("qip-play unchanged render comparison handles matching unaligned views", () => {
  const { element, bytes } = makePlayElement(true, 1, 9, 1);

  element._renderN++;
  assert.equal(element._presentPixels(bytes, 0).unchanged, false);
  element._renderN++;
  assert.equal(element._presentPixels(bytes, 0).unchanged, true);
  bytes[8] = 10;
  element._renderN++;
  assert.equal(element._presentPixels(bytes, 0).unchanged, false);

  assert.equal(element._unchangedRenderN, 1);
});

test("qip-play only suppresses context menu on the canvas", () => {
  const element = new QIPPlayElement();
  element._exports = { key_event() {}, pointer_event() {} };
  element._canvas = makeEventTarget();

  element._attachInputHandlers();

  assert.equal(
    element._canvas.listeners.filter((entry) => entry.type === "contextmenu").length,
    1,
  );
  assert.equal(
    element._listeners.filter((entry) => entry.type === "contextmenu").length,
    0,
  );

  element._detachInputHandlers();

  assert.equal(
    element._canvas.listeners.filter((entry) => entry.type === "contextmenu").length,
    0,
  );
});

test("qip-play scopes keyboard focus to the canvas", () => {
  const element = new QIPPlayElement();
  element._exports = { key_event() {}, pointer_event() {} };
  element._canvas = makeEventTarget();

  element._attachInputHandlers();

  assert.equal(element._listeners.filter((entry) => entry.type === "keydown").length, 0);
  assert.equal(element._canvas.listeners.filter((entry) => entry.type === "keydown").length, 1);
  const click = element._canvas.listeners.find((entry) => entry.type === "click");
  click.listener();
  assert.equal(element._canvas.focusN, 1);

  element._detachInputHandlers();
});

test("qip-play releases held input on blur without dropping queued events", () => {
  const element = new QIPPlayElement();
  element._exports = { key_event() {}, pointer_event() {} };
  element._eventNowMS = () => 9;
  let resumed = 0;
  element._resumeLoop = () => { resumed++; };

  element._queuePointerEvent(1, 10, 20, 7);
  element._activeKeyRepeats.set("KeyA", {
    timeoutID: 0,
    keysym: 0x61,
    flags: 7,
    pending: true,
    pendingTimeMS: 8,
    pendingSequence: ++element._eventSequence,
  });

  element._releaseHeldInput();

  assert.equal(element._activeKeyRepeats.size, 0);
  assert.equal(resumed, 1);
  assert.deepEqual(
    element._pendingEvents.map(({ type, flags, timeMS, x, y }) => ({
      type,
      flags,
      timeMS,
      x,
      y,
    })),
    [
      { type: "pointer", flags: undefined, timeMS: 7, x: 10, y: 20 },
      { type: "key", flags: 7, timeMS: 8, x: undefined, y: undefined },
      { type: "key", flags: 4, timeMS: 9, x: undefined, y: undefined },
      { type: "pointer", flags: undefined, timeMS: 9, x: -1, y: -1 },
    ],
  );
});

test("qip-play reports pointer leave outside the render surface", () => {
  const element = new QIPPlayElement();
  element._exports = { pointer_event() {} };
  element._canvas = makeEventTarget();
  element._eventNowMS = () => 17;
  element._resumeLoop = () => {};
  let queued = null;
  element._queuePointerEvent = (...args) => {
    queued = args;
  };

  element._attachInputHandlers();
  const pointerLeave = element._canvas.listeners.find(
    (entry) => entry.type === "pointerleave",
  );
  pointerLeave.listener();

  assert.deepEqual(queued, [0, -1, -1, 17]);
  element._detachInputHandlers();
});

test("qip-play runs initial Content render and separate Timed KTX2 updates", () => {
  const wasm = readFileSync("components/interactive/god-rays-optimized.wasm");
  const instance = new WebAssembly.Instance(new WebAssembly.Module(wasm), {});
  const element = new QIPPlayElement();
  element._exports = instance.exports;
  element._memory = instance.exports.memory;
  element._uniforms = godRaysUniforms();
  element._outputPtr = instance.exports.output_ptr();
  element._outputCapacity = instance.exports.output_bytes_cap();

  const initial = element._runInitialContentRender();
  const parsed = element._readKTX2Output(initial.outputLen);
  assert.equal(parsed.width, 640);
  assert.equal(parsed.height, 360);
  assert.equal(parsed.pixels.byteLength, 640 * 360 * 4);
  assert.equal(element._nextWakeAtMS, 0);
  assert.equal(element._updateN, 0);
  assert.equal(element._renderN, 1);

  element._runBootstrapUpdate();
  assert.equal(element._nextWakeAtMS, 17);

  const before = Buffer.from(parsed.pixels);
  const update = element._runUpdate(17, false);
  assert.equal(update.nextWakeAtMS, 33);
  assert.equal(element._finishedAtMS, 17);
  assert.equal(element._updateN, 2);
  assert.equal(element._renderN, 1);
  assert.deepEqual(Buffer.from(element._readKTX2Output(initial.outputLen).pixels), before);

  let drawN = 0;
  element._renderWidth = parsed.width;
  element._renderHeight = parsed.height;
  element._expectedOutputBytes = parsed.pixels.byteLength;
  element._canvas = { width: parsed.width, height: parsed.height };
  element._ctx = {
    createImageData(width, height) {
      return { data: new Uint8ClampedArray(width * height * 4) };
    },
    putImageData() {
      drawN++;
    },
  };
  element._imageData = element._ctx.createImageData(parsed.width, parsed.height);
  element._stats = { textContent: "" };
  const visible = element._runUpdate(33, true);
  assert.equal(visible.nextWakeAtMS, 49);
  assert.equal(element._renderN, 2);
  assert.equal(element._drawN, 1);
  assert.equal(drawN, 1);
  assert.match(element._stats.textContent, /\| update +3 /);
});

test("qip-play batches timestamp-free Interactive events inside an update", () => {
  const wasm = readFileSync("components/interactive/tic-tac-toe-sun-moon.wasm");
  const instance = new WebAssembly.Instance(new WebAssembly.Module(wasm), {});
  const element = new QIPPlayElement();
  element._exports = instance.exports;
  element._memory = instance.exports.memory;
  element._uniforms = [];
  element._outputPtr = instance.exports.output_ptr();
  element._outputCapacity = instance.exports.output_bytes_cap();

  const initial = element._runInitialContentRender();
  element._runBootstrapUpdate();
  const parsed = element._readKTX2Output(initial.outputLen);
  let drawN = 0;
  element._renderWidth = parsed.width;
  element._renderHeight = parsed.height;
  element._expectedOutputBytes = parsed.pixels.byteLength;
  element._canvas = { width: parsed.width, height: parsed.height };
  element._ctx = {
    createImageData(width, height) {
      return { data: new Uint8ClampedArray(width * height * 4) };
    },
    putImageData() {
      drawN++;
    },
  };
  element._imageData = element._ctx.createImageData(parsed.width, parsed.height);
  element._stats = { textContent: "" };

  element._queuePointerEvent(1, 64, 64, 1);
  element._queuePointerEvent(0, 64, 64, 1);
  const accepted = element._runUpdate(1, false);
  assert.equal(accepted.eventCount, 2);
  assert.equal(accepted.acceptedEvent, true);
  assert.equal(accepted.rendered, true);
  assert.equal(drawN, 1);

  element._queuePointerEvent(1, 64, 64, 2);
  element._queuePointerEvent(0, 64, 64, 2);
  const ignored = element._runUpdate(2, false);
  assert.equal(ignored.eventCount, 2);
  assert.equal(ignored.acceptedEvent, false);
  assert.equal(ignored.rendered, false);
  assert.equal(drawN, 1);
});

test("qip-play combines a scheduled Timed wake with an Interactive event", () => {
  const wasm = readFileSync("components/interactive/snake.wasm");
  const instance = new WebAssembly.Instance(new WebAssembly.Module(wasm), {});
  const element = new QIPPlayElement();
  element._exports = instance.exports;
  element._memory = instance.exports.memory;
  element._uniforms = [];
  element._outputPtr = instance.exports.output_ptr();
  element._outputCapacity = instance.exports.output_bytes_cap();

  const initial = element._runInitialContentRender();
  const parsed = element._readKTX2Output(initial.outputLen);
  assert.equal(element._nextWakeAtMS, 0);
  element._runBootstrapUpdate();
  assert.equal(element._nextWakeAtMS, 120);
  let drawN = 0;
  element._renderWidth = parsed.width;
  element._renderHeight = parsed.height;
  element._expectedOutputBytes = parsed.pixels.byteLength;
  element._canvas = { width: parsed.width, height: parsed.height };
  element._ctx = {
    createImageData(width, height) {
      return { data: new Uint8ClampedArray(width * height * 4) };
    },
    putImageData() {
      drawN++;
    },
  };
  element._imageData = element._ctx.createImageData(parsed.width, parsed.height);
  element._stats = { textContent: "" };

  element._queueKeyEvent(0xff52, 1, 120);
  const result = element._runUpdate(120, true);
  assert.equal(result.eventCount, 1);
  assert.equal(result.acceptedEvent, true);
  assert.equal(result.nextWakeAtMS, 240);
  assert.equal(result.rendered, true);
  assert.equal(drawN, 1);
});

test("qip-play commits fallible Content input before bootstrapping updates", () => {
  const element = new QIPPlayElement();
  let commitN = 0;
  element._inputSize = 3;
  element._uniforms = [];
  element._exports = {
    render(inputSize) {
      assert.equal(inputSize, 3);
      return 0;
    },
    commit() {
      commitN++;
      return 0n;
    },
  };

  const initial = element._runInitialContentRender();
  assert.equal(initial.outputLen, 0);
  assert.equal(commitN, 1);
  assert.equal(element._nextWakeAtMS, 0);
});
