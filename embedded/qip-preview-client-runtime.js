const qipPreviewTextEncoder = new TextEncoder();
const qipPreviewTextDecoder = new TextDecoder("utf-8", { fatal: true });

function qipPreviewNowMS() {
  if (typeof performance !== "undefined" && typeof performance.now === "function") {
    return performance.now();
  }
  return Date.now();
}

function qipPreviewFormatByteSize(byteLength) {
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

function qipPreviewFormatMS(ms) {
  return ms.toFixed(1) + " ms";
}

const QIP_PREVIEW_WASM_PAGE_SIZE_BYTES = 65536;
const QIP_PREVIEW_OPCODE_MEMORY_GROW = 0x40;

class QIPPreviewWasmReader {
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
    return qipPreviewTextDecoder.decode(bytes);
  }
}

function qipPreviewReadModulePolicy(rootElement) {
  const maxMemoryRaw = rootElement.getAttribute("max-memory");
  const maxMemoryBytes = maxMemoryRaw === null ? 0 : qipPreviewParsePolicyBytes(maxMemoryRaw, "max-memory");
  const rejectOpcodes = [];
  if (rootElement.hasAttribute("fixed-memory")) {
    rejectOpcodes.push(QIP_PREVIEW_OPCODE_MEMORY_GROW);
  }
  return { maxMemoryBytes, rejectOpcodes };
}

function qipPreviewParsePolicyBytes(rawValue, attrName) {
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

function qipPreviewValidateWasmModulePolicy(moduleBytes, policy, label) {
  if (!policy || (policy.maxMemoryBytes === 0 && policy.rejectOpcodes.length === 0)) {
    return;
  }
  const failures = [];
  const rejectMemoryGrow = policy.rejectOpcodes.includes(QIP_PREVIEW_OPCODE_MEMORY_GROW);
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

  const r = new QIPPreviewWasmReader(bytes.subarray(8));
  let memoryIndex = 0;
  while (r.remaining() > 0) {
    const sectionID = r.readByte();
    const sectionSize = r.readVarU32();
    const payload = r.readBytes(sectionSize);
    const section = new QIPPreviewWasmReader(payload);
    if (sectionID === 2) {
      memoryIndex = qipPreviewScanImportSectionForPolicy(section, policy, failures, memoryIndex);
    } else if (sectionID === 5) {
      memoryIndex = qipPreviewScanMemorySectionForPolicy(section, policy, failures, memoryIndex);
    } else if (sectionID === 10 && rejectMemoryGrow) {
      qipPreviewScanCodeSectionForPolicy(section, failures);
    }
  }

  if (failures.length > 0) {
    throw new Error("module " + label + " rejected by policy: " + failures.join("; "));
  }
}

function qipPreviewScanImportSectionForPolicy(r, policy, failures, memoryIndex) {
  const count = r.readVarU32();
  for (let i = 0; i < count; i++) {
    r.readName();
    r.readName();
    const kind = r.readByte();
    if (kind === 0x00) {
      r.readVarU32();
    } else if (kind === 0x01) {
      qipPreviewSkipTableType(r);
    } else if (kind === 0x02) {
      const limit = qipPreviewReadLimits(r);
      qipPreviewCheckMemoryLimit(limit, memoryIndex, policy, failures);
      memoryIndex++;
    } else if (kind === 0x03) {
      qipPreviewSkipGlobalType(r);
    } else if (kind === 0x04) {
      r.readByte();
      r.readVarU32();
    } else {
      throw new Error("unsupported wasm import kind 0x" + kind.toString(16));
    }
  }
  return memoryIndex;
}

function qipPreviewScanMemorySectionForPolicy(r, policy, failures, memoryIndex) {
  const count = r.readVarU32();
  for (let i = 0; i < count; i++) {
    const limit = qipPreviewReadLimits(r);
    qipPreviewCheckMemoryLimit(limit, memoryIndex, policy, failures);
    memoryIndex++;
  }
  return memoryIndex;
}

function qipPreviewReadLimits(r) {
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

function qipPreviewCheckMemoryLimit(limit, memoryIndex, policy, failures) {
  if (policy.maxMemoryBytes === 0) {
    return;
  }
  if (qipPreviewPagesToBytes(limit.minPages) > policy.maxMemoryBytes) {
    failures.push("memory[" + memoryIndex + "] initial size " + String(limit.minPages) + " pages exceeds max-memory " + String(policy.maxMemoryBytes) + " bytes");
  }
  if (!limit.hasMax) {
    failures.push("memory[" + memoryIndex + "] has no declared maximum");
    return;
  }
  if (qipPreviewPagesToBytes(limit.maxPages) > policy.maxMemoryBytes) {
    failures.push("memory[" + memoryIndex + "] maximum " + String(limit.maxPages) + " pages exceeds max-memory " + String(policy.maxMemoryBytes) + " bytes");
  }
}

function qipPreviewPagesToBytes(pages) {
  if (!Number.isFinite(pages) || pages > Number.MAX_SAFE_INTEGER / QIP_PREVIEW_WASM_PAGE_SIZE_BYTES) {
    return Number.POSITIVE_INFINITY;
  }
  return pages * QIP_PREVIEW_WASM_PAGE_SIZE_BYTES;
}

function qipPreviewScanCodeSectionForPolicy(r, failures) {
  const count = r.readVarU32();
  for (let i = 0; i < count; i++) {
    const bodySize = r.readVarU32();
    qipPreviewScanFunctionBodyForPolicy(new QIPPreviewWasmReader(r.readBytes(bodySize)), failures);
  }
}

function qipPreviewScanFunctionBodyForPolicy(r, failures) {
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
        qipPreviewReadBlockType(r);
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
        qipPreviewReadMemArg(r);
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
        qipPreviewReadFCImmediate(r);
        break;
      case 0xfd:
        qipPreviewReadFDImmediate(r);
        break;
      case 0xfe:
        qipPreviewReadFEImmediate(r);
        break;
      default:
        break;
    }
  }
}

