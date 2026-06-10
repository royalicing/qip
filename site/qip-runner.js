(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
  if (typeof root === "object" && root) {
    root.QIP = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const textEncoder = new TextEncoder();
  const textDecoder = new TextDecoder("utf-8", { fatal: true });

  function toI32(value, label) {
    const n = typeof value === "bigint" ? Number(value) : value;
    if (typeof n !== "number" || !Number.isFinite(n)) {
      throw new Error(label + " returned non-finite numeric value");
    }
    return n | 0;
  }

  function normalizeMimeType(value) {
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

  function valueFromExport(exportsObj, name, required) {
    const value = exportsObj[name];
    if (typeof value === "function") {
      return toI32(value(), name);
    }
    if (value instanceof WebAssembly.Global) {
      return toI32(value.value, name);
    }
    if (typeof value === "number" || typeof value === "bigint") {
      return toI32(value, name);
    }
    if (required) {
      throw new Error("module missing export " + name);
    }
    return null;
  }

  function readSlice(memory, ptr, len, label) {
    if (!(memory instanceof WebAssembly.Memory)) {
      throw new Error("module export memory must be WebAssembly.Memory");
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
    return mem.slice(start, end);
  }

  function writeSlice(memory, ptr, bytes, label) {
    if (!(memory instanceof WebAssembly.Memory)) {
      throw new Error("module export memory must be WebAssembly.Memory");
    }
    if (ptr < 0) {
      throw new Error(label + " returned negative pointer");
    }
    const start = ptr >>> 0;
    const end = start + bytes.length;
    const mem = new Uint8Array(memory.buffer);
    if (end < start || end > mem.length) {
      throw new Error(label + " exceeds wasm memory bounds");
    }
    mem.set(bytes, start);
  }

  function readContentType(exportsObj, memory, ptrExport, sizeExport) {
    if (!(ptrExport in exportsObj) || !(sizeExport in exportsObj)) {
      return "";
    }
    const size = valueFromExport(exportsObj, sizeExport, false);
    if (size === null || size <= 0) {
      return "";
    }
    const ptr = valueFromExport(exportsObj, ptrExport, true);
    const raw = readSlice(memory, ptr, size, ptrExport + "/" + sizeExport);
    return normalizeMimeType(textDecoder.decode(raw));
  }

  function toInputBytes(input) {
    if (typeof input === "string") {
      return {
        bytes: textEncoder.encode(input),
        kind: "utf8",
      };
    }

    if (input instanceof Uint8Array) {
      return {
        bytes: new Uint8Array(input),
        kind: "bytes",
      };
    }

    if (input instanceof ArrayBuffer) {
      return {
        bytes: new Uint8Array(input),
        kind: "bytes",
      };
    }

    if (ArrayBuffer.isView(input)) {
      return {
        bytes: new Uint8Array(input.buffer, input.byteOffset, input.byteLength),
        kind: "bytes",
      };
    }

    throw new Error("input must be a string, Uint8Array, ArrayBuffer, or TypedArray");
  }

  async function instantiateWasm(wasmModule) {
    if (wasmModule instanceof WebAssembly.Instance) {
      return wasmModule;
    }

    if (wasmModule instanceof WebAssembly.Module) {
      const out = await WebAssembly.instantiate(wasmModule, {});
      return out instanceof WebAssembly.Instance ? out : out.instance;
    }

    if (typeof wasmModule === "string") {
      if (typeof fetch !== "function") {
        throw new Error("string wasmModule requires fetch support");
      }
      const response = await fetch(wasmModule);
      if (!response.ok) {
        throw new Error("failed to fetch wasm module: " + response.status + " " + response.statusText);
      }
      const bytes = await response.arrayBuffer();
      const out = await WebAssembly.instantiate(bytes, {});
      return out instanceof WebAssembly.Instance ? out : out.instance;
    }

    if (wasmModule && typeof wasmModule.arrayBuffer === "function") {
      const bytes = await wasmModule.arrayBuffer();
      const out = await WebAssembly.instantiate(bytes, {});
      return out instanceof WebAssembly.Instance ? out : out.instance;
    }

    if (wasmModule instanceof Uint8Array || wasmModule instanceof ArrayBuffer || ArrayBuffer.isView(wasmModule)) {
      const bytes = wasmModule instanceof Uint8Array
        ? wasmModule
        : wasmModule instanceof ArrayBuffer
          ? new Uint8Array(wasmModule)
          : new Uint8Array(wasmModule.buffer, wasmModule.byteOffset, wasmModule.byteLength);
      const out = await WebAssembly.instantiate(bytes, {});
      return out instanceof WebAssembly.Instance ? out : out.instance;
    }

    throw new Error("unsupported wasmModule type");
  }

  function parseInputSignature(exportsObj) {
    if (!("input_ptr" in exportsObj)) {
      throw new Error("module missing export input_ptr");
    }

    const inputPtr = valueFromExport(exportsObj, "input_ptr", true);
    const utf8Cap = valueFromExport(exportsObj, "input_utf8_cap", false);
    const bytesCap = valueFromExport(exportsObj, "input_bytes_cap", false);

    if (utf8Cap !== null) {
      return {
        ptr: inputPtr,
        cap: utf8Cap,
        kind: "utf8",
      };
    }
    if (bytesCap !== null) {
      return {
        ptr: inputPtr,
        cap: bytesCap,
        kind: "bytes",
      };
    }

    throw new Error("module must export input_utf8_cap or input_bytes_cap");
  }

  function parseOutputSignature(exportsObj) {
    const outputPtr = valueFromExport(exportsObj, "output_ptr", false);
    const utf8Cap = valueFromExport(exportsObj, "output_utf8_cap", false);
    const bytesCap = valueFromExport(exportsObj, "output_bytes_cap", false);
    const i32Cap = valueFromExport(exportsObj, "output_i32_cap", false);

    if (outputPtr === null || (utf8Cap === null && bytesCap === null && i32Cap === null)) {
      return {
        kind: "scalar",
      };
    }

    if (utf8Cap !== null) {
      return {
        kind: "utf8",
        ptr: outputPtr,
        cap: utf8Cap,
        itemSize: 1,
      };
    }

    if (bytesCap !== null) {
      return {
        kind: "bytes",
        ptr: outputPtr,
        cap: bytesCap,
        itemSize: 1,
      };
    }

    return {
      kind: "i32",
      ptr: outputPtr,
      cap: i32Cap,
      itemSize: 4,
    };
  }

  async function renderDetailed(wasmModule, input, inputContentType) {
    const instance = await instantiateWasm(wasmModule);
    const exportsObj = instance.exports;

    if (!(exportsObj.memory instanceof WebAssembly.Memory)) {
      throw new Error("module export memory must be WebAssembly.Memory");
    }

    const renderExport = exportsObj.render;
    if (typeof renderExport !== "function") {
      throw new Error("module missing export render");
    }

    const inputSignature = parseInputSignature(exportsObj);
    const outputSignature = parseOutputSignature(exportsObj);

    const declaredInputType = readContentType(
      exportsObj,
      exportsObj.memory,
      "input_content_type_ptr",
      "input_content_type_size",
    );
    const declaredOutputType = readContentType(
      exportsObj,
      exportsObj.memory,
      "output_content_type_ptr",
      "output_content_type_size",
    );

    const normalizedInputType = normalizeMimeType(inputContentType);
    if (declaredInputType !== "" && normalizedInputType !== "" && declaredInputType !== normalizedInputType) {
      throw new Error(
        "input content type mismatch: expected " + declaredInputType + ", got " + normalizedInputType,
      );
    }

    const normalized = toInputBytes(input);
    if (normalized.bytes.length > inputSignature.cap) {
      throw new Error(
        "input is too large for module: " + String(normalized.bytes.length) + " > " + String(inputSignature.cap),
      );
    }

    if (inputSignature.kind === "utf8" && normalized.kind !== "utf8") {
      textDecoder.decode(normalized.bytes);
    }

    writeSlice(exportsObj.memory, inputSignature.ptr, normalized.bytes, "input_ptr");

    const outputLen = toI32(renderExport(normalized.bytes.length), "render");
    if (outputLen < 0) {
      throw new Error("render returned negative output size");
    }

    if (outputSignature.kind === "scalar") {
      return {
        value: outputLen,
        kind: "scalar",
        outputContentType: declaredOutputType,
      };
    }

    if (outputLen > outputSignature.cap) {
      throw new Error(
        "render output exceeds module capacity: " + String(outputLen) + " > " + String(outputSignature.cap),
      );
    }

    const byteLen = outputLen * outputSignature.itemSize;
    const outputBytes = readSlice(exportsObj.memory, outputSignature.ptr, byteLen, "output_ptr");

    if (outputSignature.kind === "utf8") {
      return {
        value: textDecoder.decode(outputBytes),
        bytes: outputBytes,
        kind: "utf8",
        outputContentType: declaredOutputType,
      };
    }

    if (outputSignature.kind === "bytes") {
      return {
        value: outputBytes,
        bytes: outputBytes,
        kind: "bytes",
        outputContentType: declaredOutputType,
      };
    }

    return {
      value: new Int32Array(outputBytes.buffer, outputBytes.byteOffset, outputLen),
      bytes: outputBytes,
      kind: "i32",
      outputContentType: declaredOutputType,
    };
  }

  async function render(wasmModule, input) {
    const result = await renderDetailed(wasmModule, input, "");
    return result.value;
  }

  class Recipe {
    constructor(inputMimeType, arrayOfWasmModules) {
      if (!Array.isArray(arrayOfWasmModules) || arrayOfWasmModules.length === 0) {
        throw new Error("Recipe requires a non-empty array of QIP components");
      }
      this.inputMimeType = normalizeMimeType(inputMimeType);
      this.modules = arrayOfWasmModules.slice();
      this.lastRender = null;
    }

    async render(input) {
      let current = input;
      let currentMimeType = this.inputMimeType;

      for (let i = 0; i < this.modules.length; i += 1) {
        const isLast = i === this.modules.length - 1;
        const result = await renderDetailed(this.modules[i], current, currentMimeType);

        if (!isLast && (result.kind === "scalar" || result.kind === "i32")) {
          throw new Error(
            "module at stage " + String(i + 1) + " produced " + result.kind + " output; only utf8/bytes can be piped",
          );
        }

        current = result.value;

        if (result.outputContentType !== "") {
          currentMimeType = result.outputContentType;
        }
      }

      this.lastRender = {
        outputMimeType: currentMimeType,
        outputKind:
          typeof current === "string"
            ? "utf8"
            : current instanceof Uint8Array
              ? "bytes"
              : current instanceof Int32Array
                ? "i32"
                : "scalar",
      };

      return current;
    }
  }

  return {
    render,
    Recipe,
  };
});
