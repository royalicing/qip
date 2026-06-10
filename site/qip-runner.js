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
    throw new Error("component missing export " + name);
  }
  return null;
}

function readSlice(memory, ptr, len, label) {
  if (!(memory instanceof WebAssembly.Memory)) {
    throw new Error("component export memory must be WebAssembly.Memory");
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
    throw new Error("component export memory must be WebAssembly.Memory");
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
      encoding: "utf8",
    };
  }

  if (input instanceof Uint8Array) {
    return {
      bytes: new Uint8Array(input),
      encoding: "bytes",
    };
  }

  if (input instanceof ArrayBuffer) {
    return {
      bytes: new Uint8Array(input),
      encoding: "bytes",
    };
  }

  if (ArrayBuffer.isView(input)) {
    return {
      bytes: new Uint8Array(input.buffer, input.byteOffset, input.byteLength),
      encoding: "bytes",
    };
  }

  throw new Error("input must be a string, Uint8Array, ArrayBuffer, or TypedArray");
}

function instantiateComponent(component) {
  if (!(component instanceof WebAssembly.Module)) {
    throw new Error("component must be a WebAssembly.Module");
  }
  return new WebAssembly.Instance(component, {});
}

function parseInputSignature(exportsObj) {
  if (!("input_ptr" in exportsObj)) {
    throw new Error("component missing export input_ptr");
  }

  const inputPtr = valueFromExport(exportsObj, "input_ptr", true);
  const utf8Cap = valueFromExport(exportsObj, "input_utf8_cap", false);
  const bytesCap = valueFromExport(exportsObj, "input_bytes_cap", false);

  if (utf8Cap !== null) {
      return {
        ptr: inputPtr,
        cap: utf8Cap,
        encoding: "utf8",
      };
  }
  if (bytesCap !== null) {
      return {
        ptr: inputPtr,
        cap: bytesCap,
        encoding: "bytes",
      };
  }

  throw new Error("component must export input_utf8_cap or input_bytes_cap");
}

function parseOutputSignature(exportsObj) {
  const outputPtr = valueFromExport(exportsObj, "output_ptr", false);
  const utf8Cap = valueFromExport(exportsObj, "output_utf8_cap", false);
  const bytesCap = valueFromExport(exportsObj, "output_bytes_cap", false);
  const i32Cap = valueFromExport(exportsObj, "output_i32_cap", false);

  if (outputPtr === null || (utf8Cap === null && bytesCap === null && i32Cap === null)) {
    return {
      encoding: "scalar",
    };
  }

  if (utf8Cap !== null) {
    return {
      encoding: "utf8",
      ptr: outputPtr,
      cap: utf8Cap,
      itemSize: 1,
    };
  }

  if (bytesCap !== null) {
    return {
      encoding: "bytes",
      ptr: outputPtr,
      cap: bytesCap,
      itemSize: 1,
    };
  }

  return {
    encoding: "i32",
    ptr: outputPtr,
    cap: i32Cap,
    itemSize: 4,
  };
}

function renderComponent(component, input, inputContentType = "", options = {}) {
  const instance = instantiateComponent(component);
  const exportsObj = instance.exports;

  if (!(exportsObj.memory instanceof WebAssembly.Memory)) {
    throw new Error("component export memory must be WebAssembly.Memory");
  }

  const renderExport = exportsObj.render;
  if (typeof renderExport !== "function") {
    throw new Error("component missing export render");
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
  if (declaredInputType !== "" && normalizedInputType === "" && options.strictInputContentType === true) {
    throw new Error("input content type mismatch: expected " + declaredInputType + ", got unknown");
  }
  if (declaredInputType !== "" && normalizedInputType !== "" && declaredInputType !== normalizedInputType) {
    throw new Error(
      "input content type mismatch: expected " + declaredInputType + ", got " + normalizedInputType,
    );
  }

  const normalized = toInputBytes(input);
  if (normalized.bytes.length > inputSignature.cap) {
    throw new Error(
      "input is too large for component: " + String(normalized.bytes.length) + " > " + String(inputSignature.cap),
    );
  }

  if (inputSignature.encoding === "utf8" && normalized.encoding !== "utf8") {
    textDecoder.decode(normalized.bytes);
  }

  writeSlice(exportsObj.memory, inputSignature.ptr, normalized.bytes, "input_ptr");

  const outputLen = toI32(renderExport(normalized.bytes.length), "render");
  if (outputLen < 0) {
    throw new Error("render returned negative output size");
  }

  if (outputSignature.encoding === "scalar") {
    return {
      value: outputLen,
      encoding: "scalar",
      contentType: declaredOutputType,
    };
  }

  if (outputLen > outputSignature.cap) {
    throw new Error(
      "render output exceeds component capacity: " + String(outputLen) + " > " + String(outputSignature.cap),
    );
  }

  const byteLen = outputLen * outputSignature.itemSize;
  const outputBytes = readSlice(exportsObj.memory, outputSignature.ptr, byteLen, "output_ptr");

  if (outputSignature.encoding === "utf8") {
    return {
      value: textDecoder.decode(outputBytes),
      bytes: outputBytes,
      encoding: "utf8",
      contentType: declaredOutputType,
    };
  }

  if (outputSignature.encoding === "bytes") {
    return {
      value: outputBytes,
      bytes: outputBytes,
      encoding: "bytes",
      contentType: declaredOutputType,
    };
  }

  return {
    value: new Int32Array(outputBytes.buffer, outputBytes.byteOffset, outputLen),
    bytes: outputBytes,
    encoding: "i32",
    contentType: declaredOutputType,
  };
}

export function render(component, input) {
  return renderComponent(component, input, "");
}

export function createRecipe(inputMimeType, components) {
  if (!Array.isArray(components) || components.length === 0) {
    throw new Error("createRecipe requires a non-empty array of QIP components");
  }
  for (let i = 0; i < components.length; i += 1) {
    if (!(components[i] instanceof WebAssembly.Module)) {
      throw new Error("recipe component at stage " + String(i + 1) + " must be a WebAssembly.Module");
    }
  }

  const recipeInputMimeType = normalizeMimeType(inputMimeType);
  const recipeComponents = components.slice();

  return {
    render(input) {
      let current = input;
      let currentMimeType = recipeInputMimeType;
      let finalResult = null;

      for (let i = 0; i < recipeComponents.length; i += 1) {
        const isLast = i === recipeComponents.length - 1;
        const result = renderComponent(recipeComponents[i], current, currentMimeType, {
          strictInputContentType: true,
        });

        if (!isLast && (result.encoding === "scalar" || result.encoding === "i32")) {
          throw new Error(
            "component at stage " + String(i + 1) + " produced " + result.encoding + " output; only utf8/bytes can be piped",
          );
        }

        current = result.value;

        if (result.contentType !== "") {
          currentMimeType = result.contentType;
        }
        finalResult = result;
      }

      return resultWithContentType(finalResult, currentMimeType);
    },
  };
}

function resultWithContentType(result, contentType) {
  return {
    ...result,
    contentType,
  };
}
