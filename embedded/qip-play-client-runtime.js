function qipPlayPerfNow() {
  return performance.now();
}

const QIP_PLAY_KEY_REPEAT_DELAY_MS = 250;
const QIP_PLAY_KEY_REPEAT_INTERVAL_MS = 33;
const QIP_PLAY_WASM_PAGE_SIZE_BYTES = 65536;
const QIP_PLAY_OPCODE_MEMORY_GROW = 0x40;

class QIPPlayWasmReader {
  constructor(bytes) {
    this.bytes = bytes;
    this.off = 0;
  }

  remaining() {
    return this.bytes.length - this.off;
  }

  readByte() {
    if (this.off >= this.bytes.length) {
      throw new Error("unexpected end of wasm");
    }
    return this.bytes[this.off++];
  }

  peekByte() {
    if (this.off >= this.bytes.length) {
      throw new Error("unexpected end of wasm");
    }
    return this.bytes[this.off];
  }

  readBytes(count) {
    if (count < 0 || this.remaining() < count) {
      throw new Error("unexpected end of wasm");
    }
    const start = this.off;
    this.off += count;
    return this.bytes.subarray(start, this.off);
  }

  readVarU32() {
    let result = 0;
    let shift = 0;
    for (let i = 0; i < 5; i++) {
      const b = this.readByte();
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) === 0) {
        return result >>> 0;
      }
      shift += 7;
    }
    throw new Error("invalid u32 leb128");
  }

  readVarU64Number() {
    let result = 0;
    let factor = 1;
    let finite = true;
    for (let i = 0; i < 10; i++) {
      const b = this.readByte();
      if (finite) {
        result += (b & 0x7f) * factor;
      }
      if ((b & 0x80) === 0) {
        return finite ? result : Number.POSITIVE_INFINITY;
      }
      if (factor > Number.MAX_SAFE_INTEGER / 128) {
        finite = false;
      } else {
        factor *= 128;
      }
    }
    throw new Error("invalid u64 leb128");
  }

  readVarS32() {
    let result = 0;
    let shift = 0;
    let b = 0;
    for (let i = 0; i < 5; i++) {
      b = this.readByte();
      result |= (b & 0x7f) << shift;
      shift += 7;
      if ((b & 0x80) === 0) {
        break;
      }
      if (i === 4) {
        throw new Error("invalid s32 leb128");
      }
    }
    if (shift < 32 && (b & 0x40) !== 0) {
      result |= (~0 << shift);
    }
    return result | 0;
  }

  readVarS64(maxBytes) {
    for (let i = 0; i < maxBytes; i++) {
      const b = this.readByte();
      if ((b & 0x80) === 0) {
        return;
      }
    }
    throw new Error("invalid s64 leb128");
  }

  readName() {
    const len = this.readVarU32();
    const bytes = this.readBytes(len);
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  }
}

function qipPlayReadModulePolicy(rootElement) {
  const maxMemoryRaw = rootElement.getAttribute("max-memory");
  const maxMemoryBytes = maxMemoryRaw === null ? 0 : qipPlayParsePolicyBytes(maxMemoryRaw, "max-memory");
  const rejectOpcodes = [];
  if (rootElement.hasAttribute("fixed-memory")) {
    rejectOpcodes.push(QIP_PLAY_OPCODE_MEMORY_GROW);
  }
  return { maxMemoryBytes, rejectOpcodes };
}

function qipPlayParsePolicyBytes(rawValue, attrName) {
  const value = String(rawValue).trim();
  if (!/^\d+$/.test(value)) {
    throw new Error(attrName + " must be an integer byte count");
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new Error(attrName + " is outside the supported integer range");
  }
  return parsed;
}

