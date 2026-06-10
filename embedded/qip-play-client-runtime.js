function qipPlayPerfNow() {
  return performance.now();
}

const QIP_PLAY_KEY_REPEAT_DELAY_MS = 250;
const QIP_PLAY_KEY_REPEAT_INTERVAL_MS = 33;

function qipPlayToI32(value, label) {
  if (typeof value === "number") {
    return value | 0;
  }
  if (typeof value === "bigint") {
    const converted = Number(value);
    if (!Number.isFinite(converted)) {
      throw new Error(label + " returned non-finite numeric value");
    }
    return converted | 0;
  }
  throw new Error(label + " returned unsupported numeric value");
}

function qipPlayToI64(value, label) {
  if (typeof value === "bigint") {
    return value;
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw new Error(label + " returned non-finite numeric value");
    }
    return BigInt(Math.trunc(value));
  }
  throw new Error(label + " returned unsupported numeric value");
}

function qipPlayI64MSAsNumber(value, label) {
  const ms = qipPlayToI64(value, label);
  if (ms <= 0n) {
    return 0;
  }
  const maxSafe = BigInt(Number.MAX_SAFE_INTEGER);
  if (ms > maxSafe) {
    return Number.MAX_SAFE_INTEGER;
  }
  return Number(ms);
}

function qipPlayNowMSArg(nowMS) {
  if (!Number.isFinite(nowMS) || nowMS <= 0) {
    return 0n;
  }
  return BigInt(Math.floor(nowMS));
}

function qipPlayReadI32Export(exportsObj, exportName) {
  const value = exportsObj[exportName];
  if (typeof value === "function") {
    return qipPlayToI32(value(), exportName);
  }
  if (value instanceof WebAssembly.Global) {
    return qipPlayToI32(value.value, exportName);
  }
  throw new Error("qip-play module missing export " + exportName);
}

function qipPlayReadSlice(memory, ptr, len, label) {
  if (!(memory instanceof WebAssembly.Memory)) {
    throw new Error("qip-play module memory export is missing or invalid");
  }
  if (ptr < 0 || len < 0) {
    throw new Error(label + " returned negative pointer/size");
  }
  const start = ptr >>> 0;
  const size = len >>> 0;
  const end = start + size;
  if (end < start) {
    throw new Error(label + " exceeds wasm memory bounds");
  }
  const mem = new Uint8Array(memory.buffer);
  if (end > mem.length) {
    throw new Error(label + " exceeds wasm memory bounds");
  }
  return mem.subarray(start, end);
}

function qipPlayMapKeyboardEventToKeysym(event) {
  const key = event.key || "";

  if (key === "ArrowLeft") return 0xff51;
  if (key === "ArrowUp") return 0xff52;
  if (key === "ArrowRight") return 0xff53;
  if (key === "ArrowDown") return 0xff54;
  if (key === "Shift") return event.location === 2 ? 0xffe2 : 0xffe1;
  if (key === "Escape") return 0xff1b;
  if (key === "Enter") return 0xff0d;
  if (key === "Tab") return 0xff09;
  if (key === "Backspace") return 0xff08;
  if (key === "Delete") return 0xffff;
  if (key === " ") return 0x20;

  if (key.length === 1) {
    return key.codePointAt(0) | 0;
  }

  return null;
}

function qipPlayShouldCaptureMetaKey(event, keysym) {
  // Preserve browser/app-level shortcuts by default, but allow the common
  // text-editing/navigation shortcuts modules expect.
  if (event.ctrlKey) return false;
  switch (keysym | 0) {
    case 0xff51: // Left
    case 0xff52: // Up
    case 0xff53: // Right
    case 0xff54: // Down
    case 0xff08: // Backspace
    case 0xffff: // Delete
    case 0xff50: // Home
    case 0xff57: // End
      return true;
    case 0x41: // A
    case 0x43: // C
    case 0x56: // V
    case 0x58: // X
    case 0x5a: // Z
    case 0x54: // T
    case 0x61: // a
    case 0x63: // c
    case 0x76: // v
    case 0x78: // x
    case 0x7a: // z
    case 0x74: // t
      return true;
    default:
      return false;
  }
}

