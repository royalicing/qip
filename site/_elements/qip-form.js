const qipFormTextEncoder = new TextEncoder();
const qipFormTextDecoder = new TextDecoder("utf-8", { fatal: true });
const qipFormRequiredExports = [
  "memory",
  "input_ptr",
  "input_utf8_cap",
  "render",
  "output_ptr",
  "output_utf8_cap",
  "input_key_ptr",
  "input_key_size",
  "input_label_ptr",
  "input_label_size",
  "error_message_ptr",
  "error_message_size",
];

function qipFormCallI32(exportsObj, fnName, args) {
  const fn = exportsObj[fnName];
  if (typeof fn !== "function") {
    throw new Error("form module missing export " + fnName);
  }
  const result = fn(...(args || []));
  return result | 0;
}

function qipFormReadSlice(exportsObj, ptr, len, label) {
  if (ptr < 0 || len < 0) {
    throw new Error(label + " returned negative pointer/size");
  }
  const mem = new Uint8Array(exportsObj.memory.buffer);
  const start = ptr >>> 0;
  const size = len >>> 0;
  const end = start + size;
  if (end < start || end > mem.length) {
    throw new Error(label + " exceeds wasm memory bounds");
  }
  return mem.slice(start, end);
}

function qipFormReadExportedString(exportsObj, ptrExport, lenExport) {
  const ptr = qipFormCallI32(exportsObj, ptrExport);
  const len = qipFormCallI32(exportsObj, lenExport);
  if (len === 0) {
    return "";
  }
  const bytes = qipFormReadSlice(exportsObj, ptr, len, ptrExport + "/" + lenExport);
  return qipFormTextDecoder.decode(bytes);
}

function qipFormReadOutput(exportsObj, outLen) {
  if (outLen < 0) {
    throw new Error("render returned negative output size: " + String(outLen));
  }
  if (outLen === 0) {
    return "";
  }
  const outPtr = qipFormCallI32(exportsObj, "output_ptr");
  const outCap = qipFormCallI32(exportsObj, "output_utf8_cap");
  if (outPtr < 0 || outCap < 0) {
    throw new Error("module returned invalid output pointer/capacity");
  }
  if (outLen > outCap) {
    throw new Error("render output size exceeds output_utf8_cap");
  }
  const bytes = qipFormReadSlice(exportsObj, outPtr, outLen, "output_ptr/output_utf8_cap");
  return qipFormTextDecoder.decode(bytes);
}

function qipFormWriteInput(exportsObj, value) {
  const inputPtr = qipFormCallI32(exportsObj, "input_ptr");
  const inputCap = qipFormCallI32(exportsObj, "input_utf8_cap");
  if (inputPtr < 0 || inputCap < 0) {
    throw new Error("module returned invalid input pointer/capacity");
  }
  const bytes = qipFormTextEncoder.encode(value);
  if (bytes.length > inputCap) {
    throw new Error("input value exceeds module input_utf8_cap");
  }

  const mem = new Uint8Array(exportsObj.memory.buffer);
  const start = inputPtr >>> 0;
  const end = start + bytes.length;
  if (end < start || end > mem.length) {
    throw new Error("input write exceeds wasm memory bounds");
  }
  mem.set(bytes, start);
  return bytes.length;
}

class QIPFormElement extends HTMLElement {
  constructor() {
    super();
    this._started = false;
    this._exports = null;
    this._hasRun = false;
    this._lastOutputLen = 0;
  }

  async connectedCallback() {
    if (this._started) {
      return;
    }
    this._started = true;
    try {
      await this._init();
      this._render();
    } catch (err) {
      this._renderFatal(err);
    }
  }

  async _init() {
    const sources = Array.from(this.querySelectorAll(":scope > source"));
    if (sources.length !== 1) {
      throw new Error("qip-form requires exactly one direct source element");
    }
    const source = sources[0];
    const sourceURL = (source.getAttribute("src") || "").trim();
    if (sourceURL === "") {
      throw new Error("qip-form source requires a non-empty src attribute");
    }
    const sourceType = (source.getAttribute("type") || "").trim().toLowerCase();
    if (sourceType !== "application/wasm") {
      throw new Error("qip-form source type must be application/wasm");
    }
    const response = await fetch(sourceURL);
    if (!response.ok) {
      throw new Error("failed to fetch form module: HTTP " + String(response.status));
    }
    const moduleBytes = await response.arrayBuffer();
    const instantiated = await WebAssembly.instantiate(moduleBytes, {});
    const exportsObj = instantiated.instance.exports;
    for (const exportName of qipFormRequiredExports) {
      if (!(exportName in exportsObj)) {
        throw new Error("form module missing export " + exportName);
      }
    }
    if (!(exportsObj.memory instanceof WebAssembly.Memory)) {
      throw new Error("form module export memory must be WebAssembly.Memory");
    }
    this._exports = exportsObj;
  }

  _render() {
    const exportsObj = this._exports;
    if (!exportsObj) {
      throw new Error("form module is not initialized");
    }

    const inputKey = qipFormReadExportedString(exportsObj, "input_key_ptr", "input_key_size").trim();
    if (inputKey === "") {
      if (!this._hasRun) {
        this._lastOutputLen = qipFormCallI32(exportsObj, "render", [0]);
        this._hasRun = true;
      }
      const outputText = qipFormReadOutput(exportsObj, this._lastOutputLen);
      const pre = document.createElement("pre");
      pre.textContent = outputText;
      this.replaceChildren(pre);
      return;
    }

    const errorMessage = qipFormReadExportedString(exportsObj, "error_message_ptr", "error_message_size");
    const inputLabel = qipFormReadExportedString(exportsObj, "input_label_ptr", "input_label_size");
    const prompt = inputLabel.trim() || inputKey;

    const container = document.createElement("form");
    container.noValidate = true;

    if (errorMessage !== "") {
      const errorNode = document.createElement("p");
      errorNode.setAttribute("role", "alert");
      errorNode.textContent = errorMessage;
      container.appendChild(errorNode);
    }

    const labelNode = document.createElement("label");
    labelNode.textContent = prompt;
    container.appendChild(labelNode);

    const inputNode = document.createElement("input");
    inputNode.type = "text";
    inputNode.required = true;
    inputNode.name = inputKey;
    inputNode.autocomplete = "off";
    container.appendChild(inputNode);

    const submitNode = document.createElement("button");
    submitNode.type = "submit";
    submitNode.textContent = "Continue";
    container.appendChild(submitNode);

    container.addEventListener("submit", (event) => {
      event.preventDefault();
      try {
        const inputLen = qipFormWriteInput(exportsObj, inputNode.value);
        this._lastOutputLen = qipFormCallI32(exportsObj, "render", [inputLen]);
        this._hasRun = true;
        this._render();
      } catch (err) {
        this._renderFatal(err);
      }
    });

    this.replaceChildren(container);
    inputNode.focus();
  }

  _renderFatal(err) {
    const message = err instanceof Error ? err.message : String(err);
    const pre = document.createElement("pre");
    pre.textContent = "Form error: " + message;
    this.replaceChildren(pre);
  }
}

if (!customElements.get("qip-form")) {
  customElements.define("qip-form", QIPFormElement);
}