function qipPlayValidateWasmModulePolicy(moduleBytes, policy, label) {
  if (!policy || (policy.maxMemoryBytes === 0 && policy.rejectOpcodes.length === 0)) {
    return;
  }
  const failures = [];
  const rejectMemoryGrow = policy.rejectOpcodes.includes(QIP_PLAY_OPCODE_MEMORY_GROW);
  const bytes = new Uint8Array(moduleBytes);
  if (
    bytes.length < 8 ||
    bytes[0] !== 0x00 ||
    bytes[1] !== 0x61 ||
    bytes[2] !== 0x73 ||
    bytes[3] !== 0x6d ||
    bytes[4] !== 0x01 ||
    bytes[5] !== 0x00 ||
    bytes[6] !== 0x00 ||
    bytes[7] !== 0x00
  ) {
    throw new Error("invalid wasm module header");
  }

  const r = new QIPPlayWasmReader(bytes.subarray(8));
  let memoryIndex = 0;
  while (r.remaining() > 0) {
    const sectionID = r.readByte();
    const sectionSize = r.readVarU32();
    const payload = r.readBytes(sectionSize);
    const section = new QIPPlayWasmReader(payload);
    if (sectionID === 2) {
      memoryIndex = qipPlayScanImportSectionForPolicy(section, policy, failures, memoryIndex);
    } else if (sectionID === 5) {
      memoryIndex = qipPlayScanMemorySectionForPolicy(section, policy, failures, memoryIndex);
    } else if (sectionID === 10 && rejectMemoryGrow) {
      qipPlayScanCodeSectionForPolicy(section, failures);
    }
  }

  if (failures.length > 0) {
    throw new Error("module " + label + " rejected by policy: " + failures.join("; "));
  }
}

function qipPlayScanImportSectionForPolicy(r, policy, failures, memoryIndex) {
  const count = r.readVarU32();
  for (let i = 0; i < count; i++) {
    r.readName();
    r.readName();
    const kind = r.readByte();
    if (kind === 0x00) {
      r.readVarU32();
    } else if (kind === 0x01) {
      qipPlaySkipTableType(r);
    } else if (kind === 0x02) {
      const limit = qipPlayReadLimits(r);
      qipPlayCheckMemoryLimit(limit, memoryIndex, policy, failures);
      memoryIndex++;
    } else if (kind === 0x03) {
      qipPlaySkipGlobalType(r);
    } else if (kind === 0x04) {
      r.readByte();
      r.readVarU32();
    } else {
      throw new Error("unsupported wasm import kind 0x" + kind.toString(16));
    }
  }
  return memoryIndex;
}

function qipPlayScanMemorySectionForPolicy(r, policy, failures, memoryIndex) {
  const count = r.readVarU32();
  for (let i = 0; i < count; i++) {
    const limit = qipPlayReadLimits(r);
    qipPlayCheckMemoryLimit(limit, memoryIndex, policy, failures);
    memoryIndex++;
  }
  return memoryIndex;
}

function qipPlayReadLimits(r) {
  const flags = r.readByte();
  const memory64 = (flags & 0x04) !== 0;
  const minPages = memory64 ? r.readVarU64Number() : r.readVarU32();
  let hasMax = false;
  let maxPages = 0;
  if ((flags & 0x01) !== 0) {
    hasMax = true;
    maxPages = memory64 ? r.readVarU64Number() : r.readVarU32();
  }
  return { minPages, hasMax, maxPages };
}

function qipPlayCheckMemoryLimit(limit, memoryIndex, policy, failures) {
  if (policy.maxMemoryBytes === 0) {
    return;
  }
  if (qipPlayPagesToBytes(limit.minPages) > policy.maxMemoryBytes) {
    failures.push("memory[" + memoryIndex + "] initial size " + String(limit.minPages) + " pages exceeds max-memory " + String(policy.maxMemoryBytes) + " bytes");
  }
  if (!limit.hasMax) {
    failures.push("memory[" + memoryIndex + "] has no declared maximum");
    return;
  }
  if (qipPlayPagesToBytes(limit.maxPages) > policy.maxMemoryBytes) {
    failures.push("memory[" + memoryIndex + "] maximum " + String(limit.maxPages) + " pages exceeds max-memory " + String(policy.maxMemoryBytes) + " bytes");
  }
}