function qipPlayBuildKeyFlags(event, isDown) {
  let flags = 0;
  if (isDown) flags |= 1 << 0;
  if (event.repeat) flags |= 1 << 1;
  if (event.shiftKey) flags |= 1 << 2;
  if (event.ctrlKey) flags |= 1 << 3;
  if (event.altKey) flags |= 1 << 4;
  if (event.metaKey) flags |= 1 << 5;
  return flags;
}

function qipPlayMapDOMButtonsToMask(buttons) {
  let mask = 0;
  if (buttons & 1) mask |= 1; // primary -> button 1
  if (buttons & 4) mask |= 2; // auxiliary -> button 2 (middle)
  if (buttons & 2) mask |= 4; // secondary -> button 3 (right)
  return mask;
}

function qipPlayKeyIdentity(event) {
  const code = event.code || "";
  if (code !== "") {
    return code;
  }
  return "key:" + (event.key || "");
}

function qipPlayCanvasXY(canvas, event, renderWidth, renderHeight) {
  const rect = canvas.getBoundingClientRect();
  const relX = rect.width > 0 ? (event.clientX - rect.left) / rect.width : 0;
  const relY = rect.height > 0 ? (event.clientY - rect.top) / rect.height : 0;

  let x = Math.floor(relX * renderWidth);
  let y = Math.floor(relY * renderHeight);

  if (x < 0) x = 0;
  if (y < 0) y = 0;
  if (x >= renderWidth) x = renderWidth - 1;
  if (y >= renderHeight) y = renderHeight - 1;

  return { x, y };
}

async function qipPlayLoadModuleBytes(sourceURL) {
  const response = await fetch(sourceURL);
  if (!response.ok) {
    throw new Error(
      "failed to fetch module " +
        sourceURL +
        " (" +
        String(response.status) +
        ")",
    );
  }
  return await response.arrayBuffer();
}

function qipPlayGetInputElement(playElement) {
  return playElement.querySelector('input[name="input"]');
}

class QIPPlayElement extends HTMLElement {
  constructor() {
    super();
    this._started = false;
    this._rafID = 0;
    this._timeoutID = 0;
    this._timeoutTargetMS = 0;

    this._exports = null;
    this._memory = null;

    this._canvas = null;
    this._ctx = null;
    this._imageData = null;
    this._stats = null;

    this._outputPtr = 0;
    this._outputBytes = 0;
    this._renderWidth = 0;
    this._renderHeight = 0;
    this._expectedOutputBytes = 0;
    this._logTimings = false;
    this._lastTickMS = 0;
    this._lastRenderMS = 0;
    this._lastDrawMS = 0;

    this._boundKeyDown = null;
    this._boundKeyUp = null;
    this._boundPointer = null;
    this._boundPointerUp = null;
    this._boundContextMenu = null;
    this._boundClickFocus = null;
    this._boundFrame = null;
    this._boundBlur = null;
    this._boundInputChange = null;
    this._inputElement = null;
    this._eventN = 0;
    this._tickN = 0;
    this._renderN = 0;
    this._drawN = 0;
    this._activeKeyRepeats = new Map();
    this._pendingKeyEvents = [];
    this._pendingPointerEvents = [];
    this._nextWakeAtMS = 0;
    this._timeOriginMS = 0;
  }

  async connectedCallback() {
    if (this._started) {
      return;
    }
    this._started = true;
    try {
      await this._init();
      this._timeOriginMS = qipPlayPerfNow();
      this._nextWakeAtMS = this._runTick(0).nextWakeAtMS;
      this._renderFrame("initial");
      this._resumeLoop();
    } catch (err) {
      this._renderError(err);
    }
  }

  disconnectedCallback() {
    if (this._rafID !== 0 && typeof cancelAnimationFrame === "function") {
      cancelAnimationFrame(this._rafID);
      this._rafID = 0;
    }
    if (this._timeoutID !== 0) {
      clearTimeout(this._timeoutID);
      this._timeoutID = 0;
    }
    this._timeoutTargetMS = 0;
    this._nextWakeAtMS = 0;
    this._timeOriginMS = 0;
    this._detachInputBinding();
    this._clearKeyRepeats();
    this._detachInputHandlers();
  }

