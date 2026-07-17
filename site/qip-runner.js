const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder("utf-8", { fatal: true });
const mimeTypePattern =
  /^[a-z0-9][a-z0-9!#$&^_.+-]*\/[a-z0-9][a-z0-9!#$&^_.+-]*$/;

function toI32(value, label) {
  const n = typeof value === "bigint" ? Number(value) : value;
  if (typeof n !== "number" || !Number.isFinite(n)) {
    throw Error(label + " returned non-finite numeric value");
  }
  return n | 0;
}

function optionalContractContentType(value) {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "string") {
    throw Error("contentType must be a string");
  }
  if (!mimeTypePattern.test(value)) {
    throw Error(
      "contentType must be a lowercase MIME type without parameters e.g. 'text/html'",
    );
  }
  return value;
}

class ContentTypeUTF8 {
  constructor(optionalMIMEType) {
    this.contentType = optionalContractContentType(optionalMIMEType);
    Object.freeze(this);
  }
}

class ContentTypeBytes {
  constructor(optionalMIMEType) {
    this.contentType = optionalContractContentType(optionalMIMEType);
    Object.freeze(this);
  }
}

function sameContract(left, right) {
  return (
    left.constructor === right.constructor &&
    (left.contentType === undefined ||
      right.contentType === undefined ||
      left.contentType === right.contentType)
  );
}

function describeContract(contract) {
  return (
    (contract instanceof ContentTypeUTF8 ? "utf-8" : "bytes") +
    (contract.contentType ? " " + contract.contentType : "")
  );
}

function isContentContract(value) {
  return value instanceof ContentTypeUTF8 || value instanceof ContentTypeBytes;
}

function assertContractsMatch(actual, expected, label) {
  if (!sameContract(actual, expected)) {
    throw Error(
      label +
        " contract mismatch: expected " +
        describeContract(expected) +
        ", got " +
        describeContract(actual),
    );
  }
}

function readI32Export(exportsObj, name) {
  return toI32(exportsObj[name](), name);
}

function readSlice(memory, ptr, len, label) {
  if (ptr < 0 || len < 0) {
    throw Error(label + " returned negative pointer/size");
  }
  const start = ptr >>> 0;
  const end = start + (len >>> 0);
  const mem = new Uint8Array(memory.buffer);
  if (end > mem.length) {
    throw Error(label + " exceeds wasm memory bounds");
  }
  return mem.slice(start, end);
}

function writeSlice(memory, ptr, bytes, label) {
  if (ptr < 0) {
    throw Error(label + " returned negative pointer");
  }
  const start = ptr >>> 0;
  const end = start + bytes.length;
  const mem = new Uint8Array(memory.buffer);
  if (end > mem.length) {
    throw Error(label + " exceeds wasm memory bounds");
  }
  mem.set(bytes, start);
}

function optionalContentType(exportsObj, memory, ptrName, sizeName) {
  if (exportsObj[ptrName] === undefined && exportsObj[sizeName] === undefined) {
    return undefined;
  }
  if (
    typeof exportsObj[ptrName] !== "function" ||
    typeof exportsObj[sizeName] !== "function"
  ) {
    throw Error(
      "content type exports " + ptrName + "/" + sizeName + " must be functions",
    );
  }
  const size = readI32Export(exportsObj, sizeName);
  if (size <= 0) {
    return undefined;
  }
  const ptr = readI32Export(exportsObj, ptrName);
  return optionalContractContentType(
    textDecoder.decode(readSlice(memory, ptr, size, ptrName + "/" + sizeName)),
  );
}

function requireExportedFunction(moduleExports, name) {
  if (
    !moduleExports.find((exp) => exp.name === name && exp.kind === "function")
  ) {
    throw Error("component must export " + name + " as function");
  }
}

function capName(contract, direction) {
  return (
    direction +
    (contract instanceof ContentTypeUTF8 ? "_utf8_cap" : "_bytes_cap")
  );
}

function bytesForInput(input, contract) {
  if (contract instanceof ContentTypeUTF8) {
    if (typeof input !== "string") {
      throw Error(
        "component input must be a string for " + describeContract(contract),
      );
    }
    return textEncoder.encode(input);
  }
  if (!(input instanceof Uint8Array)) {
    throw Error(
      "component input must be Uint8Array for " + describeContract(contract),
    );
  }
  return input;
}

function outputForBytes(bytes, contract) {
  return contract instanceof ContentTypeUTF8 ? textDecoder.decode(bytes) : bytes;
}

function assertJsOutput(value, contract) {
  if (contract instanceof ContentTypeUTF8) {
    if (typeof value !== "string") {
      throw Error(
        "JavaScript component returned non-string output for " +
          describeContract(contract),
      );
    }
  } else if (!(value instanceof Uint8Array)) {
    throw Error(
      "JavaScript component returned non-Uint8Array output for " +
        describeContract(contract),
    );
  }
}

function freezeComponent(fn, input, output) {
  Object.defineProperties(fn, {
    input: { value: input },
    output: { value: output },
  });
  return Object.freeze(fn);
}