function qipPlayPagesToBytes(pages) {
  if (!Number.isFinite(pages) || pages > Number.MAX_SAFE_INTEGER / QIP_PLAY_WASM_PAGE_SIZE_BYTES) {
    return Number.POSITIVE_INFINITY;
  }
  return pages * QIP_PLAY_WASM_PAGE_SIZE_BYTES;
}

function qipPlayScanCodeSectionForPolicy(r, failures) {
  const count = r.readVarU32();
  for (let i = 0; i < count; i++) {
    const bodySize = r.readVarU32();
    qipPlayScanFunctionBodyForPolicy(new QIPPlayWasmReader(r.readBytes(bodySize)), failures);
  }
}

function qipPlayScanFunctionBodyForPolicy(r, failures) {
  const localDecls = r.readVarU32();
  for (let i = 0; i < localDecls; i++) {
    r.readVarU32();
    r.readByte();
  }
  while (r.remaining() > 0) {
    const op = r.readByte();
    switch (op) {
      case 0x00:
      case 0x01:
      case 0x05:
      case 0x0b:
      case 0x0f:
      case 0x1a:
      case 0x1b:
        break;
      case 0x02:
      case 0x03:
      case 0x04:
        qipPlayReadBlockType(r);
        break;
      case 0x0c:
      case 0x0d:
      case 0x10:
      case 0x12:
      case 0x14:
      case 0xd2:
        r.readVarU32();
        break;
      case 0x0e: {
        const targetCount = r.readVarU32();
        for (let i = 0; i < targetCount; i++) r.readVarU32();
        r.readVarU32();
        break;
      }
      case 0x11:
      case 0x13:
        r.readVarU32();
        r.readVarU32();
        break;
      case 0x1c: {
        const count = r.readVarU32();
        r.readBytes(count);
        break;
      }
      case 0x20:
      case 0x21:
      case 0x22:
      case 0x23:
      case 0x24:
      case 0x25:
      case 0x26:
        r.readVarU32();
        break;
      case 0x28:
      case 0x29:
      case 0x2a:
      case 0x2b:
      case 0x2c:
      case 0x2d:
      case 0x2e:
      case 0x2f:
      case 0x30:
      case 0x31:
      case 0x32:
      case 0x33:
      case 0x34:
      case 0x35:
      case 0x36:
      case 0x37:
      case 0x38:
      case 0x39:
      case 0x3a:
      case 0x3b:
      case 0x3c:
      case 0x3d:
      case 0x3e:
        qipPlayReadMemArg(r);
        break;
      case 0x3f:
        r.readVarU32();
        break;
      case 0x40:
        r.readVarU32();
        failures.push("violates fixed-memory policy: contains memory.grow");
        break;
      case 0x41:
        r.readVarS32();
        break;
      case 0x42:
        r.readVarS64(10);
        break;
      case 0x43:
        r.readBytes(4);
        break;
      case 0x44:
        r.readBytes(8);
        break;
      case 0xd0:
        r.readByte();
        break;
      case 0xfc:
        qipPlayReadFCImmediate(r);
        break;
      case 0xfd:
        qipPlayReadFDImmediate(r);
        break;
      case 0xfe:
        qipPlayReadFEImmediate(r);
        break;
      default:
        break;
    }
  }
}

function qipPlayReadBlockType(r) {
  const b = r.peekByte();
  if (b === 0x40 || b === 0x7f || b === 0x7e || b === 0x7d || b === 0x7c || b === 0x7b || b === 0x70 || b === 0x6f) {
    r.readByte();
    return;
  }
  r.readVarS64(5);
}

function qipPlayReadMemArg(r) {
  r.readVarU32();
  r.readVarU32();
}

function qipPlayReadFCImmediate(r) {
  const sub = r.readVarU32();
  if (sub === 8) {
    r.readVarU32();
    r.readVarU32();
  } else if (sub === 9) {
    r.readVarU32();
  } else if (sub === 10) {
    r.readVarU32();
    r.readVarU32();
  } else if (sub === 11) {
    r.readVarU32();
  } else if (sub === 12) {
    r.readVarU32();
    r.readVarU32();
  } else if (sub === 13) {
    r.readVarU32();
  } else if (sub === 14) {
    r.readVarU32();
    r.readVarU32();
  } else if (sub === 15 || sub === 16 || sub === 17) {
    r.readVarU32();
  }
}