  async _init() {
    const sourceElement = this.querySelector("source");
    const inputElement = qipPlayGetInputElement(this);
    if (!sourceElement) {
      throw new Error("<qip-play> requires a child <source> to load wasm from");
    }

    const srcRaw = (sourceElement.getAttribute("src") || "").trim();
    if (srcRaw === "") {
      throw new Error("<qip-play> <source> requires a non-empty src");
    }
    const sourceType = sourceElement.getAttribute("type") || "application/wasm";
    if (sourceType !== "" && sourceType !== "application/wasm") {
      throw new Error("unsupported <source> type in <qip-play>: " + sourceType);
    }

    const sourceURL = new URL(srcRaw, document.baseURI).toString();
    const moduleBytes = await qipPlayLoadModuleBytes(sourceURL);
    const instantiated = await WebAssembly.instantiate(moduleBytes, {});
    const exportsObj =
      (instantiated &&
        instantiated.instance &&
        instantiated.instance.exports) ||
      (instantiated && instantiated.exports) ||
      null;
    if (!exportsObj) {
      throw new Error("failed to access wasm exports for qip-play module");
    }

    if (!(exportsObj.memory instanceof WebAssembly.Memory)) {
      throw new Error("qip-play module must export memory");
    }

    for (const name of [
      "output_ptr",
      "output_rgba8_srgb_bytes",
      "render_width_px",
      "render_height_px",
      "key_event",
      "pointer_event",
      "tick",
      "render",
    ]) {
      if (!(name in exportsObj)) {
        throw new Error("qip-play module missing export " + name);
      }
    }

    this._exports = exportsObj;
    this._memory = exportsObj.memory;
    this._outputPtr = qipPlayReadI32Export(exportsObj, "output_ptr");
    this._outputBytes = qipPlayReadI32Export(
      exportsObj,
      "output_rgba8_srgb_bytes",
    );
    this._renderWidth = qipPlayReadI32Export(exportsObj, "render_width_px");
    this._renderHeight = qipPlayReadI32Export(exportsObj, "render_height_px");

    if (
      this._outputPtr < 0 ||
      this._outputBytes < 0 ||
      this._renderWidth <= 0 ||
      this._renderHeight <= 0
    ) {
      throw new Error(
        "qip-play module exported invalid render geometry or output buffer values",
      );
    }

    const expected = this._renderWidth * this._renderHeight * 4;
    if (expected < 0 || expected !== this._outputBytes) {
      throw new Error(
        "qip-play output_rgba8_srgb_bytes must equal render width*height*4",
      );
    }
    this._expectedOutputBytes = expected;
    this._logTimings = this.hasAttribute("log");

    this._setupInputBinding(inputElement);

    this._canvas = document.createElement("canvas");
    this._canvas.width = this._renderWidth;
    this._canvas.height = this._renderHeight;
    this._canvas.style.display = "block";
    this._canvas.style.width = String(this._renderWidth) + "px";
    this._canvas.style.height = "auto";
    this._canvas.style.imageRendering = "pixelated";
    this._canvas.style.touchAction = "none";

    this._stats = document.createElement("div");
    this._stats.setAttribute("aria-label", "qip-play timing stats");
    this._stats.style.boxSizing = "border-box";
    this._stats.style.marginTop = "6px";
    this._stats.style.maxWidth = String(this._renderWidth) + "px";
    this._stats.style.font = "11px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace";
    this._stats.style.color = "#666";
    this._stats.style.whiteSpace = "normal";
    this._stats.style.lineHeight = "1.35";
    this._updateStats();

    this._ctx = this._canvas.getContext("2d", {
      alpha: false,
      desynchronized: true,
    });
    if (!this._ctx) {
      throw new Error("2D canvas context is unavailable");
    }
    this._imageData = this._ctx.createImageData(
      this._renderWidth,
      this._renderHeight,
    );

    if (!this.hasAttribute("tabindex")) {
      this.tabIndex = 0;
    }

    this.replaceChildren(this._canvas);
    if (inputElement) {
      this.appendChild(inputElement);
    }
    this.appendChild(this._stats);
    this._attachInputHandlers();
  }

