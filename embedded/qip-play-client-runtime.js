function qipPlayPerfNow() {
  if (
    typeof performance !== "undefined" &&
    typeof performance.now === "function"
  ) {
    return performance.now();
  }
  return Date.now();
}

const QIP_PLAY_KEY_REPEAT_DELAY_MS = 250;
const QIP_PLAY_KEY_REPEAT_INTERVAL_MS = 33;
const QIP_PLAY_FIXED_TICK_MS_DEFAULT = 16;
const QIP_PLAY_MAX_TICKS_PER_FRAME = 8;

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
  if (key === "Escape") return 0xff1b;
  if (key === "Enter") return 0xff0d;
  if (key === "Tab") return 0xff09;
  if (key === "Backspace") return 0xff08;
  if (key === " ") return 0x20;

  if (key.length === 1) {
    return key.codePointAt(0) | 0;
  }

  return null;
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

    this._exports = null;
    this._memory = null;

    this._canvas = null;
    this._ctx = null;
    this._imageData = null;

    this._outputPtr = 0;
    this._outputCap = 0;
    this._renderWidth = 0;
    this._renderHeight = 0;
    this._expectedOutputBytes = 0;
    this._logTimings = false;

    this._boundKeyDown = null;
    this._boundKeyUp = null;
    this._boundPointer = null;
    this._boundPointerUp = null;
    this._boundClickFocus = null;
    this._boundFrame = null;
    this._boundBlur = null;
    this._boundInputChange = null;
    this._inputElement = null;
    this._activeKeyRepeats = new Map();
    this._pendingKeyEvents = [];
    this._pendingPointerEvents = [];
    this._fixedTickMS = QIP_PLAY_FIXED_TICK_MS_DEFAULT;
    this._maxTicksPerFrame = QIP_PLAY_MAX_TICKS_PER_FRAME;
    this._lastFrameMS = 0;
    this._tickAccumulatorMS = 0;
    this._simElapsedMS = 0;
    this._keepAnimating = false;
    this._timeOriginMS = 0;
  }

  async connectedCallback() {
    if (this._started) {
      return;
    }
    this._started = true;
    try {
      await this._init();
      const firstTick = this._runTick(0);
      this._keepAnimating = firstTick.changed !== 0;
      this._timeOriginMS = qipPlayPerfNow();
      this._lastFrameMS = this._timeOriginMS;
      this._tickAccumulatorMS = 0;
      this._simElapsedMS = 0;
      this._renderFrame("initial");
      if (
        this._keepAnimating ||
        this._pendingKeyEvents.length > 0 ||
        this._pendingPointerEvents.length > 0
      ) {
        this._resumeLoop();
      }
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
    this._lastFrameMS = 0;
    this._tickAccumulatorMS = 0;
    this._simElapsedMS = 0;
    this._keepAnimating = false;
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
      "output_bytes_cap",
      "render_width_px",
      "render_height_px",
      "key_event",
      "pointer_event",
      "tick",
      "render_output",
    ]) {
      if (!(name in exportsObj)) {
        throw new Error("qip-play module missing export " + name);
      }
    }

    this._exports = exportsObj;
    this._memory = exportsObj.memory;
    this._outputPtr = qipPlayReadI32Export(exportsObj, "output_ptr");
    this._outputCap = qipPlayReadI32Export(exportsObj, "output_bytes_cap");
    this._renderWidth = qipPlayReadI32Export(exportsObj, "render_width_px");
    this._renderHeight = qipPlayReadI32Export(exportsObj, "render_height_px");

    if (
      this._outputPtr < 0 ||
      this._outputCap < 0 ||
      this._renderWidth <= 0 ||
      this._renderHeight <= 0
    ) {
      throw new Error(
        "qip-play module exported invalid render geometry or output buffer values",
      );
    }

    const expected = this._renderWidth * this._renderHeight * 4;
    if (expected < 0 || expected > this._outputCap) {
      throw new Error(
        "qip-play output buffer is smaller than render width*height*4",
      );
    }
    this._expectedOutputBytes = expected;
    this._logTimings = this.hasAttribute("log");
    this._fixedTickMS = this._readFixedTickMS();

    this._setupInputBinding(inputElement);

    this._canvas = document.createElement("canvas");
    this._canvas.width = this._renderWidth;
    this._canvas.height = this._renderHeight;
    this._canvas.style.display = "block";
    this._canvas.style.width = "100%";
    this._canvas.style.height = "auto";
    this._canvas.style.imageRendering = "pixelated";
    this._canvas.style.touchAction = "none";

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
    this._attachInputHandlers();
  }

  _setupInputBinding(inputElement) {
    if (!inputElement) {
      return;
    }
    if (!("input_ptr" in this._exports) || !("input_utf8_cap" in this._exports)) {
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

  _readFixedTickMS() {
    const raw = this.getAttribute("tick-ms");
    if (raw == null || raw.trim() === "") {
      return QIP_PLAY_FIXED_TICK_MS_DEFAULT;
    }
    const parsed = Number(raw);
    if (!Number.isFinite(parsed) || parsed <= 0) {
      throw new Error(
        "<qip-play> tick-ms must be a positive number of milliseconds",
      );
    }
    return Math.max(1, Math.floor(parsed));
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
      throw new Error("qip-play input exports returned invalid pointer/capacity");
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
      if (this._boundClickFocus) {
        this._canvas.removeEventListener("click", this._boundClickFocus);
      }
    }

    this._boundKeyDown = null;
    this._boundKeyUp = null;
    this._boundPointer = null;
    this._boundPointerUp = null;
    this._boundClickFocus = null;
    if (this._boundBlur) this.removeEventListener("blur", this._boundBlur);
    this._boundBlur = null;
  }

  _dispatchKey(event, isDown) {
    if (!this._exports || typeof this._exports.key_event !== "function") {
      return;
    }

    // Preserve browser/app shortcuts like Cmd+R on macOS by not capturing
    // Meta-modified keystrokes for qip-play modules.
    if (event.metaKey) {
      return;
    }

    const keysym = qipPlayMapKeyboardEventToKeysym(event);
    if (keysym === null) {
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
    this._queueKeyEvent(keysym | 0, flags | 0, eventNowMS | 0);
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
      eventNowMS | 0,
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
    this._pendingKeyEvents.push({
      keysym: keysym | 0,
      flags: flags | 0,
      timeMS: timeMS | 0,
    });
  }

  _queuePointerEvent(buttonMask, x, y, timeMS) {
    this._pendingPointerEvents.push({
      buttonMask: buttonMask | 0,
      x: x | 0,
      y: y | 0,
      timeMS: timeMS | 0,
    });
  }

  _eventNowMS() {
    const now = qipPlayPerfNow();
    if (this._timeOriginMS === 0) {
      this._timeOriginMS = now;
    }
    const elapsed = now - this._timeOriginMS;
    if (!Number.isFinite(elapsed) || elapsed <= 0) {
      return 0;
    }
    return Math.floor(elapsed);
  }

  _flushPendingKeyEvents(tickNowMS) {
    if (!this._exports || typeof this._exports.key_event !== "function") {
      this._pendingKeyEvents.length = 0;
      return;
    }
    while (this._pendingKeyEvents.length > 0) {
      const evt = this._pendingKeyEvents[0];
      if (evt.timeMS > tickNowMS) break;
      this._pendingKeyEvents.shift();
      this._exports.key_event(evt.keysym, evt.flags, evt.timeMS);
    }
  }

  _flushPendingPointerEvents(tickNowMS) {
    if (!this._exports || typeof this._exports.pointer_event !== "function") {
      this._pendingPointerEvents.length = 0;
      return;
    }
    while (this._pendingPointerEvents.length > 0) {
      const evt = this._pendingPointerEvents[0];
      if (evt.timeMS > tickNowMS) break;
      this._pendingPointerEvents.shift();
      this._exports.pointer_event(evt.buttonMask, evt.x, evt.y, evt.timeMS);
    }
  }

  _flushRepeatKeyEvents(tickNowMS) {
    if (!this._exports || typeof this._exports.key_event !== "function") {
      return;
    }
    for (const repeatState of this._activeKeyRepeats.values()) {
      if (!repeatState.pending) {
        continue;
      }
      if (repeatState.pendingTimeMS > tickNowMS) {
        continue;
      }
      repeatState.pending = false;
      this._exports.key_event(
        repeatState.keysym,
        repeatState.flags,
        repeatState.pendingTimeMS,
      );
    }
  }

  _resumeLoop() {
    if (this._rafID !== 0 || this._timeoutID !== 0) {
      return;
    }
    if (!this._boundFrame) {
      this._boundFrame = (nowMS) => {
        this._rafID = 0;
        this._timeoutID = 0;
        const keepRunning = this._frame(nowMS);
        if (keepRunning) {
          this._resumeLoop();
        }
      };
    }

    if (typeof requestAnimationFrame === "function") {
      this._rafID = requestAnimationFrame(this._boundFrame);
      return;
    }

    this._timeoutID = setTimeout(() => this._boundFrame(qipPlayPerfNow()), 16);
  }

  _frame(nowMS) {
    if (!this._exports || typeof this._exports.tick !== "function") {
      return false;
    }

    const frameNowMS = Number.isFinite(nowMS) ? nowMS : qipPlayPerfNow();
    if (this._lastFrameMS === 0) {
      this._lastFrameMS = frameNowMS;
    }

    let dtMS = frameNowMS - this._lastFrameMS;
    this._lastFrameMS = frameNowMS;
    if (!Number.isFinite(dtMS) || dtMS < 0) {
      dtMS = 0;
    }
    if (dtMS > 1000) {
      dtMS = 1000;
    }
    this._tickAccumulatorMS += dtMS;

    let tickCount = 0;
    let changed = 0;
    let tickMS = 0;
    while (
      this._tickAccumulatorMS >= this._fixedTickMS &&
      tickCount < this._maxTicksPerFrame
    ) {
      this._simElapsedMS += this._fixedTickMS;
      const tickResult = this._runTick(this._simElapsedMS | 0);
      if (tickResult.changed !== 0) {
        changed = 1;
      }
      tickMS += tickResult.tickMS;
      this._tickAccumulatorMS -= this._fixedTickMS;
      tickCount += 1;
    }
    if (
      tickCount >= this._maxTicksPerFrame &&
      this._tickAccumulatorMS >= this._fixedTickMS
    ) {
      // Prevent runaway catch-up when a tab stalls for a long period.
      this._tickAccumulatorMS = this._fixedTickMS - 1;
    }
    if (tickCount > 0) {
      this._keepAnimating = changed !== 0;
    }

    let renderMS = null;
    if (tickCount > 0 || this._keepAnimating) {
      renderMS = this._renderFrame();
    }
    if (this._logTimings) {
      if (renderMS === null) {
        console.log(
          "[qip-play] tick_ms=%s changed=%d ticks=%d render_ms=-",
          tickMS.toFixed(3),
          changed | 0,
          tickCount | 0,
        );
      } else {
        console.log(
          "[qip-play] tick_ms=%s changed=%d ticks=%d render_ms=%s frame_ms=%s",
          tickMS.toFixed(3),
          changed | 0,
          tickCount | 0,
          renderMS.toFixed(3),
          (tickMS + renderMS).toFixed(3),
        );
      }
    }
    const hasPendingRepeat = this._hasPendingRepeatKeyEvents();
    return (
      this._keepAnimating ||
      this._pendingKeyEvents.length > 0 ||
      this._pendingPointerEvents.length > 0 ||
      hasPendingRepeat ||
      this._tickAccumulatorMS >= this._fixedTickMS
    );
  }

  _runTick(tickNowMS) {
    const tickStart = this._logTimings ? qipPlayPerfNow() : 0;
    this._flushPendingKeyEvents(tickNowMS);
    this._flushPendingPointerEvents(tickNowMS);
    this._flushRepeatKeyEvents(tickNowMS);
    const changed = qipPlayToI32(
      this._exports.tick(tickNowMS | 0),
      "tick",
    );
    const tickMS = this._logTimings ? qipPlayPerfNow() - tickStart : 0;
    return { changed, tickMS };
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
    if (!this._exports || typeof this._exports.render_output !== "function") {
      return;
    }
    if (!this._imageData || !this._ctx) {
      return;
    }

    const renderStart = this._logTimings ? qipPlayPerfNow() : 0;
    const outputLen = qipPlayToI32(
      this._exports.render_output(),
      "render_output",
    );
    if (outputLen !== this._expectedOutputBytes) {
      throw new Error(
        "qip-play render_output returned unexpected byte length " +
          String(outputLen) +
          "; expected " +
          String(this._expectedOutputBytes),
      );
    }

    const bytes = qipPlayReadSlice(
      this._memory,
      this._outputPtr,
      outputLen,
      "output_ptr/output_bytes_cap",
    );
    this._imageData.data.set(bytes);
    this._ctx.putImageData(this._imageData, 0, 0);
    const renderMS = this._logTimings ? qipPlayPerfNow() - renderStart : 0;
    if (this._logTimings && reason === "initial") {
      console.log("[qip-play] initial_render_ms=%s", renderMS.toFixed(3));
    }
    return renderMS;
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