function qipPlayReadFDImmediate(r) {
  const sub = r.readVarU32();
  if (sub <= 11 || sub === 92 || sub === 93) {
    qipPlayReadMemArg(r);
  } else if (sub === 12 || sub === 13) {
    r.readBytes(16);
  } else if (sub >= 21 && sub <= 34) {
    r.readByte();
  } else if (sub >= 84 && sub <= 91) {
    qipPlayReadMemArg(r);
    r.readByte();
  }
}

function qipPlayReadFEImmediate(r) {
  const sub = r.readVarU32();
  if (sub === 3) {
    r.readByte();
    return;
  }
  qipPlayReadMemArg(r);
}

function qipPlaySkipTableType(r) {
  r.readByte();
  qipPlayReadLimits(r);
}

function qipPlaySkipGlobalType(r) {
  r.readByte();
  r.readByte();
}

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
  if (nowMS <= 0) {
    return 0n;
  }
  return BigInt(Math.floor(nowMS));
}

function qipPlayFormatByteSize(byteLength) {
  if (byteLength < 1000) {
    return String(byteLength) + " B";
  }
  const kilobytes = byteLength / 1000;
  if (kilobytes < 100) {
    return kilobytes.toFixed(1) + " kB";
  }
  if (kilobytes < 1000) {
    return kilobytes.toFixed(0) + " kB";
  }
  const megabytes = kilobytes / 1000;
  if (megabytes < 100) {
    return megabytes.toFixed(1) + " MB";
  }
  return megabytes.toFixed(0) + " MB";
}

function qipPlayFormatMS(ms) {
  return ms.toFixed(1);
}