  _setupInputBinding(inputElement) {
    if (!inputElement) {
      return;
    }
    if (
      !("input_ptr" in this._exports) ||
      !("input_utf8_cap" in this._exports)
    ) {
      throw new Error(
        '<qip-play><input name="input"> requires module exports input_ptr and input_utf8_cap',
      );
    }
    this._inputElement = inputElement;
    if (inputElement) {
      this._boundInputChange = () => {
        this._writeInputText(String(inputElement.value ?? ""));
      };
      inputElement.addEventListener("input", this._boundInputChange);
      inputElement.addEventListener("change", this._boundInputChange);
    }
    this._writeInputText(String(inputElement.value ?? ""));
  }

  _detachInputBinding() {
    const inputElement = this._inputElement;
    if (inputElement && this._boundInputChange) {
      inputElement.removeEventListener("input", this._boundInputChange);
      inputElement.removeEventListener("change", this._boundInputChange);
    }
    this._inputElement = null;
    this._boundInputChange = null;
  }

  _writeInputText(inputText) {
    const encoder = new TextEncoder();
    const bytes = encoder.encode(inputText);

    const inputPtr = qipPlayReadI32Export(this._exports, "input_ptr");
    const inputCap = qipPlayReadI32Export(this._exports, "input_utf8_cap");
    if (inputCap < 0 || inputPtr < 0) {
      throw new Error(
        "qip-play input exports returned invalid pointer/capacity",
      );
    }
    if (bytes.length > inputCap) {
      throw new Error(
        "qip-play input text exceeds module input_utf8_cap: " +
          String(bytes.length) +
          " > " +
          String(inputCap),
      );
    }

    const capSlice = qipPlayReadSlice(
      this._memory,
      inputPtr,
      inputCap,
      "input_ptr/input_utf8_cap",
    );
    capSlice.fill(0);
    capSlice.set(bytes, 0);

    // Keep qip-play contract-simple: write input bytes only.
    // Modules can read input on first tick/render.
    this._nextWakeAtMS = 0;
    this._resumeLoop();
  }

  _attachInputHandlers() {
    if (!this._exports || !this._canvas) {
      return;
    }

    this._boundKeyDown = (event) => {
      this._dispatchKey(event, true);
    };
    this._boundKeyUp = (event) => {
      this._dispatchKey(event, false);
    };

    this._boundPointer = (event) => {
      this._dispatchPointer(event);
    };
    this._boundPointerUp = (event) => {
      this._dispatchPointer(event);
    };
    this._boundContextMenu = (event) => {
      event.preventDefault();
      event.stopPropagation();
    };

    this._boundClickFocus = () => {
      this.focus();
    };
    this._boundBlur = () => {
      this._clearKeyRepeats();
    };

    this.addEventListener("keydown", this._boundKeyDown);
    this.addEventListener("keyup", this._boundKeyUp);
    this._canvas.addEventListener("pointerdown", this._boundPointer);
    this._canvas.addEventListener("pointermove", this._boundPointer);
    this._canvas.addEventListener("pointerup", this._boundPointerUp);
    this._canvas.addEventListener("pointercancel", this._boundPointerUp);
    this._canvas.addEventListener("contextmenu", this._boundContextMenu, true);
    this.addEventListener("contextmenu", this._boundContextMenu, true);
    this._canvas.oncontextmenu = () => false;
    this._canvas.addEventListener("click", this._boundClickFocus);
    this.addEventListener("blur", this._boundBlur);
  }

