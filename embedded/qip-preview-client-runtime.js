const qipPreviewTextEncoder = new TextEncoder();
const qipPreviewTextDecoder = new TextDecoder("utf-8", { fatal: true });

function qipPreviewNowMS() {
  if (typeof performance !== "undefined" && typeof performance.now === "function") {
    return performance.now();
  }
  return Date.now();
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

async function qipPreviewLoadStage(sourceElement) {
  const srcRaw = (sourceElement.getAttribute("src") || "").trim();
  if (srcRaw === "") {
    throw new Error("<source> inside <qip-preview> requires a non-empty src");
  }
  const sourceType = (sourceElement.getAttribute("type") || "application/wasm").trim().toLowerCase();
  if (sourceType !== "" && sourceType !== "application/wasm") {
    throw new Error("unsupported <source> type in <qip-preview>: " + sourceType);
  }
  const sourceURL = new URL(srcRaw, document.baseURI).toString();
  const response = await fetch(sourceURL);
  if (!response.ok) {
    throw new Error("failed to fetch module " + sourceURL + " (" + String(response.status) + ")");
  }
  const bytes = await response.arrayBuffer();
  const module = await WebAssembly.compile(bytes);
  return {
    src: sourceURL,
    module,
    moduleBytes: bytes.byteLength,
    uniforms: qipPreviewExtractUniforms(sourceElement),
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
  let byteLen = outputLen;
  if ("output_utf8_cap" in exportsObj) {
    capName = "output_utf8_cap";
  } else if ("output_bytes_cap" in exportsObj) {
    capName = "output_bytes_cap";
  } else if ("output_i32_cap" in exportsObj) {
    capName = "output_i32_cap";
    byteLen = outputLen * 4;
  } else {
    throw new Error("preview module missing output_utf8_cap/output_bytes_cap/output_i32_cap");
  }

  const cap = qipPreviewReadI32Export(exportsObj, capName);
  if (cap < 0) {
    throw new Error("module returned invalid " + capName);
  }
  if (outputLen > cap) {
    throw new Error("render output size exceeds " + capName);
  }
  return qipPreviewReadSlice(exportsObj.memory, outputPtr, byteLen, "output_ptr/" + capName);
}

async function qipPreviewRunStage(stage, input) {
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
    outputContentType = input.contentType;
  }
  return {
    bytes: outputBytes,
    contentType: outputContentType,
  };
}

function qipPreviewReadInputBytes(inputElement) {
  if (inputElement instanceof HTMLTextAreaElement || inputElement instanceof HTMLInputElement) {
    return qipPreviewTextEncoder.encode(inputElement.value || "");
  }
  return qipPreviewTextEncoder.encode((inputElement.textContent || "").trim());
}

class QIPPreviewElement extends HTMLElement {
  constructor() {
    super();
    this._started = false;
    this._stages = [];
    this._inputElement = null;
    this._outputElement = null;
    this._runToken = 0;
    this._boundControlListener = null;
    this._objectURL = "";
    this._imageElement = null;
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
    this._revokeObjectURL();
  }

  async _init() {
    const sourceElements = Array.from(this.querySelectorAll("source"));
    if (sourceElements.length === 0) {
      throw new Error("<qip-preview> requires at least one <source> module");
    }

    this._stages = [];
    this._moduleBytesTotal = 0;
    for (const sourceElement of sourceElements) {
      const stage = await qipPreviewLoadStage(sourceElement);
      this._stages.push(stage);
      this._moduleBytesTotal += stage.moduleBytes;
    }
    this.dataset.moduleBytesTotal = String(this._moduleBytesTotal);

    this._inputElement = this.querySelector("[name='input']");
    if (!this._inputElement) {
      throw new Error("<qip-preview> requires a child input with name=\"input\"");
    }
    this._outputElement = this.querySelector("[name='output']");
    if (!this._outputElement) {
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
    if (!this._inputElement || !this._outputElement) {
      throw new Error("qip-preview is not initialized");
    }
    const startedMS = qipPreviewNowMS();
    try {
      let current = {
        bytes: qipPreviewReadInputBytes(this._inputElement),
        contentType: "",
      };
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
        const elapsedMS = Math.max(0, Math.round(qipPreviewNowMS() - startedMS));
        this.dataset.runMs = String(elapsedMS);
      }
    }
  }

  _renderResult(result) {
    if (!this._outputElement) {
      return;
    }
    const contentType = qipPreviewGuessDisplayContentType(result.bytes, result.contentType);
    if (contentType.startsWith("image/")) {
      const blob = new Blob([result.bytes], { type: contentType });
      const nextURL = URL.createObjectURL(blob);
      const prevURL = this._objectURL;
      this._objectURL = nextURL;
      if (!this._imageElement || this._imageElement.parentElement !== this._outputElement) {
        this._imageElement = document.createElement("img");
        this._imageElement.alt = "qip-preview output";
        this._outputElement.replaceChildren(this._imageElement);
      }
      this._imageElement.src = nextURL;
      if (prevURL !== "") {
        URL.revokeObjectURL(prevURL);
      }
      return;
    }

    this._imageElement = null;
    this._revokeObjectURL();
    const pre = document.createElement("pre");
    if (contentType === "" || qipPreviewIsTextContentType(contentType)) {
      try {
        pre.textContent = qipPreviewTextDecoder.decode(result.bytes);
      } catch (_) {
        pre.textContent = qipPreviewFormatBinary(result.bytes);
      }
    } else {
      pre.textContent = qipPreviewFormatBinary(result.bytes);
    }
    this._outputElement.replaceChildren(pre);
  }

  _renderError(err) {
    if (!this._outputElement) {
      const fallback = document.createElement("pre");
      fallback.setAttribute("role", "alert");
      const message = err instanceof Error ? err.message : String(err);
      fallback.textContent = "Preview error: " + message;
      this.replaceChildren(fallback);
      return;
    }
    this._revokeObjectURL();
    this._imageElement = null;
    const pre = document.createElement("pre");
    pre.setAttribute("role", "alert");
    const message = err instanceof Error ? err.message : String(err);
    pre.textContent = "Preview error: " + message;
    this._outputElement.replaceChildren(pre);
  }

  _revokeObjectURL() {
    if (this._objectURL !== "") {
      URL.revokeObjectURL(this._objectURL);
      this._objectURL = "";
    }
  }
}

if (!customElements.get("qip-preview")) {
  customElements.define("qip-preview", QIPPreviewElement);
}