function validateWasmComponent(input, module, output) {
  const moduleExports = WebAssembly.Module.exports(module);

  if (!moduleExports.find((exp) => exp.name === "memory" && exp.kind === "memory")) {
    throw Error("component must export memory");
  }
  requireExportedFunction(moduleExports, "render");
  requireExportedFunction(moduleExports, "input_ptr");
  requireExportedFunction(moduleExports, capName(input, "input"));
  requireExportedFunction(moduleExports, "output_ptr");
  requireExportedFunction(moduleExports, capName(output, "output"));

  const exportsObj = new WebAssembly.Instance(module, {}).exports;
  const declaredInput = optionalContentType(
    exportsObj,
    exportsObj.memory,
    "input_content_type_ptr",
    "input_content_type_size",
  );
  const declaredOutput = optionalContentType(
    exportsObj,
    exportsObj.memory,
    "output_content_type_ptr",
    "output_content_type_size",
  );

  if (
    declaredInput !== undefined &&
    input.contentType !== undefined &&
    declaredInput !== input.contentType
  ) {
    throw Error(
      "component input content type mismatch: expected " +
        input.contentType +
        ", module declares " +
        declaredInput,
    );
  }
  if (
    declaredOutput !== undefined &&
    output.contentType !== undefined &&
    declaredOutput !== output.contentType
  ) {
    throw Error(
      "component output content type mismatch: expected " +
        output.contentType +
        ", module declares " +
        declaredOutput,
    );
  }
}

function wasmComponent(input, module, output) {
  validateWasmComponent(input, module, output);

  return freezeComponent(
    (value) => {
      const exportsObj = new WebAssembly.Instance(module, {}).exports;
      const render = exportsObj.render;

      const inputBytes = bytesForInput(value, input);
      const inputPtr = readI32Export(exportsObj, "input_ptr");
      const inputCap = readI32Export(exportsObj, capName(input, "input"));
      if (inputBytes.length > inputCap) {
        throw Error(
          "input exceeds component capacity: " +
            inputBytes.length +
            " > " +
            inputCap,
        );
      }

      writeSlice(exportsObj.memory, inputPtr, inputBytes, "input_ptr");

      const outputLen = toI32(render(inputBytes.length), "render");
      if (outputLen < 0) {
        throw Error("render returned negative output size");
      }

      const outputCap = readI32Export(exportsObj, capName(output, "output"));
      if (outputLen > outputCap) {
        throw Error(
          "render output exceeds component capacity: " +
            outputLen +
            " > " +
            outputCap,
        );
      }

      const outputPtr = readI32Export(exportsObj, "output_ptr");
      return outputForBytes(
        readSlice(exportsObj.memory, outputPtr, outputLen, "output_ptr"),
        output,
      );
    },
    input,
    output,
  );
}

function jsComponent(input, fn, output) {
  return freezeComponent(
    (value) => {
      bytesForInput(value, input);
      const result = fn(value);
      assertJsOutput(result, output);
      return result;
    },
    input,
    output,
  );
}

function isContentComponent(value) {
  return (
    typeof value === "function" &&
    isContentContract(value.input) &&
    isContentContract(value.output)
  );
}

export function contentTypeUTF8(optionalMIMEType) {
  return new ContentTypeUTF8(optionalMIMEType);
}

export function contentTypeBytes(optionalMIMEType) {
  return new ContentTypeBytes(optionalMIMEType);
}

export function contentComponent(input, implementation, output) {
  if (!isContentContract(input)) {
    throw Error("contentComponent input must be a content contract");
  }
  if (!isContentContract(output)) {
    throw Error("contentComponent output must be a content contract");
  }
  if (implementation instanceof WebAssembly.Module) {
    return wasmComponent(input, implementation, output);
  }
  if (typeof implementation === "function") {
    return jsComponent(input, implementation, output);
  }
  throw Error(
    "content component implementation must be a WebAssembly.Module or function",
  );
}

export function contentRecipe(input, components, output) {
  if (!isContentContract(input)) {
    throw Error("contentRecipe input must be a content contract");
  }
  if (!isContentContract(output)) {
    throw Error("contentRecipe output must be a content contract");
  }
  if (!Array.isArray(components)) {
    throw Error("contentRecipe components must be an array");
  }

  const steps = components.slice();
  for (let i = 0; i < steps.length; i += 1) {
    if (!isContentComponent(steps[i])) {
      throw Error(
        "contentRecipe step " + String(i + 1) + " must be a content component",
      );
    }
  }

  if (steps.length === 0) {
    assertContractsMatch(input, output, "empty recipe");
  } else {
    assertContractsMatch(input, steps[0].input, "recipe input");
    for (let i = 0; i < steps.length - 1; i += 1) {
      assertContractsMatch(
        steps[i].output,
        steps[i + 1].input,
        "recipe step " + String(i + 1),
      );
    }
    assertContractsMatch(
      steps[steps.length - 1].output,
      output,
      "recipe output",
    );
  }

  return freezeComponent(
    (value) => {
      bytesForInput(value, input);
      let current = value;
      for (const step of steps) {
        current = step(current);
      }
      assertJsOutput(current, output);
      return current;
    },
    input,
    output,
  );
}