  _detachInputHandlers() {
    if (this._boundKeyDown)
      this.removeEventListener("keydown", this._boundKeyDown);
    if (this._boundKeyUp) this.removeEventListener("keyup", this._boundKeyUp);

    if (this._canvas) {
      if (this._boundPointer) {
        this._canvas.removeEventListener("pointerdown", this._boundPointer);
        this._canvas.removeEventListener("pointermove", this._boundPointer);
      }
      if (this._boundPointerUp) {
        this._canvas.removeEventListener("pointerup", this._boundPointerUp);
        this._canvas.removeEventListener("pointercancel", this._boundPointerUp);
      }
      if (this._boundContextMenu) {
        this._canvas.removeEventListener(
          "contextmenu",
          this._boundContextMenu,
          true,
        );
        this.removeEventListener("contextmenu", this._boundContextMenu, true);
      }
      if (this._boundClickFocus) {
        this._canvas.removeEventListener("click", this._boundClickFocus);
      }
    }

    this._boundKeyDown = null;
    this._boundKeyUp = null;
    this._boundPointer = null;
    this._boundPointerUp = null;
    this._boundContextMenu = null;
    if (this._canvas) {
      this._canvas.oncontextmenu = null;
    }
    this._boundClickFocus = null;
    if (this._boundBlur) this.removeEventListener("blur", this._boundBlur);
    this._boundBlur = null;
  }

  _dispatchKey(event, isDown) {
    if (!this._exports || typeof this._exports.key_event !== "function") {
      return;
    }

    const keysym = qipPlayMapKeyboardEventToKeysym(event);
    if (keysym === null) {
      return;
    }

    if (event.metaKey && !qipPlayShouldCaptureMetaKey(event, keysym)) {
      return;
    }

    event.preventDefault();
    const keyID = qipPlayKeyIdentity(event);

    // Ignore browser-generated repeat bursts; we drive repeat ourselves.
    if (isDown && event.repeat) {
      return;
    }
    if (isDown && this._activeKeyRepeats.has(keyID)) {
      return;
    }

    const flags = qipPlayBuildKeyFlags(event, isDown);
    const eventNowMS = this._eventNowMS();
    this._queueKeyEvent(keysym | 0, flags | 0, eventNowMS);
    if (isDown) {
      this._startKeyRepeat(keyID, keysym, event);
    } else {
      this._stopKeyRepeat(keyID);
    }
    this._resumeLoop();
  }

  _dispatchPointer(event) {
    if (
      !this._exports ||
      !this._canvas ||
      typeof this._exports.pointer_event !== "function"
    ) {
      return;
    }

    event.preventDefault();

    const coords = qipPlayCanvasXY(
      this._canvas,
      event,
      this._renderWidth,
      this._renderHeight,
    );
    const buttonMask = qipPlayMapDOMButtonsToMask(event.buttons | 0);
    const eventNowMS = this._eventNowMS();
    this._queuePointerEvent(
      buttonMask | 0,
      coords.x | 0,
      coords.y | 0,
      eventNowMS,
    );
    this._resumeLoop();
  }

  _startKeyRepeat(keyID, keysym, baseEvent) {
    if (!this._exports || typeof this._exports.key_event !== "function") {
      return;
    }
    if (this._activeKeyRepeats.has(keyID)) {
      return;
    }

    const repeatFlags = qipPlayBuildKeyFlags(baseEvent, true) | (1 << 1);
    const repeatState = {
      timeoutID: 0,
      keysym: keysym | 0,
      flags: repeatFlags | 0,
      pending: false,
      pendingTimeMS: 0,
    };

    const runRepeat = () => {
      if (!this._activeKeyRepeats.has(keyID)) {
        return;
      }
      repeatState.pending = true;
      repeatState.pendingTimeMS = this._eventNowMS();
      this._resumeLoop();
      repeatState.timeoutID = setTimeout(
        runRepeat,
        QIP_PLAY_KEY_REPEAT_INTERVAL_MS,
      );
    };

    repeatState.timeoutID = setTimeout(runRepeat, QIP_PLAY_KEY_REPEAT_DELAY_MS);
    this._activeKeyRepeats.set(keyID, repeatState);
  }

  _stopKeyRepeat(keyID) {
    const repeatState = this._activeKeyRepeats.get(keyID);
    if (!repeatState) {
      return;
    }
    if (repeatState.timeoutID !== 0) {
      clearTimeout(repeatState.timeoutID);
    }
    this._activeKeyRepeats.delete(keyID);
  }