function qipPlayFormatCount(count) {
  return String(count).padStart(3, " ");
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

function qipPlayByteSlicesEqual(a, b) {
  if (!a || !b || a.byteLength !== b.byteLength) {
    return false;
  }

  const len = a.byteLength;
  let i = 0;
  const aAlign = a.byteOffset & 3;
  const bAlign = b.byteOffset & 3;
  if (aAlign === bAlign) {
    const prefixLen = Math.min((4 - aAlign) & 3, len);
    while (i < prefixLen) {
      if (a[i] !== b[i]) {
        return false;
      }
      i++;
    }

    const wordBytes = (len - i) & ~3;
    const a32 = new Uint32Array(a.buffer, a.byteOffset + i, wordBytes >>> 2);
    const b32 = new Uint32Array(b.buffer, b.byteOffset + i, wordBytes >>> 2);
    for (let wordIndex = 0; wordIndex < a32.length; wordIndex++) {
      if (a32[wordIndex] !== b32[wordIndex]) {
        return false;
      }
    }
    i += wordBytes;
  }

  while (i < len) {
    if (a[i] !== b[i]) {
      return false;
    }
    i++;
  }
  return true;
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

function qipPlayCustomProperty(computedStyle, propertyName, fallback) {
  if (!computedStyle) {
    return fallback;
  }
  const value = computedStyle.getPropertyValue(propertyName).trim();
  return value !== "" ? value : fallback;
}

function qipPlayPresentation(element, renderWidth) {
  const attrCanvasWidth = (element.getAttribute("canvas-width") || "").trim();
  const attrCanvasHeight = (element.getAttribute("canvas-height") || "").trim();
  const needsComputed = attrCanvasWidth === "" || attrCanvasHeight === "";
  const computedStyle = needsComputed ? getComputedStyle(element) : null;

  return {
    canvasWidth:
      attrCanvasWidth ||
      qipPlayCustomProperty(
        computedStyle,
        "--qip-play-canvas-width",
        String(renderWidth) + "px",
      ),
    canvasHeight:
      attrCanvasHeight ||
      qipPlayCustomProperty(
        computedStyle,
        "--qip-play-canvas-height",
        "auto",
      ),
  };
}

/**
 * <qip-play> is a light-DOM browser host for interactive RGBA components.
 *
 * Optional static module policy attributes:
 *
 * - max-memory="<bytes>" rejects modules whose declared memory minimum or
 *   maximum exceeds the byte cap. A module with memory but no declared maximum
 *   is rejected when this attribute is set.
 * - fixed-memory rejects modules that can grow linear memory while they run.
 */
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
    this._wasmByteLength = 0;
    this._debugStats = false;
    this._logTimings = false;
    this._lastTickMS = 0;
    this._lastRenderMS = 0;
    this._lastDrawMS = 0;
    this._lastCompareMS = 0;
    this._lastRenderUnchanged = false;

    this._boundKeyDown = null;
    this._boundKeyUp = null;
    this._boundPointer = null;
    this._boundPointerUp = null;
    this._boundPointerLeave = null;
    this._boundContextMenu = null;
    this._boundClickFocus = null;
    this._boundFrame = null;
    this._boundBlur = null;
    this._boundInputChange = null;
    this._inputElement = null;
    this._eventN = 0;
    this._tickN = 0;
    this._renderN = 0;
    this._unchangedRenderN = 0;
    this._drawN = 0;
    this._hasRenderedFrame = false;
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
    const policy = qipPlayReadModulePolicy(this);
    qipPlayValidateWasmModulePolicy(moduleBytes, policy, sourceURL);
    this._wasmByteLength = moduleBytes.byteLength;
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
    this._debugStats = this.hasAttribute("debug");
    this._logTimings = this.hasAttribute("log");

    // TODO: Support <source data-uniform-*> for qip-play, matching qip-edit.

    this._setupInputBinding(inputElement);

    this._canvas = document.createElement("canvas");
    this._canvas.width = this._renderWidth;
    this._canvas.height = this._renderHeight;
    const presentation = qipPlayPresentation(this, this._renderWidth);
    this._canvas.style.display = "block";
    this._canvas.style.width = presentation.canvasWidth;
    this._canvas.style.height = presentation.canvasHeight;
    this._canvas.style.touchAction = "none";
    this._canvas.tabIndex = this.hasAttribute("tabindex") ? this.tabIndex : 0;
    this.removeAttribute("tabindex");

    this._stats = document.createElement("aside");
    this._stats.setAttribute("aria-label", "qip-play stats");
    this._stats.style.boxSizing = "border-box";
    this._stats.style.marginTop = "6px";
    this._stats.style.maxWidth = presentation.canvasWidth;
    this._stats.style.font = "11px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace";
    this._stats.style.color = "#666";
    this._stats.style.whiteSpace = "pre-wrap";
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
    this._boundPointerLeave = () => {
      if (!this._exports || typeof this._exports.pointer_event !== "function") {
        return;
      }
      this._queuePointerEvent(0, -1, -1, this._eventNowMS());
      this._resumeLoop();
    };
    this._boundContextMenu = (event) => {
      event.preventDefault();
      event.stopPropagation();
    };

    this._boundClickFocus = () => {
      this._canvas.focus();
    };
    this._boundBlur = () => {
      this._clearKeyRepeats();
    };

    this._canvas.addEventListener("keydown", this._boundKeyDown);
    this._canvas.addEventListener("keyup", this._boundKeyUp);
    this._canvas.addEventListener("pointerdown", this._boundPointer);
    this._canvas.addEventListener("pointermove", this._boundPointer);
    this._canvas.addEventListener("pointerup", this._boundPointerUp);
    this._canvas.addEventListener("pointercancel", this._boundPointerUp);
    this._canvas.addEventListener("pointerleave", this._boundPointerLeave);
    this._canvas.addEventListener("contextmenu", this._boundContextMenu, true);
    this._canvas.addEventListener("click", this._boundClickFocus);
    this._canvas.addEventListener("blur", this._boundBlur);
  }

  _detachInputHandlers() {
    if (this._canvas) {
      if (this._boundKeyDown) {
        this._canvas.removeEventListener("keydown", this._boundKeyDown);
      }
      if (this._boundKeyUp) {
        this._canvas.removeEventListener("keyup", this._boundKeyUp);
      }
      if (this._boundPointer) {
        this._canvas.removeEventListener("pointerdown", this._boundPointer);
        this._canvas.removeEventListener("pointermove", this._boundPointer);
      }
      if (this._boundPointerUp) {
        this._canvas.removeEventListener("pointerup", this._boundPointerUp);
        this._canvas.removeEventListener("pointercancel", this._boundPointerUp);
      }
      if (this._boundPointerLeave) {
        this._canvas.removeEventListener("pointerleave", this._boundPointerLeave);
      }
      if (this._boundContextMenu) {
        this._canvas.removeEventListener(
          "contextmenu",
          this._boundContextMenu,
          true,
        );
      }
      if (this._boundClickFocus) {
        this._canvas.removeEventListener("click", this._boundClickFocus);
      }
      if (this._boundBlur) {
        this._canvas.removeEventListener("blur", this._boundBlur);
      }
    }

    this._boundKeyDown = null;
    this._boundKeyUp = null;
    this._boundPointer = null;
    this._boundPointerUp = null;
    this._boundPointerLeave = null;
    this._boundContextMenu = null;
    this._boundClickFocus = null;
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
      timeMS,
    });
  }

  _queuePointerEvent(buttonMask, x, y, timeMS) {
    this._eventN++;
    this._pendingPointerEvents.push({
      buttonMask: buttonMask | 0,
      x: x | 0,
      y: y | 0,
      timeMS,
    });
  }

  _eventNowMS() {
    if (this._timeOriginMS <= 0) {
      return 0;
    }
    const elapsed = qipPlayPerfNow() - this._timeOriginMS;
    if (elapsed <= 0) {
      return 0;
    }
    return Math.floor(elapsed);
  }

  _flushPendingKeyEvents(tickNowMS) {
    if (!this._exports || typeof this._exports.key_event !== "function") {
      this._pendingKeyEvents.length = 0;
      return { count: 0, accepted: false };
    }
    let flushed = 0;
    let accepted = false;
    while (this._pendingKeyEvents.length > 0) {
      const evt = this._pendingKeyEvents[0];
      if (evt.timeMS > tickNowMS) break;
      this._pendingKeyEvents.shift();
      const result = this._exports.key_event(
        evt.keysym,
        evt.flags,
        qipPlayNowMSArg(evt.timeMS),
      );
      if (Number(result) !== 0) accepted = true;
      flushed += 1;
    }
    return { count: flushed, accepted };
  }

  _flushPendingPointerEvents(tickNowMS) {
    if (!this._exports || typeof this._exports.pointer_event !== "function") {
      this._pendingPointerEvents.length = 0;
      return { count: 0, accepted: false };
    }
    let flushed = 0;
    let accepted = false;
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
      if (Number(result) !== 0) accepted = true;
      flushed += 1;
    }
    return { count: flushed, accepted };
  }

  _flushRepeatKeyEvents(tickNowMS) {
    if (!this._exports || typeof this._exports.key_event !== "function") {
      return { count: 0, accepted: false };
    }
    let flushed = 0;
    let accepted = false;
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
      if (Number(result) !== 0) accepted = true;
      flushed += 1;
    }
    return { count: flushed, accepted };
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

    const tickNowMS = this._elapsedFromPerfNow(nowMS);
    const eventResult = this._drainEvents(tickNowMS);
    const eventCount = eventResult.eventCount;
    const wakeDue = this._nextWakeAtMS > 0 && tickNowMS >= this._nextWakeAtMS;
    if (eventCount <= 0 && !wakeDue) {
      return;
    }
    if (!wakeDue && !eventResult.accepted) {
      if (this._logTimings) {
        console.log(
          "[qip-play] now_ms=%d events=%d next_wake_at_ms=%d tick_ms=%s render_ms=%s draw_ms=%s frame_ms=%s",
          tickNowMS,
          eventCount,
          this._nextWakeAtMS,
          "0.0",
          "0.0",
          "0.0",
          "0.0",
        );
      }
      return;
    }

    const tickResult = this._runTick(tickNowMS);
    this._nextWakeAtMS = tickResult.nextWakeAtMS;
    const renderResult = wakeDue || eventResult.accepted
      ? this._renderFrame()
      : { renderMS: 0, compareMS: 0, drawMS: 0, unchanged: false };
    if (this._logTimings) {
      console.log(
        "[qip-play] now_ms=%d events=%d next_wake_at_ms=%d tick_ms=%s render_ms=%s compare_ms=%s draw_ms=%s unchanged=%s frame_ms=%s",
        tickNowMS,
        eventCount,
        this._nextWakeAtMS,
        qipPlayFormatMS(tickResult.tickMS),
        qipPlayFormatMS(renderResult.renderMS),
        qipPlayFormatMS(renderResult.compareMS),
        qipPlayFormatMS(renderResult.drawMS),
        renderResult.unchanged ? "yes" : "no",
        qipPlayFormatMS(tickResult.tickMS + renderResult.renderMS + renderResult.compareMS + renderResult.drawMS),
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
      accepted:
        keyResult.accepted || pointerResult.accepted || repeatResult.accepted,
    };
  }

  _elapsedFromPerfNow(perfNowMS) {
    if (this._timeOriginMS <= 0) {
      return 0;
    }
    const elapsed = perfNowMS - this._timeOriginMS;
    if (elapsed <= 0) {
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
    if (nextAt === Number.MAX_SAFE_INTEGER) {
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
      return { renderMS: 0, compareMS: 0, drawMS: 0, unchanged: false };
    }
    if (!this._imageData || !this._ctx) {
      return { renderMS: 0, compareMS: 0, drawMS: 0, unchanged: false };
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

    const bytes = qipPlayReadSlice(
      this._memory,
      this._outputPtr,
      outputLen,
      "output_ptr/output_rgba8_srgb_bytes",
    );
    let compareMS = 0;
    let unchanged = false;
    if (this._debugStats && this._hasRenderedFrame) {
      const compareStart = qipPlayPerfNow();
      unchanged = qipPlayByteSlicesEqual(this._imageData.data, bytes);
      compareMS = qipPlayPerfNow() - compareStart;
      if (unchanged) {
        this._unchangedRenderN++;
      }
    }
    const drawStart = qipPlayPerfNow();
    this._imageData.data.set(bytes);
    this._ctx.putImageData(this._imageData, 0, 0);
    const drawMS = qipPlayPerfNow() - drawStart;
    this._drawN++;
    this._hasRenderedFrame = true;
    this._lastRenderMS = renderMS;
    this._lastCompareMS = compareMS;
    this._lastDrawMS = drawMS;
    this._lastRenderUnchanged = unchanged;
    this._updateStats();
    if (this._logTimings && reason === "initial") {
      console.log(
        "[qip-play] initial_render_ms=%s initial_draw_ms=%s",
        qipPlayFormatMS(renderMS),
        qipPlayFormatMS(drawMS),
      );
    }
    return { renderMS, compareMS, drawMS, unchanged };
  }

  _updateStats() {
    if (!this._stats) {
      return;
    }
    this._stats.textContent =
      "wasm " +
      qipPlayFormatByteSize(this._wasmByteLength) +
      " | memory " +
      qipPlayFormatByteSize(this._memory.buffer.byteLength) +
      " | tick " +
      qipPlayFormatCount(this._tickN) +
      " " +
      qipPlayFormatMS(this._lastTickMS) +
      " ms | render " +
      qipPlayFormatCount(this._renderN) +
      " " +
      qipPlayFormatMS(this._lastRenderMS) +
      " ms" +
      (this._debugStats
        ? " | unchanged renders " +
          String(this._unchangedRenderN) +
          " | compare " +
          qipPlayFormatMS(this._lastCompareMS) +
          " ms"
        : "");
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
