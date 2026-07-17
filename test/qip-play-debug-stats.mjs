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

test("qip-play debug stats count unchanged renders without skipping canvas draws", () => {
  const { element, bytes, putImageDataN } = makePlayElement(true);

  assert.equal(element._renderFrame().unchanged, false);
  assert.equal(element._renderFrame().unchanged, true);
  bytes[3] = 5;
  assert.equal(element._renderFrame().unchanged, false);

  assert.equal(element._renderN, 3);
  assert.equal(element._unchangedRenderN, 1);
  assert.equal(element._drawN, 3);
  assert.equal(putImageDataN(), 3);
  assert.match(
    element._stats.textContent,
    /^wasm 0 B \| memory 65\.5 kB \| tick {3}0 \d+\.\d ms \| render {3}3 \d+\.\d ms \| unchanged renders 1 \| compare \d+\.\d ms$/,
  );
  assert.doesNotMatch(element._stats.textContent, /\binit\b/);
  assert.doesNotMatch(element._stats.textContent, /\| ticks /);
  assert.doesNotMatch(element._stats.textContent, /\| renders /);
  assert.doesNotMatch(element._stats.textContent, /\bdraws?\b/);
  assert.match(element._stats.textContent, /unchanged renders 1/);
  assert.match(element._stats.textContent, /compare \d+\.\d ms/);
});

test("qip-play unchanged render comparison is disabled outside debug stats", () => {
  const { element, putImageDataN } = makePlayElement(false);

  assert.equal(element._renderFrame().unchanged, false);
  assert.equal(element._renderFrame().unchanged, false);

  assert.equal(element._renderN, 2);
  assert.equal(element._unchangedRenderN, 0);
  assert.equal(element._drawN, 2);
  assert.equal(putImageDataN(), 2);
  assert.match(
    element._stats.textContent,
    /^wasm 0 B \| memory 65\.5 kB \| tick {3}0 \d+\.\d ms \| render {3}2 \d+\.\d ms$/,
  );
  assert.doesNotMatch(element._stats.textContent, /\binit\b/);
  assert.doesNotMatch(element._stats.textContent, /\| ticks /);
  assert.doesNotMatch(element._stats.textContent, /\| renders /);
  assert.doesNotMatch(element._stats.textContent, /unchanged renders/);
  assert.doesNotMatch(element._stats.textContent, /\bdraws?\b/);
});

test("qip-play unchanged render comparison handles matching unaligned views", () => {
  const { element, bytes } = makePlayElement(true, 1, 9, 1);

  assert.equal(element._renderFrame().unchanged, false);
  assert.equal(element._renderFrame().unchanged, true);
  bytes[8] = 10;
  assert.equal(element._renderFrame().unchanged, false);

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

test("qip-play ticks accepted events but skips ignored events", () => {
  const element = new QIPPlayElement();
  let eventResult = 0;
  let tickN = 0;
  let renderN = 0;
  element._exports = {
    pointer_event() {
      return eventResult;
    },
    tick() {
      return 0n;
    },
  };
  element._elapsedFromPerfNow = () => 0;
  element._runTick = () => {
    tickN++;
    return { nextWakeAtMS: 0, tickMS: 0 };
  };
  element._renderFrame = () => {
    renderN++;
    return { renderMS: 0, compareMS: 0, drawMS: 0, unchanged: false };
  };

  element._queuePointerEvent(0, 1, 1, 0);
  element._frame(0);
  assert.equal(tickN, 0);
  assert.equal(renderN, 0);

  eventResult = 1;
  element._queuePointerEvent(0, 2, 2, 0);
  element._frame(0);
  assert.equal(tickN, 1);
  assert.equal(renderN, 1);
});