  _clearKeyRepeats() {
    for (const keyID of this._activeKeyRepeats.keys()) {
      this._stopKeyRepeat(keyID);
    }
    this._pendingKeyEvents.length = 0;
    this._pendingPointerEvents.length = 0;
  }

  _queueKeyEvent(keysym, flags, timeMS) {
    this._eventN++;
    this._pendingKeyEvents.push({
      keysym: keysym | 0,
      flags: flags | 0,
      timeMS: Math.max(0, Math.floor(timeMS)),
    });
  }

  _queuePointerEvent(buttonMask, x, y, timeMS) {
    this._eventN++;
    this._pendingPointerEvents.push({
      buttonMask: buttonMask | 0,
      x: x | 0,
      y: y | 0,
      timeMS: Math.max(0, Math.floor(timeMS)),
    });
  }

  _eventNowMS() {
    if (!Number.isFinite(this._timeOriginMS) || this._timeOriginMS <= 0) {
      return 0;
    }
    const elapsed = qipPlayPerfNow() - this._timeOriginMS;
    if (!Number.isFinite(elapsed) || elapsed <= 0) {
      return 0;
    }
    return Math.floor(elapsed);
  }

  _flushPendingKeyEvents(tickNowMS) {
    if (!this._exports || typeof this._exports.key_event !== "function") {
      this._pendingKeyEvents.length = 0;
      return { count: 0, redrawRequested: false };
    }
    let flushed = 0;
    let redrawRequested = false;
    while (this._pendingKeyEvents.length > 0) {
      const evt = this._pendingKeyEvents[0];
      if (evt.timeMS > tickNowMS) break;
      this._pendingKeyEvents.shift();
      const result = this._exports.key_event(
        evt.keysym,
        evt.flags,
        qipPlayNowMSArg(evt.timeMS),
      );
      if (Number(result) !== 0) redrawRequested = true;
      flushed += 1;
    }
    return { count: flushed, redrawRequested };
  }

  _flushPendingPointerEvents(tickNowMS) {
    if (!this._exports || typeof this._exports.pointer_event !== "function") {
      this._pendingPointerEvents.length = 0;
      return { count: 0, redrawRequested: false };
    }
    let flushed = 0;
    let redrawRequested = false;
    while (this._pendingPointerEvents.length > 0) {
      const evt = this._pendingPointerEvents[0];
      if (evt.timeMS > tickNowMS) break;
      this._pendingPointerEvents.shift();
      const result = this._exports.pointer_event(
        evt.buttonMask,
        evt.x,
        evt.y,
        qipPlayNowMSArg(evt.timeMS),
      );
      if (Number(result) !== 0) redrawRequested = true;
      flushed += 1;
    }
    return { count: flushed, redrawRequested };
  }

  _flushRepeatKeyEvents(tickNowMS) {
    if (!this._exports || typeof this._exports.key_event !== "function") {
      return { count: 0, redrawRequested: false };
    }
    let flushed = 0;
    let redrawRequested = false;
    for (const repeatState of this._activeKeyRepeats.values()) {
      if (!repeatState.pending) {
        continue;
      }
      if (repeatState.pendingTimeMS > tickNowMS) {
        continue;
      }
      repeatState.pending = false;
      const result = this._exports.key_event(
        repeatState.keysym,
        repeatState.flags,
        qipPlayNowMSArg(repeatState.pendingTimeMS),
      );
      if (Number(result) !== 0) redrawRequested = true;
      flushed += 1;
    }
    return { count: flushed, redrawRequested };
  }