function qipPreviewReadBlockType(r) {
  const b = r.peekByte();
  if (b === 0x40 || b === 0x7f || b === 0x7e || b === 0x7d || b === 0x7c || b === 0x7b || b === 0x70 || b === 0x6f) {
    r.readByte();
    return;
  }
  r.readVarS64(5);
}

function qipPreviewReadMemArg(r) {
  r.readVarU32();
  r.readVarU32();
}

function qipPreviewReadFCImmediate(r) {
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

function qipPreviewReadFDImmediate(r) {
  const sub = r.readVarU32();
  if (sub <= 11 || sub === 92 || sub === 93) {
    qipPreviewReadMemArg(r);
  } else if (sub === 12 || sub === 13) {
    r.readBytes(16);
  } else if (sub >= 21 && sub <= 34) {
    r.readByte();
  } else if (sub >= 84 && sub <= 91) {
    qipPreviewReadMemArg(r);
    r.readByte();
  }
}

function qipPreviewReadFEImmediate(r) {
  const sub = r.readVarU32();
  if (sub === 3) {
    r.readByte();
    return;
  }
  qipPreviewReadMemArg(r);
}

function qipPreviewSkipTableType(r) {
  r.readByte();
  qipPreviewReadLimits(r);
}

function qipPreviewSkipGlobalType(r) {
  r.readByte();
  r.readByte();
}

function qipPreviewToI32(value, label) {
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

function qipPreviewReadI32Export(exportsObj, exportName) {
  const value = exportsObj[exportName];
  if (typeof value === "function") {
    return qipPreviewToI32(value(), exportName);
  }
  if (value instanceof WebAssembly.Global) {
    return qipPreviewToI32(value.value, exportName);
  }
  throw new Error("preview module missing export " + exportName);
}

function qipPreviewReadSlice(memory, ptr, len, label) {
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
  return mem.slice(start, end);
}

function qipPreviewNormalizeContentType(value) {
  if (typeof value !== "string") {
    return "";
  }
  const trimmed = value.trim().toLowerCase();
  if (trimmed === "") {
    return "";
  }
  const semi = trimmed.indexOf(";");
  if (semi === -1) {
    return trimmed;
  }
  return trimmed.slice(0, semi).trim();
}

function qipPreviewReadDeclaredContentType(exportsObj, ptrExport, sizeExport) {
  if (!(ptrExport in exportsObj) || !(sizeExport in exportsObj)) {
    return "";
  }
  const size = qipPreviewReadI32Export(exportsObj, sizeExport);
  if (size <= 0) {
    return "";
  }
  const ptr = qipPreviewReadI32Export(exportsObj, ptrExport);
  const bytes = qipPreviewReadSlice(exportsObj.memory, ptr, size, ptrExport + "/" + sizeExport);
  const text = qipPreviewTextDecoder.decode(bytes);
  return qipPreviewNormalizeContentType(text);
}

function qipPreviewParseUniformAttempts(rawValue) {
  const value = String(rawValue).trim();
  if (value === "") {
    throw new Error("uniform value must not be empty");
  }

  const parsedColor = qipPreviewParseColorInputValue(value);
  if (parsedColor !== null) {
    return [parsedColor, BigInt(parsedColor)];
  }

  if (/^[+-]?0x[0-9a-f]+$/i.test(value) || /^[+-]?\d+$/.test(value)) {
    const bigValue = BigInt(value);
    const numberValue = Number(bigValue);
    if (Number.isSafeInteger(numberValue)) {
      return [numberValue, bigValue];
    }
    return [bigValue];
  }

  const floatValue = Number(value);
  if (!Number.isFinite(floatValue)) {
    throw new Error("uniform value is not a finite number");
  }
  return [floatValue];
}

function qipPreviewApplyUniform(exportsObj, key, rawValue) {
  const setterName = "uniform_set_" + key;
  const setter = exportsObj[setterName];
  if (typeof setter !== "function") {
    throw new Error("preview module missing export " + setterName);
  }
  let attempts;
  try {
    attempts = qipPreviewParseUniformAttempts(rawValue);
  } catch (err) {
    const detail = err instanceof Error ? err.message : String(err);
    console.error("qip-preview uniform parse error", {
      key,
      value: rawValue,
      valueType: typeof rawValue,
      error: detail,
    });
    throw err;
  }

  let lastErr = null;
  for (const value of attempts) {
    try {
      setter(value);
      return;
    } catch (err) {
      lastErr = err;
    }
  }

  const detail = lastErr instanceof Error ? lastErr.message : String(lastErr);
  console.error("qip-preview uniform set error", {
    key,
    value: rawValue,
    valueType: typeof rawValue,
    attempts: attempts.map((v) => typeof v === "bigint" ? (v.toString() + "n") : String(v)),
    error: detail,
  });
  throw new Error("failed to set uniform " + key + ": " + detail);
}

function qipPreviewIsTextContentType(contentType) {
  return contentType.startsWith("text/") ||
    contentType === "application/json" ||
    contentType === "application/javascript" ||
    contentType === "application/xml" ||
    contentType.endsWith("+json") ||
    contentType.endsWith("+xml");
}

function qipPreviewIsHTMLContentType(contentType) {
  return contentType === "text/html";
}

function qipPreviewGuessImageContentType(bytes) {
  if (bytes.length >= 8 &&
      bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47 &&
      bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a) {
    return "image/png";
  }
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return "image/jpeg";
  }
  if (bytes.length >= 6 &&
      bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46 &&
      bytes[3] === 0x38 && (bytes[4] === 0x37 || bytes[4] === 0x39) && bytes[5] === 0x61) {
    return "image/gif";
  }
  if (bytes.length >= 2 && bytes[0] === 0x42 && bytes[1] === 0x4d) {
    return "image/bmp";
  }
  if (bytes.length >= 4 && bytes[0] === 0x00 && bytes[1] === 0x00 && bytes[2] === 0x01 && bytes[3] === 0x00) {
    return "image/x-icon";
  }
  if (bytes.length >= 12 &&
      bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 &&
      bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) {
    return "image/webp";
  }
  return "";
}

function qipPreviewGuessDisplayContentType(bytes, declared) {
  const normalized = qipPreviewNormalizeContentType(declared);
  if (normalized !== "") {
    return normalized;
  }
  const guessedImage = qipPreviewGuessImageContentType(bytes);
  if (guessedImage !== "") {
    return guessedImage;
  }
  try {
    qipPreviewTextDecoder.decode(bytes);
    return "text/plain";
  } catch (_) {
    return "";
  }
}

function qipPreviewFormatBinary(bytes) {
  const max = Math.min(bytes.length, 256);
  let hex = "";
  for (let i = 0; i < max; i += 1) {
    if (i > 0 && i % 16 === 0) {
      hex += "\n";
    } else if (i > 0) {
      hex += " ";
    }
    const value = bytes[i].toString(16).padStart(2, "0");
    hex += value;
  }
  if (bytes.length > max) {
    hex += "\n...";
  }
  return "Binary output (" + String(bytes.length) + " bytes)\n" + hex;
}

function qipPreviewExtractUniforms(sourceElement) {
  const pairs = [];
  const names = sourceElement.getAttributeNames();
  for (const attrName of names) {
    if (!attrName.startsWith("data-uniform-")) {
      continue;
    }
    const key = attrName.slice("data-uniform-".length).trim();
    if (key === "") {
      continue;
    }
    const rawValue = sourceElement.getAttribute(attrName);
    if (rawValue === null) {
      continue;
    }
    const trimmed = rawValue.trim();
    if (trimmed !== "") {
      pairs.push({
        key,
        staticValue: rawValue,
        inputElement: null,
      });
      continue;
    }
    const inputElement = qipPreviewFindUniformInputElement(sourceElement, key);
    if (!inputElement) {
      throw new Error(
        "<source> uniform " + key + " requires an input with name=\"uniform-" + key + "\" in the same <qip-preview> when " + attrName + " is empty",
      );
    }
    pairs.push({
      key,
      staticValue: null,
      inputElement,
    });
  }
  pairs.sort((a, b) => a.key.localeCompare(b.key));
  return pairs;
}

function qipPreviewFindUniformInputElement(sourceElement, key) {
  const name = "uniform-" + key;
  const root = sourceElement.closest("qip-preview");
  if (root) {
    const named = root.querySelectorAll("[name]");
    for (const candidate of named) {
      if (typeof candidate.getAttribute === "function" && candidate.getAttribute("name") === name) {
        return candidate;
      }
    }
  }
  return null;
}

function qipPreviewReadUniformValue(uniform) {
  if (uniform.inputElement) {
    const element = uniform.inputElement;
    if (element instanceof HTMLInputElement) {
      const inputType = (element.type || "").toLowerCase();
      const declaredType = (element.getAttribute("type") || "").toLowerCase();
      if (inputType === "color" || declaredType === "color") {
        const parsedColor = qipPreviewParseColorInputValue(element.value || "");
        if (parsedColor === null) {
          throw new Error("color uniform input must be a hex color (#rgb, #rrggbb, #rgba, #rrggbbaa)");
        }
        return parsedColor;
      }
      return element.value || "";
    }
    if (element instanceof HTMLTextAreaElement || element instanceof HTMLSelectElement) {
      return element.value || "";
    }
    return (element.textContent || "").trim();
  }
  return uniform.staticValue || "";
}

function qipPreviewParseColorInputValue(rawValue) {
  const value = String(rawValue).trim();
  let hex = "";
  if (/^#[0-9a-f]{3}$/i.test(value)) {
    const r = value[1];
    const g = value[2];
    const b = value[3];
    hex = r + r + g + g + b + b + "ff";
  } else if (/^#[0-9a-f]{4}$/i.test(value)) {
    const r = value[1];
    const g = value[2];
    const b = value[3];
    const a = value[4];
    hex = r + r + g + g + b + b + a + a;
  } else if (/^#[0-9a-f]{6}$/i.test(value)) {
    hex = value.slice(1) + "ff";
  } else if (/^#[0-9a-f]{8}$/i.test(value)) {
    hex = value.slice(1);
  } else {
    return null;
  }
  const parsed = Number.parseInt(hex, 16);
  if (!Number.isFinite(parsed)) {
    return null;
  }
  return parsed >>> 0;
}

function qipPreviewSourceType(sourceElement) {
  return (sourceElement.getAttribute("type") || "application/wasm").trim().toLowerCase();
}

// A <source name="input"> is the input; every other <source> is a pipeline
// stage. Because the name carries the meaning, the input may itself be wasm.
function qipPreviewIsDataSource(sourceElement) {
  return sourceElement.getAttribute("name") === "input";
}

async function qipPreviewFetchSourceBytes(sourceElement, label) {
  const srcRaw = (sourceElement.getAttribute("src") || "").trim();
  if (srcRaw === "") {
    throw new Error("<source> inside <qip-preview> requires a non-empty src");
  }
  const sourceURL = new URL(srcRaw, document.baseURI).toString();
  const response = await fetch(sourceURL);
  if (!response.ok) {
    throw new Error("failed to fetch " + label + " " + sourceURL + " (" + String(response.status) + ")");
  }
  const bytes = await response.arrayBuffer();
  return { sourceURL, bytes };
}

async function qipPreviewLoadStage(sourceElement, policy) {
  const { sourceURL, bytes } = await qipPreviewFetchSourceBytes(sourceElement, "module");
  qipPreviewValidateWasmModulePolicy(bytes, policy, sourceURL);
  const module = await WebAssembly.compile(bytes);
  return {
    src: sourceURL,
    module,
    moduleBytes: bytes.byteLength,
    uniforms: qipPreviewExtractUniforms(sourceElement),
    exports: null,
  };
}

// Fetches the <source name="input"> payload. Its type attribute becomes the
// pipeline's initial content type.
async function qipPreviewLoadDataSource(sourceElement) {
  const { sourceURL, bytes } = await qipPreviewFetchSourceBytes(sourceElement, "input payload");
  return {
    src: sourceURL,
    bytes: new Uint8Array(bytes),
    contentType: qipPreviewNormalizeContentType(qipPreviewSourceType(sourceElement)),
  };
}

function qipPreviewWriteInput(exportsObj, inputBytes) {
  const inputPtr = qipPreviewReadI32Export(exportsObj, "input_ptr");
  const inputCapName = ("input_utf8_cap" in exportsObj) ? "input_utf8_cap" : "input_bytes_cap";
  const inputCap = qipPreviewReadI32Export(exportsObj, inputCapName);
  if (inputPtr < 0 || inputCap < 0) {
    throw new Error("module returned invalid input pointer/capacity");
  }
  if (inputBytes.length > inputCap) {
    throw new Error("input size exceeds " + inputCapName);
  }
  const start = inputPtr >>> 0;
  const end = start + inputBytes.length;
  const mem = new Uint8Array(exportsObj.memory.buffer);
  if (end < start || end > mem.length) {
    throw new Error("input write exceeds wasm memory bounds");
  }
  mem.set(inputBytes, start);
}

function qipPreviewReadOutputBytes(exportsObj, outputLen) {
  if (outputLen < 0) {
    throw new Error("render returned negative output size");
  }
  const outputPtr = qipPreviewReadI32Export(exportsObj, "output_ptr");
  if (outputPtr < 0) {
    throw new Error("module returned invalid output pointer");
  }

  let capName = "";
  if ("output_utf8_cap" in exportsObj) {
    capName = "output_utf8_cap";
  } else if ("output_bytes_cap" in exportsObj) {
    capName = "output_bytes_cap";
  } else {
    throw new Error("preview module missing output_utf8_cap/output_bytes_cap");
  }

  const cap = qipPreviewReadI32Export(exportsObj, capName);
  if (cap < 0) {
    throw new Error("module returned invalid " + capName);
  }
  if (outputLen > cap) {
    throw new Error("render output size exceeds " + capName);
  }
  return qipPreviewReadSlice(exportsObj.memory, outputPtr, outputLen, "output_ptr/" + capName);
}

async function qipPreviewStageExports(stage) {
  if (stage.exports) {
    return stage.exports;
  }
  const instantiated = await WebAssembly.instantiate(stage.module, {});
  const exportsObj = (instantiated && instantiated.instance && instantiated.instance.exports) ||
    (instantiated && instantiated.exports) ||
    null;
  if (!exportsObj) {
    throw new Error("failed to access wasm exports for preview module");
  }
  if (!(exportsObj.memory instanceof WebAssembly.Memory)) {
    throw new Error("preview module must export memory");
  }
  if (typeof exportsObj.render !== "function") {
    throw new Error("preview module missing export render");
  }
  stage.exports = exportsObj;
  return exportsObj;
}

async function qipPreviewRunStage(stage, input) {
  // One instance is kept per stage and re-rendered, as the component contract
  // intends; re-instantiating per render churns linear memory allocations. A
  // failed render drops the instance so the next run starts fresh.
  const exportsObj = await qipPreviewStageExports(stage);
  try {
    const expectedInputType = qipPreviewReadDeclaredContentType(exportsObj, "input_content_type_ptr", "input_content_type_size");
    if (expectedInputType !== "" && input.contentType !== "" && expectedInputType !== input.contentType) {
      throw new Error("input content type mismatch: expected " + expectedInputType + ", got " + input.contentType);
    }

    qipPreviewWriteInput(exportsObj, input.bytes);
    for (const uniform of stage.uniforms) {
      qipPreviewApplyUniform(exportsObj, uniform.key, qipPreviewReadUniformValue(uniform));
    }

    const outputLen = qipPreviewToI32(exportsObj.render(input.bytes.length), "render");
    const outputBytes = qipPreviewReadOutputBytes(exportsObj, outputLen);
    let outputContentType = qipPreviewReadDeclaredContentType(exportsObj, "output_content_type_ptr", "output_content_type_size");
    if (outputContentType === "") {
      // A bytes-in, UTF-8-out component produces new text; the incoming
      // (binary) pipeline content type does not describe its output.
      const readsUTF8 = "input_utf8_cap" in exportsObj;
      const emitsUTF8 = "output_utf8_cap" in exportsObj;
      if (readsUTF8 || !emitsUTF8) {
        outputContentType = input.contentType;
      }
    }
    return {
      bytes: outputBytes,
      contentType: outputContentType,
    };
  } catch (err) {
    stage.exports = null;
    throw err;
  }
}

function qipPreviewIsFileInput(inputElement) {
  return inputElement instanceof HTMLInputElement &&
    (inputElement.type || "").toLowerCase() === "file";
}

// Resolves the pipeline's initial bytes and content type. A chosen file wins,
// then the input <source>, then the input element's text.
async function qipPreviewReadInput(inputElement, payload) {
  if (inputElement && qipPreviewIsFileInput(inputElement)) {
    const file = inputElement.files && inputElement.files[0];
    if (file) {
      const bytes = new Uint8Array(await file.arrayBuffer());
      return {
        bytes,
        contentType: qipPreviewNormalizeContentType(file.type || ""),
      };
    }
    if (payload) {
      return { bytes: payload.bytes, contentType: payload.contentType };
    }
    return { bytes: new Uint8Array(0), contentType: "" };
  }
  if (payload) {
    return { bytes: payload.bytes, contentType: payload.contentType };
  }
  if (!inputElement) {
    return { bytes: new Uint8Array(0), contentType: "" };
  }
  if (inputElement instanceof HTMLTextAreaElement || inputElement instanceof HTMLInputElement) {
    return {
      bytes: qipPreviewTextEncoder.encode(inputElement.value || ""),
      contentType: "",
    };
  }
  return {
    bytes: qipPreviewTextEncoder.encode((inputElement.textContent || "").trim()),
    contentType: "",
  };
}

function qipPreviewEscapeHTML(text) {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function qipPreviewFindTextOutputTarget(outputElement) {
  return outputElement.querySelector("pre > code, iframe");
}

function qipPreviewIsElementNamed(element, localName) {
  return element && typeof element.localName === "string" && element.localName.toLowerCase() === localName;
}

function qipPreviewSetGeneratedAlertRole(outputElement) {
  if (!outputElement.hasAttribute("role")) {
    outputElement.setAttribute("role", "alert");
    outputElement.setAttribute("data-qip-generated-alert-role", "true");
  }
}

function qipPreviewClearGeneratedAlertRole(outputElement) {
  if (outputElement.getAttribute("data-qip-generated-alert-role") === "true") {
    outputElement.removeAttribute("role");
    outputElement.removeAttribute("data-qip-generated-alert-role");
  }
}

const QIP_PREVIEW_IFRAME_STYLE = "\n<style>:where(body){font-family:sans-serif}</style>";

function qipPreviewSetIframeSrcdoc(iframeElement, html, includePreviewStyle) {
  const srcdoc = includePreviewStyle ? html + QIP_PREVIEW_IFRAME_STYLE : html;
  iframeElement.srcdoc = srcdoc;
  iframeElement.setAttribute("srcdoc", srcdoc);
}

function qipPreviewRenderTextOutput(outputElement, text, contentType, isError) {
  const target = qipPreviewFindTextOutputTarget(outputElement);
  if (qipPreviewIsElementNamed(target, "iframe")) {
    if (!target.hasAttribute("sandbox")) {
      target.setAttribute("sandbox", "");
    }
    if (isError) {
      qipPreviewSetIframeSrcdoc(target, "<pre role=\"alert\">" + qipPreviewEscapeHTML(text) + "</pre>", false);
      return;
    }
    qipPreviewSetIframeSrcdoc(target, text, qipPreviewIsHTMLContentType(contentType));
    return;
  }
  if (target) {
    target.textContent = text;
    return;
  }
  outputElement.textContent = text;
}

/**
 * <qip-preview> is a light-DOM browser host for Content components.
 *
 * The element reads input from the first child with name="input", runs each
 * <source type="application/wasm"> as a QIP pipeline stage, then writes the same
 * output bytes into every <output name="output"> child. Multiple outputs are
 * views of one component result, not multiple component return values.
 *
 * Binary input has two HTML-native forms:
 *
 * - A <source name="input" src="..." type="..."> is fetched as the input; its
 *   type attribute becomes the pipeline's initial content type.
 * - An <input type="file" name="input"> supplies the chosen file's bytes. With
 *   no file selected it falls back to the input <source>, so a page can ship
 *   default data that visitors override with their own file.
 *
 * Each <output> may declare its preferred view with normal HTML:
 *
 * - <pre><code></code></pre> receives decoded UTF-8 output as textContent.
 * - <iframe sandbox></iframe> receives decoded UTF-8 output as srcdoc. For
 *   text/html output, a minimal preview style is appended.
 * - <img> receives image output through an object URL.
 * - Without a recognized child, decoded text or a small binary hex preview is
 *   written directly to the <output> element.
 *
 * Text views are used only after the bytes decode as UTF-8 or the content type
 * is a known text type. Image views are used only for image/* content types.
 *
 * Optional static module policy attributes:
 *
 * - max-memory="<bytes>" rejects modules whose declared memory minimum or
 *   maximum exceeds the byte cap. A module with memory but no declared maximum
 *   is rejected when this attribute is set.
 * - fixed-memory rejects modules that can grow linear memory while they run.
 */
class QIPPreviewElement extends HTMLElement {
  constructor() {
    super();
    this._started = false;
    this._stages = [];
    this._payload = null;
    this._inputElement = null;
    this._outputElements = [];
    this._runToken = 0;
    this._boundControlListener = null;
    this._objectURLs = [];
    this._moduleBytesTotal = 0;
    this._runRequestID = 0;
    this._queuedRunToken = 0;
  }

  async connectedCallback() {
    if (this._started) {
      return;
    }
    this._started = true;
    try {
      await this._init();
      this._scheduleRun();
    } catch (err) {
      this._renderError(err);
    }
  }

  disconnectedCallback() {
    if (this._boundControlListener) {
      this.removeEventListener("input", this._boundControlListener);
      this.removeEventListener("change", this._boundControlListener);
    }
    if (this._runRequestID !== 0 && typeof cancelAnimationFrame === "function") {
      cancelAnimationFrame(this._runRequestID);
      this._runRequestID = 0;
    }
    this._boundControlListener = null;
    this._revokeObjectURLs();
  }

  async _init() {
    const sourceElements = Array.from(this.querySelectorAll("source"));
    const moduleSourceElements = [];
    const dataSourceElements = [];
    for (const sourceElement of sourceElements) {
      if (qipPreviewIsDataSource(sourceElement)) {
        dataSourceElements.push(sourceElement);
        continue;
      }
      const sourceType = qipPreviewSourceType(sourceElement);
      if (sourceType !== "application/wasm") {
        throw new Error(
          "pipeline <source> must be application/wasm, got " + sourceType + "; use name=\"input\" for the input",
        );
      }
      moduleSourceElements.push(sourceElement);
    }
    if (moduleSourceElements.length === 0) {
      throw new Error("<qip-preview> requires at least one <source> module");
    }
    if (dataSourceElements.length > 1) {
      throw new Error("<qip-preview> allows at most one non-wasm data <source>");
    }

    const policy = qipPreviewReadModulePolicy(this);
    this._stages = [];
    this._moduleBytesTotal = 0;
    for (const sourceElement of moduleSourceElements) {
      const stage = await qipPreviewLoadStage(sourceElement, policy);
      this._stages.push(stage);
      this._moduleBytesTotal += stage.moduleBytes;
    }
    this.dataset.moduleBytesTotal = String(this._moduleBytesTotal);
    this.dataset.wasmSize = qipPreviewFormatByteSize(this._moduleBytesTotal);

    this._payload = null;
    if (dataSourceElements.length === 1) {
      this._payload = await qipPreviewLoadDataSource(dataSourceElements[0]);
    }

    this._inputElement = null;
    for (const candidate of this.querySelectorAll("[name='input']")) {
      if (!qipPreviewIsElementNamed(candidate, "source")) {
        this._inputElement = candidate;
        break;
      }
    }
    if (!this._inputElement && !this._payload) {
      throw new Error("<qip-preview> requires a child input with name=\"input\" or a data <source>");
    }
    this._outputElements = Array.from(this.querySelectorAll("output[name='output']"));
    if (this._outputElements.length === 0) {
      throw new Error("<qip-preview> requires a child output with name=\"output\"");
    }

    this._boundControlListener = () => {
      this._scheduleRun();
    };
    this.addEventListener("input", this._boundControlListener);
    this.addEventListener("change", this._boundControlListener);
  }

  _scheduleRun() {
    const token = ++this._runToken;
    this._queuedRunToken = token;
    if (this._runRequestID !== 0) {
      return;
    }
    const flushRun = () => {
      this._runRequestID = 0;
      const nextToken = this._queuedRunToken;
      this._runPipeline(nextToken).catch((err) => {
        if (nextToken === this._runToken) {
          this._renderError(err);
        }
      });
    };
    if (typeof requestAnimationFrame === "function") {
      this._runRequestID = requestAnimationFrame(flushRun);
      return;
    }
    flushRun();
  }

  async _runPipeline(token) {
    if ((!this._inputElement && !this._payload) || this._outputElements.length === 0) {
      throw new Error("qip-preview is not initialized");
    }
    const startedMS = qipPreviewNowMS();
    try {
      let current = await qipPreviewReadInput(this._inputElement, this._payload);
      if (token !== this._runToken) {
        return;
      }
      for (const stage of this._stages) {
        current = await qipPreviewRunStage(stage, current);
        if (token !== this._runToken) {
          return;
        }
      }
      if (token !== this._runToken) {
        return;
      }
      this._renderResult(current);
    } finally {
      if (token === this._runToken) {
        const elapsedMS = Math.max(0, qipPreviewNowMS() - startedMS);
        this.dataset.runMs = String(Math.round(elapsedMS));
        this._updateStats(elapsedMS);
      }
    }
  }

  _updateStats(elapsedMS) {
    let memoryBytesTotal = 0;
    for (const stage of this._stages) {
      if (stage.exports && stage.exports.memory instanceof WebAssembly.Memory) {
        memoryBytesTotal += stage.exports.memory.buffer.byteLength;
      }
    }
    this.dataset.wasmSize = qipPreviewFormatByteSize(this._moduleBytesTotal);
    this.dataset.memoryBytesTotal = String(memoryBytesTotal);
    this.dataset.memorySize = qipPreviewFormatByteSize(memoryBytesTotal);
    this.dataset.renderTime = qipPreviewFormatMS(elapsedMS);
  }

  _renderResult(result) {
    if (this._outputElements.length === 0) {
      return;
    }
    this._revokeObjectURLs();
    const contentType = qipPreviewGuessDisplayContentType(result.bytes, result.contentType);
    const isImage = contentType.startsWith("image/");
    let decodedText = null;
    let fallbackText = null;
    if (contentType === "" || qipPreviewIsTextContentType(contentType)) {
      try {
        decodedText = qipPreviewTextDecoder.decode(result.bytes);
      } catch (_) {
        fallbackText = qipPreviewFormatBinary(result.bytes);
      }
    } else if (!isImage) {
      fallbackText = qipPreviewFormatBinary(result.bytes);
    }

    let imageURL = "";
    for (const outputElement of this._outputElements) {
      qipPreviewClearGeneratedAlertRole(outputElement);
      if (isImage) {
        const imageElement = outputElement.querySelector("img");
        if (imageElement) {
          if (imageURL === "") {
            const blob = new Blob([result.bytes], { type: contentType });
            imageURL = URL.createObjectURL(blob);
          }
          if (!imageElement.hasAttribute("alt")) {
            imageElement.alt = "qip-preview output";
          }
          imageElement.src = imageURL;
          continue;
        }
      }
      if (decodedText !== null) {
        qipPreviewRenderTextOutput(outputElement, decodedText, contentType, false);
      } else {
        outputElement.textContent = fallbackText || qipPreviewFormatBinary(result.bytes);
      }
    }
    if (imageURL !== "") {
      this._objectURLs.push(imageURL);
    }
  }

  _renderError(err) {
    if (this._outputElements.length === 0) {
      const fallback = document.createElement("pre");
      fallback.setAttribute("role", "alert");
      const message = err instanceof Error ? err.message : String(err);
      fallback.textContent = "Preview error: " + message;
      this.replaceChildren(fallback);
      return;
    }
    this._revokeObjectURLs();
    const message = err instanceof Error ? err.message : String(err);
    for (const outputElement of this._outputElements) {
      qipPreviewSetGeneratedAlertRole(outputElement);
      qipPreviewRenderTextOutput(outputElement, "Preview error: " + message, "text/plain", true);
    }
  }

  _revokeObjectURLs() {
    for (const objectURL of this._objectURLs) {
      URL.revokeObjectURL(objectURL);
    }
    this._objectURLs = [];
  }
}

if (!customElements.get("qip-preview")) {
  customElements.define("qip-preview", QIPPreviewElement);
}