  _resumeLoop() {
    const nowMS = this._eventNowMS();
    const immediate = this._hasReadyWork(nowMS);
    if (!immediate && this._nextWakeAtMS === 0 && !this._hasPendingFutureWork()) {
      return;
    }
    if (!this._boundFrame) {
      this._boundFrame = (nowMS) => {
        this._rafID = 0;
        this._timeoutID = 0;
        this._timeoutTargetMS = 0;
        this._frame(nowMS);
        this._resumeLoop();
      };
    }

    if (immediate) {
      if (this._timeoutID !== 0) {
        clearTimeout(this._timeoutID);
        this._timeoutID = 0;
        this._timeoutTargetMS = 0;
      }
      if (this._rafID !== 0) {
        return;
      }
      if (typeof requestAnimationFrame === "function") {
        this._rafID = requestAnimationFrame(this._boundFrame);
        return;
      }
      this._scheduleTimeout(1, nowMS + 1);
      return;
    }

    if (this._rafID !== 0) {
      return;
    }
    const delayMS = this._nextDelayMS(nowMS);
    const targetMS = nowMS + delayMS;
    if (this._timeoutID !== 0 && this._timeoutTargetMS <= targetMS) {
      return;
    }
    if (this._timeoutID !== 0) {
      clearTimeout(this._timeoutID);
      this._timeoutID = 0;
      this._timeoutTargetMS = 0;
    }
    this._scheduleTimeout(delayMS, targetMS);
  }

  _scheduleTimeout(delayMS, targetMS) {
    this._timeoutTargetMS = targetMS;
    this._timeoutID = setTimeout(() => this._boundFrame(qipPlayPerfNow()), delayMS);
  }

  _frame(nowMS) {
    if (!this._exports || typeof this._exports.tick !== "function") {
      return;
    }

    const frameNow = Number.isFinite(nowMS) ? nowMS : qipPlayPerfNow();
    const tickNowMS = this._elapsedFromPerfNow(frameNow);
    const eventResult = this._drainEvents(tickNowMS);
    const eventCount = eventResult.eventCount;
    const wakeDue = this._nextWakeAtMS > 0 && tickNowMS >= this._nextWakeAtMS;
    if (eventCount <= 0 && !wakeDue) {
      return;
    }

    const tickResult = this._runTick(tickNowMS);
    this._nextWakeAtMS = tickResult.nextWakeAtMS;
    const renderResult = wakeDue || eventResult.redrawRequested
      ? this._renderFrame()
      : { renderMS: 0, drawMS: 0 };
    if (this._logTimings) {
      console.log(
        "[qip-play] now_ms=%d events=%d next_wake_at_ms=%d tick_ms=%s render_ms=%s draw_ms=%s frame_ms=%s",
        tickNowMS,
        eventCount,
        this._nextWakeAtMS,
        tickResult.tickMS.toFixed(3),
        renderResult.renderMS.toFixed(3),
        renderResult.drawMS.toFixed(3),
        (tickResult.tickMS + renderResult.renderMS + renderResult.drawMS).toFixed(3),
      );
    }
  }

  _runTick(tickNowMS) {
    const tickStart = qipPlayPerfNow();
    const nextWakeAtMS = qipPlayI64MSAsNumber(
      this._exports.tick(qipPlayNowMSArg(tickNowMS)),
      "tick",
    );
    const tickMS = qipPlayPerfNow() - tickStart;
    this._tickN += 1;
    this._lastTickMS = tickMS;
    this._updateStats();
    return { nextWakeAtMS, tickMS };
  }

  _drainEvents(tickNowMS) {
    const keyResult = this._flushPendingKeyEvents(tickNowMS);
    const pointerResult = this._flushPendingPointerEvents(tickNowMS);
    const repeatResult = this._flushRepeatKeyEvents(tickNowMS);
    return {
      eventCount: keyResult.count + pointerResult.count + repeatResult.count,
      redrawRequested:
        keyResult.redrawRequested ||
        pointerResult.redrawRequested ||
        repeatResult.redrawRequested,
    };
  }

  _elapsedFromPerfNow(perfNowMS) {
    if (!Number.isFinite(this._timeOriginMS) || this._timeOriginMS <= 0) {
      return 0;
    }
    const elapsed = perfNowMS - this._timeOriginMS;
    if (!Number.isFinite(elapsed) || elapsed <= 0) {
      return 0;
    }
    return Math.floor(elapsed);
  }

  _hasReadyWork(nowMS) {
    if (this._nextWakeAtMS > 0 && nowMS >= this._nextWakeAtMS) {
      return true;
    }
    if (
      this._pendingKeyEvents.length > 0 &&
      this._pendingKeyEvents[0].timeMS <= nowMS
    ) {
      return true;
    }
    if (
      this._pendingPointerEvents.length > 0 &&
      this._pendingPointerEvents[0].timeMS <= nowMS
    ) {
      return true;
    }
    for (const repeatState of this._activeKeyRepeats.values()) {
      if (repeatState.pending && repeatState.pendingTimeMS <= nowMS) {
        return true;
      }
    }
    return false;
  }

  _hasPendingFutureWork() {
    if (this._nextWakeAtMS > 0) {
      return true;
    }
    if (this._pendingKeyEvents.length > 0 || this._pendingPointerEvents.length > 0) {
      return true;
    }
    return this._hasPendingRepeatKeyEvents();
  }

  _nextDelayMS(nowMS) {
    let nextAt = Number.MAX_SAFE_INTEGER;
    if (this._nextWakeAtMS > 0) {
      nextAt = Math.min(nextAt, this._nextWakeAtMS);
    }
    if (this._pendingKeyEvents.length > 0) {
      nextAt = Math.min(nextAt, this._pendingKeyEvents[0].timeMS);
    }
    if (this._pendingPointerEvents.length > 0) {
      nextAt = Math.min(nextAt, this._pendingPointerEvents[0].timeMS);
    }
    for (const repeatState of this._activeKeyRepeats.values()) {
      if (repeatState.pending) {
        nextAt = Math.min(nextAt, repeatState.pendingTimeMS);
      }
    }
    if (!Number.isFinite(nextAt) || nextAt === Number.MAX_SAFE_INTEGER) {
      return 16;
    }
    const delay = Math.floor(nextAt - nowMS);
    if (delay <= 0) {
      return 1;
    }
    return Math.min(delay, 1000);
  }

  _hasPendingRepeatKeyEvents() {
    for (const repeatState of this._activeKeyRepeats.values()) {
      if (repeatState.pending) {
        return true;
      }
    }
    return false;
  }

  _renderFrame(reason) {
    if (!this._exports || typeof this._exports.render !== "function") {
      return { renderMS: 0, drawMS: 0 };
    }
    if (!this._imageData || !this._ctx) {
      return { renderMS: 0, drawMS: 0 };
    }

    const renderStart = qipPlayPerfNow();
    const outputLen = qipPlayToI32(
      this._exports.render(0),
      "render",
    );
    const renderMS = qipPlayPerfNow() - renderStart;
    this._renderN++;
    if (outputLen !== this._expectedOutputBytes) {
      throw new Error(
        "qip-play render(0) returned unexpected byte length " +
          String(outputLen) +
          "; expected " +
          String(this._expectedOutputBytes),
      );
    }

    const drawStart = qipPlayPerfNow();
    const bytes = qipPlayReadSlice(
      this._memory,
      this._outputPtr,
      outputLen,
      "output_ptr/output_rgba8_srgb_bytes",
    );
    this._imageData.data.set(bytes);
    this._ctx.putImageData(this._imageData, 0, 0);
    const drawMS = qipPlayPerfNow() - drawStart;
    this._drawN++;
    this._lastRenderMS = renderMS;
    this._lastDrawMS = drawMS;
    this._updateStats();
    if (this._logTimings && reason === "initial") {
      console.log(
        "[qip-play] initial_render_ms=%s initial_draw_ms=%s",
        renderMS.toFixed(3),
        drawMS.toFixed(3),
      );
    }
    return { renderMS, drawMS };
  }

  _updateStats() {
    if (!this._stats) {
      return;
    }
    this._stats.textContent =
      "tick " +
      this._lastTickMS.toFixed(3) +
      " ms | render " +
      this._lastRenderMS.toFixed(3) +
      " ms | draw " +
      this._lastDrawMS.toFixed(3) +
      " ms | ticks " +
      String(this._tickN) +
      " | renders " +
      String(this._renderN) +
      " | draws " +
      String(this._drawN);
  }

  _renderError(err) {
    const pre = document.createElement("pre");
    pre.setAttribute("role", "alert");
    const message = err instanceof Error ? err.message : String(err);
    pre.textContent = "Play error: " + message;
    this.replaceChildren(pre);
  }
}

if (!customElements.get("qip-play")) {
  customElements.define("qip-play", QIPPlayElement);
}
