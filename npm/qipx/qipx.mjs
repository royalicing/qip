#!/usr/bin/env node

import { realpathSync } from "node:fs";
import { readdir, readFile, stat, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const decoder = new TextDecoder("utf-8", { fatal: true });
const encoder = new TextEncoder();

function usage() {
  return `Usage: qipx run [options] <component.wasm> [component2.wasm ...]\n` +
    `       qipx dry run [options] <component.wasm> [component2.wasm ...]\n` +
    `       qipx comply [options] <file-or-dir> [...]\n` +
    `       qipx bench [options] <component.wasm> [...]  (coming soon)\n\n` +
    `Options:\n` +
    `  -i, --input <path>              Read input from a file instead of stdin\n` +
    `  -o, --output <path>             Write output to a file instead of stdout\n` +
    `  --max-memory <bytes>            Reject modules whose declared memory exceeds bytes\n` +
    `  --capacities-must-fit           Reject stages whose max output cannot fit next input\n` +
    `  dry run                         Validate the pipeline without reading input or rendering\n` +
    `  -h, --help                      Show this help\n\n` +
    `Uniforms:\n` +
    `  Place a query string after a component path, for example:\n` +
    `  qipx run component.wasm '?width=640&height=480'\n` +
    `  i32 uniforms are treated as unsigned values; use i64 for signed integers.\n\n` +
    `Documentation: https://qip.dev/docs/content-component\n`;
}

function complyUsage() {
  return `Usage: qipx comply [options] <file-or-dir> [...]\n\n` +
    `Options:\n` +
    `  --with <compliance.wasm>        Run a Compliance oracle (repeatable)\n` +
    `  --seed <n>                      Call uniform_set_seed(u32) on each oracle\n` +
    `  --max-memory <bytes>            Reject implementation memory above bytes\n` +
    `  -h, --help                      Show this help\n\n` +
    `Checks QIP Content ABI compliance and the Strict Wasm Profile subset.\n` +
    `Documentation: https://qip.dev/docs/comply\n`;
}

function bytes(value) {
  if (value instanceof Uint8Array) return value;
  if (typeof value === "string") return encoder.encode(value);
  return new Uint8Array(value);
}

function exportedValue(exports, name, label) {
  const item = exports[name];
  if (typeof item !== "function") throw new Error(`${label} must export ${name}() -> i32`);
  return Number(item()) >>> 0;
}

function requireFunction(exports, name, label) {
  const item = exports[name];
  if (typeof item !== "function") throw new Error(`${label} must export ${name}`);
  return item;
}

function declaredType(exports, prefix, label) {
  const pointer = exports[`${prefix}_content_type_ptr`];
  const size = exports[`${prefix}_content_type_size`];
  if (pointer === undefined && size === undefined) return "";
  if (pointer === undefined || size === undefined) throw new Error(`${label} has incomplete ${prefix} content-type exports`);
  const start = exportedValue(exports, `${prefix}_content_type_ptr`, label);
  const length = exportedValue(exports, `${prefix}_content_type_size`, label);
  const type = decoder.decode(new Uint8Array(exports.memory.buffer, start, length));
  validateContentType(type, `${label} ${prefix} content type`);
  return type;
}

function validateContentType(type, label = "content type") {
  if (/^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/.test(type)) return;
  if (type === "multipart/form-data;boundary=uuid-00000000-0000-0000-0000-000000000000") return;
  throw new Error(`invalid ${label}: ${type}`);
}

function optionalContentType(type, label = "contentType") {
  if (type === undefined) return undefined;
  validateContentType(type, label);
  return type;
}

class ContentContract {
  constructor(encoding, optionalMIMEType) {
    this.encoding = encoding;
    this.contentType = optionalContentType(optionalMIMEType);
    Object.freeze(this);
  }
}

export function contentTypeUTF8(optionalMIMEType) {
  return new ContentContract("utf8", optionalMIMEType);
}

export function contentTypeBytes(optionalMIMEType) {
  return new ContentContract("bytes", optionalMIMEType);
}

const contentComponentContractBrand = Symbol("qipx.contentComponentContract");

class ContentComponentContractSpec {
  constructor(options = {}) {
    this[contentComponentContractBrand] = true;
    this.label = options.label;
    this.maxMemory = options.maxMemory === undefined ? undefined : parseMaxMemory(options.maxMemory);
    this.input = options.input;
    this.output = options.output;
    if (this.input !== undefined && !isContentContract(this.input)) throw new Error("input must be contentTypeUTF8(...) or contentTypeBytes(...)");
    if (this.output !== undefined && !isContentContract(this.output)) throw new Error("output must be contentTypeUTF8(...) or contentTypeBytes(...)");
    Object.freeze(this);
  }
}

export function newContentComponentContract(options = {}) {
  return new ContentComponentContractSpec(options);
}

function componentContractOptions(options = {}) {
  return options?.[contentComponentContractBrand] ? options : options;
}

function isContentContract(value) {
  return value instanceof ContentContract;
}

function describeContentContract(contract) {
  return `${contract.encoding}${contract.contentType ? ` ${contract.contentType}` : ""}`;
}

function assertComponentContract(component, field, expected) {
  if (expected === undefined) return;
  if (!isContentContract(expected)) throw new Error(`${field} must be contentTypeUTF8(...) or contentTypeBytes(...)`);
  const actual = component[field];
  if (actual.encoding !== expected.encoding || (expected.contentType !== undefined && actual.contentType !== expected.contentType)) {
    throw new Error(`${component.label} ${field} contract mismatch: expected ${describeContentContract(expected)}, got ${describeContentContract(actual)}`);
  }
}

function validUniformKey(key) {
  return key.length >= 1 && key.length <= 63 && /^[a-z][a-z0-9_]*$/.test(key) && !key.endsWith("_") && !key.includes("__");
}

function parseUniformValue(value) {
  const trimmed = String(value).trim();
  if (/^[-+]?0x[0-9a-f]+$/i.test(trimmed)) return Number.parseInt(trimmed, 16);
  if (/^[-+]?\d+$/.test(trimmed)) return Number.parseInt(trimmed, 10);
  if (/^[-+]?(?:\d+\.\d*|\d*\.\d+|\d+)(?:e[-+]?\d+)?$/i.test(trimmed)) return Number(trimmed);
  throw new Error(`uniform value ${JSON.stringify(value)} is not a number`);
}

function validateUniforms(stage) {
  for (const [key, rawValue] of stage.uniforms ?? []) {
    if (!validUniformKey(key)) throw new Error(`${stage.label} has invalid uniform key ${key}`);
    parseUniformValue(rawValue);
    const setterName = `uniform_set_${key}`;
    const setter = stage.component.exports[setterName];
    if (typeof setter !== "function") throw new Error(`${stage.label} does not export ${setterName}`);
  }
}

function applyUniforms(stage) {
  validateUniforms(stage);
  for (const [key, rawValue] of stage.uniforms ?? []) {
    stage.component.exports[`uniform_set_${key}`](parseUniformValue(rawValue));
  }
}

function readULEB(bytes, offset) {
  let result = 0n;
  let shift = 0n;
  for (let index = offset; index < bytes.length; index += 1) {
    const byte = bytes[index];
    result |= BigInt(byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) return { value: result, offset: index + 1 };
    shift += 7n;
    if (shift > 63n) throw new Error("invalid Wasm LEB128 integer");
  }
  throw new Error("truncated Wasm LEB128 integer");
}

function readName(bytes, offset) {
  const length = readULEB(bytes, offset);
  const start = length.offset;
  const end = start + Number(length.value);
  if (end > bytes.length) throw new Error("truncated Wasm name");
  return { value: decoder.decode(bytes.subarray(start, end)), offset: end };
}

function readSLEB(bytes, offset) {
  let result = 0n;
  let shift = 0n;
  let byte = 0;
  let cursor = offset;
  for (; cursor < bytes.length; cursor += 1) {
    byte = bytes[cursor];
    result |= BigInt(byte & 0x7f) << shift;
    shift += 7n;
    if ((byte & 0x80) === 0) break;
    if (shift > 63n) throw new Error("invalid Wasm signed LEB128 integer");
  }
  if (cursor >= bytes.length) throw new Error("truncated Wasm signed LEB128 integer");
  if (shift < 64n && (byte & 0x40) !== 0) result |= -1n << shift;
  return { value: result, offset: cursor + 1 };
}

function validateMemoryPolicy(wasm, label, policy = {}) {
  if (wasm.length < 8 || wasm[0] !== 0x00 || wasm[1] !== 0x61 || wasm[2] !== 0x73 || wasm[3] !== 0x6d) {
    throw new Error(`${label} is not a WebAssembly binary module`);
  }
  const maxMemory = policy.maxMemory;
  let offset = 8;
  let memoryCount = 0;
  while (offset < wasm.length) {
    const sectionID = wasm[offset++];
    const size = readULEB(wasm, offset);
    offset = size.offset;
    const sectionEnd = offset + Number(size.value);
    if (sectionEnd > wasm.length) throw new Error(`${label} has a truncated Wasm section`);
    if (sectionID === 2) {
      let cursor = offset;
      const count = readULEB(wasm, cursor);
      cursor = count.offset;
      for (let index = 0n; index < count.value; index += 1n) {
        cursor = readName(wasm, cursor).offset;
        cursor = readName(wasm, cursor).offset;
        const kind = wasm[cursor++];
        if (kind === 0x00) cursor = readULEB(wasm, cursor).offset;
        else if (kind === 0x01) {
          cursor += 1;
          const limits = readLimits(wasm, cursor, label);
          cursor = limits.offset;
        } else if (kind === 0x02) {
          const limits = readLimits(wasm, cursor, label);
          cursor = limits.offset;
          memoryCount += 1;
          validateMemoryLimits(limits, label, maxMemory);
        } else if (kind === 0x03) {
          cursor += 2;
        } else {
          throw new Error(`${label} has an unknown import kind`);
        }
      }
    } else if (sectionID === 5) {
      let cursor = offset;
      const count = readULEB(wasm, cursor);
      cursor = count.offset;
      for (let index = 0n; index < count.value; index += 1n) {
        const limits = readLimits(wasm, cursor, label);
        cursor = limits.offset;
        memoryCount += 1;
        validateMemoryLimits(limits, label, maxMemory);
      }
    }
    offset = sectionEnd;
  }
  if (memoryCount !== 1) throw new Error(`${label} must declare exactly one memory`);
}

function readLimits(bytes, offset, label) {
  const flags = bytes[offset++];
  if (flags === undefined) throw new Error(`${label} has truncated limits`);
  const minimum = readULEB(bytes, offset);
  offset = minimum.offset;
  let maximum = null;
  if ((flags & 0x01) !== 0) {
    const max = readULEB(bytes, offset);
    maximum = max.value;
    offset = max.offset;
  }
  return { flags, minimum: minimum.value, maximum, offset };
}

function validateMemoryLimits(limits, label, maxMemory) {
  if ((limits.flags & 0x02) !== 0) throw new Error(`${label} declares shared memory, which is outside the Strict Wasm Profile`);
  if (limits.maximum === null) throw new Error(`${label} declares memory without a maximum, which is outside the Strict Wasm Profile`);
  if (maxMemory === undefined || maxMemory === null) return;
  const pageSize = 65536n;
  const cap = BigInt(maxMemory);
  const minBytes = limits.minimum * pageSize;
  if (minBytes > cap) throw new Error(`${label} declares minimum memory ${minBytes} bytes, exceeding --max-memory ${cap}`);
  const maxBytes = limits.maximum * pageSize;
  if (maxBytes > cap) throw new Error(`${label} declares maximum memory ${maxBytes} bytes, exceeding --max-memory ${cap}`);
}

function readBlockType(wasm, offset) {
  const byte = wasm[offset];
  if (byte === undefined) throw new Error("truncated Wasm block type");
  if (byte === 0x40 || byte === 0x6f || byte === 0x70 || byte === 0x7b || byte === 0x7c || byte === 0x7d || byte === 0x7e || byte === 0x7f) {
    return offset + 1;
  }
  return readSLEB(wasm, offset).offset;
}

function skipVector(wasm, offset) {
  const count = readULEB(wasm, offset);
  let cursor = count.offset;
  for (let index = 0n; index < count.value; index += 1n) cursor = readULEB(wasm, cursor).offset;
  return cursor;
}

function skipMemarg(wasm, offset) {
  return readULEB(wasm, readULEB(wasm, offset).offset).offset;
}

function skipSIMDInstruction(wasm, offset, label) {
  const sub = readULEB(wasm, offset);
  const code = Number(sub.value);
  const cursor = sub.offset;
  if ((code >= 0 && code <= 11) || (code >= 92 && code <= 93)) return skipMemarg(wasm, cursor);
  if (code === 12 || code === 13) return cursor + 16;
  if (code >= 21 && code <= 34) return cursor + 1;
  if (code >= 84 && code <= 91) return skipMemarg(wasm, cursor) + 1;
  if (code >= 0 && code <= 255) return cursor;
  throw new Error(`${label} uses unsupported SIMD opcode 0x${code.toString(16)}`);
}

function skipStrictInstruction(wasm, offset, calls, label) {
  const opcode = wasm[offset++];
  if (opcode === undefined) throw new Error(`${label} has a truncated instruction`);
  switch (opcode) {
    case 0x02:
    case 0x03:
    case 0x04:
      return readBlockType(wasm, offset);
    case 0x0c:
    case 0x0d:
    case 0xd2:
      return readULEB(wasm, offset).offset;
    case 0x0e:
      return readULEB(wasm, skipVector(wasm, offset)).offset;
    case 0x10: {
      const target = readULEB(wasm, offset);
      calls.push(Number(target.value));
      return target.offset;
    }
    case 0x11:
    case 0x13:
      return readULEB(wasm, readULEB(wasm, offset).offset).offset;
    case 0x20:
    case 0x21:
    case 0x22:
    case 0x23:
    case 0x24:
    case 0x25:
    case 0x26:
    case 0xd0:
      return readULEB(wasm, offset).offset;
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
      return skipMemarg(wasm, offset);
    case 0x3f:
      return readULEB(wasm, offset).offset;
    case 0x40:
      throw new Error(`${label} uses memory.grow, which is outside the Strict Wasm Profile`);
    case 0x41:
    case 0x42:
      return readSLEB(wasm, offset).offset;
    case 0x43:
      return offset + 4;
    case 0x44:
      return offset + 8;
    case 0xfc: {
      const sub = readULEB(wasm, offset);
      if (sub.value === 8n || sub.value === 10n) return readULEB(wasm, readULEB(wasm, sub.offset).offset).offset;
      if (sub.value === 9n || sub.value === 11n || (sub.value >= 12n && sub.value <= 17n)) return readULEB(wasm, sub.offset).offset;
      return sub.offset;
    }
    case 0xfd:
      return skipSIMDInstruction(wasm, offset, label);
    case 0xfe:
      throw new Error(`${label} uses atomic instructions, which are outside the Strict Wasm Profile`);
    default:
      if (opcode >= 0x00 && opcode <= 0x1b) return offset;
      if (opcode === 0x1c) {
        const count = readULEB(wasm, offset);
        return Number(count.value) + count.offset;
      }
      if (opcode >= 0x45 && opcode <= 0xbf) return offset;
      if (opcode >= 0xc0 && opcode <= 0xc4) return offset;
      throw new Error(`${label} uses unsupported Wasm opcode 0x${opcode.toString(16)} at byte offset ${offset - 1}`);
  }
}

const staticExportNames = [
  "input_ptr",
  "input_utf8_cap",
  "input_bytes_cap",
  "output_ptr",
  "output_utf8_cap",
  "output_bytes_cap",
  "input_content_type_ptr",
  "input_content_type_size",
  "output_content_type_ptr",
  "output_content_type_size",
];

function validateStrictInstructions(wasm, label) {
  let offset = 8;
  let functionCount = 0;
  let callGraph = [];
  while (offset < wasm.length) {
    const sectionID = wasm[offset++];
    const size = readULEB(wasm, offset);
    offset = size.offset;
    const sectionEnd = offset + Number(size.value);
    if (sectionID === 2) {
      const count = readULEB(wasm, offset);
      if (count.value !== 0n) throw new Error(`${label} imports host functions or state, which is outside the Strict Wasm Profile`);
    } else if (sectionID === 3) {
      const count = readULEB(wasm, offset);
      functionCount = Number(count.value);
      callGraph = Array.from({ length: functionCount }, () => []);
    } else if (sectionID === 8) {
      throw new Error(`${label} declares a start function, which is outside the Strict Wasm Profile`);
    } else if (sectionID === 10) {
      let cursor = offset;
      const count = readULEB(wasm, cursor);
      cursor = count.offset;
      if (Number(count.value) !== functionCount) throw new Error(`${label} code/function section count mismatch`);
      for (let funcIndex = 0; funcIndex < functionCount; funcIndex += 1) {
        const bodySize = readULEB(wasm, cursor);
        cursor = bodySize.offset;
        const bodyEnd = cursor + Number(bodySize.value);
        const locals = readULEB(wasm, cursor);
        cursor = locals.offset;
        for (let localIndex = 0n; localIndex < locals.value; localIndex += 1n) {
          cursor = readULEB(wasm, cursor).offset;
          cursor += 1;
        }
        while (cursor < bodyEnd) cursor = skipStrictInstruction(wasm, cursor, callGraph[funcIndex], label);
        if (cursor !== bodyEnd) throw new Error(`${label} function body is malformed`);
      }
    }
    offset = sectionEnd;
  }
}

function skipStaticExportInstruction(wasm, offset, metrics, label) {
  const opcode = wasm[offset++];
  if (opcode === undefined) throw new Error(`${label} has a truncated instruction`);
  if (opcode === 0x02 || opcode === 0x03 || opcode === 0x04) {
    metrics.control += 1;
    if (opcode === 0x03) metrics.loop += 1;
    return readBlockType(wasm, offset);
  }
  if (opcode === 0x0c || opcode === 0x0d || opcode === 0x0e) metrics.control += 1;
  if (opcode === 0x10 || opcode === 0x11 || opcode === 0x12 || opcode === 0x13 || opcode === 0x14 || opcode === 0xd2) metrics.call += 1;
  if (opcode >= 0x20 && opcode <= 0x22) metrics.local += 1;
  if ((opcode >= 0x24 && opcode <= 0x26) || (opcode >= 0x28 && opcode <= 0x40) || opcode === 0xfc || opcode === 0xfe) metrics.memoryOrTable += 1;
  return skipStrictInstruction(wasm, offset - 1, [], label);
}

function analyzeStaticExports(wasm, label) {
  let offset = 8;
  let importedFuncCount = 0;
  let definedFuncCount = 0;
  const exportsByName = new Map();
  const metricsByDefinedFunc = [];
  while (offset < wasm.length) {
    const sectionID = wasm[offset++];
    const size = readULEB(wasm, offset);
    offset = size.offset;
    const sectionEnd = offset + Number(size.value);
    if (sectionEnd > wasm.length) throw new Error(`${label} has a truncated Wasm section`);
    if (sectionID === 2) {
      let cursor = offset;
      const count = readULEB(wasm, cursor);
      cursor = count.offset;
      for (let index = 0n; index < count.value; index += 1n) {
        cursor = readName(wasm, cursor).offset;
        cursor = readName(wasm, cursor).offset;
        const kind = wasm[cursor++];
        if (kind === 0x00) {
          importedFuncCount += 1;
          cursor = readULEB(wasm, cursor).offset;
        } else if (kind === 0x01) {
          cursor += 1;
          cursor = readLimits(wasm, cursor, label).offset;
        } else if (kind === 0x02) {
          cursor = readLimits(wasm, cursor, label).offset;
        } else if (kind === 0x03) {
          cursor += 2;
        } else {
          throw new Error(`${label} has an unknown import kind`);
        }
      }
    } else if (sectionID === 3) {
      const count = readULEB(wasm, offset);
      definedFuncCount = Number(count.value);
    } else if (sectionID === 7) {
      let cursor = offset;
      const count = readULEB(wasm, cursor);
      cursor = count.offset;
      for (let index = 0n; index < count.value; index += 1n) {
        const name = readName(wasm, cursor);
        cursor = name.offset;
        const kind = wasm[cursor++];
        const item = readULEB(wasm, cursor);
        cursor = item.offset;
        exportsByName.set(name.value, { kind, index: Number(item.value) });
      }
    } else if (sectionID === 10) {
      let cursor = offset;
      const count = readULEB(wasm, cursor);
      cursor = count.offset;
      if (Number(count.value) !== definedFuncCount) throw new Error(`${label} code/function section count mismatch`);
      for (let funcIndex = 0; funcIndex < definedFuncCount; funcIndex += 1) {
        const bodySize = readULEB(wasm, cursor);
        cursor = bodySize.offset;
        const bodyEnd = cursor + Number(bodySize.value);
        const locals = readULEB(wasm, cursor);
        cursor = locals.offset;
        for (let localIndex = 0n; localIndex < locals.value; localIndex += 1n) {
          cursor = readULEB(wasm, cursor).offset;
          cursor += 1;
        }
        const metrics = { call: 0, loop: 0, control: 0, local: 0, memoryOrTable: 0 };
        while (cursor < bodyEnd) cursor = skipStaticExportInstruction(wasm, cursor, metrics, label);
        metricsByDefinedFunc[funcIndex] = metrics;
      }
    }
    offset = sectionEnd;
  }
  return { importedFuncCount, exportsByName, metricsByDefinedFunc };
}

function failStaticExports(message) {
  throw new Error(message ?? "comply: static qip contract checks failed");
}

function requireFunctionExport(analysis, name, label) {
  const exp = analysis.exportsByName.get(name);
  if (!exp) failStaticExports(`${label} must export ${name}`);
  if (exp.kind !== 0x00) failStaticExports(`${label} export ${name} must be a function`);
  return exp;
}

function requireStaticFunctionExport(analysis, name, label) {
  const exp = requireFunctionExport(analysis, name, label);
  if (exp.index < analysis.importedFuncCount) failStaticExports("comply: static qip contract checks failed");
  const defIndex = exp.index - analysis.importedFuncCount;
  const metrics = analysis.metricsByDefinedFunc[defIndex];
  if (!metrics) failStaticExports("comply: static qip contract checks failed");
  if (metrics.call || metrics.loop || metrics.control || metrics.local || metrics.memoryOrTable) {
    failStaticExports("comply: static qip contract checks failed");
  }
}

function wasmMustExportComponentFunctions(data, label) {
  const analysis = analyzeStaticExports(data, label);
  const memory = analysis.exportsByName.get("memory");
  if (!memory) failStaticExports(`${label} does not export memory`);
  if (memory.kind !== 0x02) failStaticExports(`${label} export memory must be memory`);
  requireFunctionExport(analysis, "render", label);
  requireStaticFunctionExport(analysis, "input_ptr", label);
  const hasInputUTF8 = analysis.exportsByName.has("input_utf8_cap");
  const hasInputBytes = analysis.exportsByName.has("input_bytes_cap");
  if (hasInputUTF8 === hasInputBytes) failStaticExports(`${label} must export exactly one input capacity: input_utf8_cap or input_bytes_cap`);
  requireStaticFunctionExport(analysis, hasInputUTF8 ? "input_utf8_cap" : "input_bytes_cap", label);
  requireStaticFunctionExport(analysis, "output_ptr", label);
  const hasOutputUTF8 = analysis.exportsByName.has("output_utf8_cap");
  const hasOutputBytes = analysis.exportsByName.has("output_bytes_cap");
  if (hasOutputUTF8 === hasOutputBytes) failStaticExports(`${label} must export exactly one output capacity: output_utf8_cap or output_bytes_cap`);
  requireStaticFunctionExport(analysis, hasOutputUTF8 ? "output_utf8_cap" : "output_bytes_cap", label);

  for (const prefix of ["input", "output"]) {
    const hasPtr = analysis.exportsByName.has(`${prefix}_content_type_ptr`);
    const hasSize = analysis.exportsByName.has(`${prefix}_content_type_size`);
    if (hasPtr !== hasSize) failStaticExports(`${label} has incomplete ${prefix} content-type exports`);
    if (hasPtr) {
      requireStaticFunctionExport(analysis, `${prefix}_content_type_ptr`, label);
      requireStaticFunctionExport(analysis, `${prefix}_content_type_size`, label);
    }
  }

  for (const name of staticExportNames) {
    const exp = analysis.exportsByName.get(name);
    if (!exp) continue;
    requireStaticFunctionExport(analysis, name, label);
  }
}

export function wasmMustComplyWithComponentContract(wasm, options = {}) {
  const contract = componentContractOptions(options);
  const label = contract.label ?? "component";
  const data = bytes(wasm);
  const maxMemory = contract.maxMemory === undefined || contract.maxMemory === null || contract.maxMemory === "" ? undefined : parseMaxMemory(contract.maxMemory);
  validateMemoryPolicy(data, label, { maxMemory });
  validateStrictInstructions(data, label);
  wasmMustExportComponentFunctions(data, label);
}

export function newComponent(instance, options = {}) {
  const contract = componentContractOptions(options);
  const label = contract.label ?? "component";
  const exports = instance.exports;
  if (!(exports.memory instanceof WebAssembly.Memory)) throw new Error(`${label} does not export memory`);
  requireFunction(exports, "render", label);
  const hasInputUTF8 = typeof exports.input_utf8_cap === "function";
  const hasInputBytes = typeof exports.input_bytes_cap === "function";
  const hasOutputUTF8 = typeof exports.output_utf8_cap === "function";
  const hasOutputBytes = typeof exports.output_bytes_cap === "function";
  if (hasInputUTF8 === hasInputBytes) throw new Error(`${label} must export exactly one input capacity: input_utf8_cap or input_bytes_cap`);
  if (hasOutputUTF8 === hasOutputBytes) throw new Error(`${label} must export exactly one output capacity: output_utf8_cap or output_bytes_cap`);
  const inputCapName = hasInputUTF8 ? "input_utf8_cap" : "input_bytes_cap";
  const outputCapName = hasOutputUTF8 ? "output_utf8_cap" : "output_bytes_cap";
  exportedValue(exports, "input_ptr", label);
  exportedValue(exports, inputCapName, label);
  exportedValue(exports, "output_ptr", label);
  exportedValue(exports, outputCapName, label);
  const component = Object.freeze({
    label,
    instance,
    exports,
    input: new ContentContract(hasInputUTF8 ? "utf8" : "bytes", declaredType(exports, "input", label) || undefined),
    output: new ContentContract(hasOutputUTF8 ? "utf8" : "bytes", declaredType(exports, "output", label) || undefined),
    inputCapName,
    outputCapName,
    clearsContentType: hasOutputUTF8 && hasInputBytes,
    inputCapacity: exportedValue(exports, inputCapName, label),
    outputCapacity: exportedValue(exports, outputCapName, label),
  });
  assertComponentContract(component, "input", contract.input);
  assertComponentContract(component, "output", contract.output);
  return component;
}

function makeStage(spec, component) {
  const stage = {
    label: spec.label ?? spec.filePath ?? component.label,
    uniforms: spec.uniforms ?? [],
    component,
    input: component.input,
    output: component.output,
    inputCapName: component.inputCapName,
    outputCapName: component.outputCapName,
    clearsContentType: component.clearsContentType,
    inputCapacity: component.inputCapacity,
    outputCapacity: component.outputCapacity,
  };
  validateUniforms(stage);
  return stage;
}

function runStage(stage, input) {
  applyUniforms(stage);
  const { exports } = stage.component;
  const inputPointer = exportedValue(exports, "input_ptr", stage.label);
  const inputCapacity = exportedValue(exports, stage.inputCapName, stage.label);
  if (input.byteLength > inputCapacity || inputPointer + input.byteLength > exports.memory.buffer.byteLength) {
    throw new RangeError(`${stage.label} input exceeds its capacity`);
  }
  new Uint8Array(exports.memory.buffer, inputPointer, input.byteLength).set(input);
  const outputLength = Number(exports.render(input.byteLength)) >>> 0;
  const outputPointer = exportedValue(exports, "output_ptr", stage.label);
  const outputCapacity = exportedValue(exports, stage.outputCapName, stage.label);
  if (outputLength > outputCapacity || outputPointer + outputLength > exports.memory.buffer.byteLength) {
    throw new RangeError(`${stage.label} returned an invalid output length`);
  }
  return new Uint8Array(exports.memory.buffer, outputPointer, outputLength).slice();
}

function resolveStageInputType(stage, currentType, allowMissingInputContentType) {
  let effectiveType = currentType;
  if (!effectiveType && stage.input.contentType && allowMissingInputContentType) effectiveType = stage.input.contentType;
  if (stage.input.contentType && effectiveType !== stage.input.contentType) {
    if (!effectiveType) throw new Error(`${stage.label} expects ${stage.input.contentType}, but pipeline content type is unspecified`);
    throw new Error(`${stage.label} expects ${stage.input.contentType}, got ${effectiveType}`);
  }
  return effectiveType;
}

function nextContentType(stage, effectiveInputType) {
  if (stage.output.contentType) return stage.output.contentType;
  if (stage.clearsContentType) return "";
  return effectiveInputType;
}

function parseMaxMemory(value) {
  if (!/^\d+$/.test(String(value))) throw new Error(`invalid --max-memory ${value}`);
  const parsed = BigInt(value);
  if (parsed <= 0n || parsed > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error(`invalid --max-memory ${value}`);
  return Number(parsed);
}

function parseU32Flag(name, value) {
  if (!/^\d+$/.test(String(value))) throw new Error(`invalid ${name} ${value}`);
  const parsed = BigInt(value);
  if (parsed < 0n || parsed > 0xffffffffn) throw new Error(`invalid ${name} ${value}`);
  return Number(parsed);
}

function validatePipeline(stages, options = {}) {
  if (!Array.isArray(stages) || stages.length === 0) throw new Error("at least one component is required");
  let currentType = options.inputContentType ?? "";
  if (currentType) validateContentType(currentType, "input content type");
  stages.forEach((stage, index) => {
    const effectiveType = resolveStageInputType(stage, currentType, index === 0 && !options.inputContentType);
    currentType = nextContentType(stage, effectiveType);
    if (options.capacitiesMustFit && index + 1 < stages.length) {
      const nextStage = stages[index + 1];
      if (stage.outputCapacity > nextStage.inputCapacity) {
        throw new Error(`${stage.label} output capacity ${stage.outputCapacity} exceeds ${nextStage.label} input capacity ${nextStage.inputCapacity}`);
      }
    }
  });
  const last = stages.at(-1);
  return Object.freeze({
    stages,
    inputContentType: options.inputContentType ?? "",
    outputContentType: currentType,
    outputEncoding: last.output.encoding,
  });
}

function runPreparedPipeline(input, pipeline) {
  let output = bytes(input);
  let currentType = pipeline.inputContentType;
  for (let index = 0; index < pipeline.stages.length; index += 1) {
    const stage = pipeline.stages[index];
    const effectiveType = resolveStageInputType(stage, currentType, index === 0 && !pipeline.inputContentType);
    output = runStage(stage, output);
    currentType = nextContentType(stage, effectiveType);
  }
  return pipelineResult(output, currentType, pipeline.outputEncoding);
}

function pipelineResult(bytesOut, contentType, outputEncoding) {
  let decoded;
  let hasDecoded = false;
  return Object.freeze({
    bytes: bytesOut,
    contentType,
    outputEncoding,
    get text() {
      if (outputEncoding !== "utf8") throw new Error("pipeline output is bytes, not UTF-8");
      if (!hasDecoded) {
        decoded = decoder.decode(bytesOut);
        hasDecoded = true;
      }
      return decoded;
    },
  });
}

export function createPipeline(componentSpecs, options = {}) {
  const stages = [];
  for (const spec of componentSpecs) {
    if (!spec.component) throw new Error("stage requires component");
    stages.push(makeStage(spec, spec.component));
  }
  const plan = validatePipeline(stages, options);
  return Object.freeze({
    ...plan,
    run(input) {
      return runPreparedPipeline(input, plan);
    },
  });
}

async function walkWasmFiles(path) {
  const info = await stat(path);
  if (info.isFile()) {
    if (!path.endsWith(".wasm")) throw new Error(`${path} is not a .wasm file`);
    return [path];
  }
  if (!info.isDirectory()) throw new Error(`${path} is not a file or directory`);
  const files = [];
  async function walk(directory) {
    const entries = await readdir(directory, { withFileTypes: true });
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      const child = join(directory, entry.name);
      if (entry.isDirectory()) await walk(child);
      else if (entry.isFile() && entry.name.endsWith(".wasm")) files.push(child);
      else if (entry.isSymbolicLink()) {
        const childInfo = await stat(child);
        if (childInfo.isDirectory()) await walk(child);
        else if (childInfo.isFile() && entry.name.endsWith(".wasm")) files.push(child);
      }
    }
  }
  await walk(path);
  return files;
}

async function discoverWasmFiles(paths) {
  const files = [];
  for (const path of paths) files.push(...await walkWasmFiles(path));
  return [...new Set(files)].sort((a, b) => a.localeCompare(b));
}

function parseComplyCLI(argv) {
  // TODO: Add --straight-line-oracles for --with oracles so JS comply can
  // match Go's audit mode for fixture-style Compliance oracles.
  const options = { maxMemory: undefined, with: [], seed: undefined };
  const paths = [];
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--help" || arg === "-h") {
      console.log(complyUsage());
      process.exit(0);
    } else if (arg === "--max-memory") {
      options.maxMemory = parseMaxMemory(argv[++index]);
    } else if (arg === "--with") {
      const value = argv[++index];
      if (!value) throw new Error("--with requires a path");
      options.with.push(value);
    } else if (arg === "--seed") {
      options.seed = parseU32Flag("--seed", argv[++index]);
    } else if (arg.startsWith("-")) {
      throw new Error(`unknown comply option ${arg}`);
    } else {
      paths.push(arg);
    }
  }
  if (paths.length === 0) throw new Error("comply requires at least one file or directory");
  options.with.sort((a, b) => a.localeCompare(b));
  return { options, paths };
}

function readMemory(memory, ptr, length) {
  const start = Number(ptr) >>> 0;
  const size = Number(length) >>> 0;
  if (start + size > memory.buffer.byteLength) return null;
  return new Uint8Array(memory.buffer, start, size).slice();
}

function renderComponent(component, input) {
  const stage = makeStage({ component }, component);
  return runStage(stage, bytes(input));
}

async function instantiateContentComponent(wasm, label, options = {}) {
  wasmMustComplyWithComponentContract(wasm, { label, maxMemory: options.maxMemory });
  const module = new WebAssembly.Module(wasm);
  const instance = new WebAssembly.Instance(module);
  return newComponent(instance, { label });
}

function instantiateComplianceOracle(wasm, label, imports) {
  const module = new WebAssembly.Module(wasm);
  const instance = new WebAssembly.Instance(module, imports);
  if (!(instance.exports.memory instanceof WebAssembly.Memory)) throw new Error(`${label} Compliance oracle must export memory`);
  if (typeof instance.exports.comply !== "function") throw new Error(`${label} Compliance oracle must export comply() -> i32`);
  return instance;
}

async function runComplianceOracle(implWasm, implPath, oraclePath, options = {}) {
  const oracleWasm = await readFile(oraclePath);
  const impl = await instantiateContentComponent(implWasm, implPath, options);
  let oracleInstance;
  const state = { next: 0n, openRenderInto: null, openRenderIntoFailed: false, openRenderIntoErrorCount: 0, failCount: 0, failures: [], protocolError: null };
  const failProtocol = (message) => {
    if (!state.protocolError) state.protocolError = message;
  };
  const oracleMemory = () => oracleInstance?.exports?.memory;
  const readOracle = (ptr, length) => {
    const memory = oracleMemory();
    if (!(memory instanceof WebAssembly.Memory)) return null;
    return readMemory(memory, ptr, length);
  };
  const caseOpen = (ordinal, kind) => {
    const ord = BigInt(ordinal);
    if (state.openRenderInto !== null) {
      failProtocol(`${kind} at ordinal ${ord} inside open must_render_into case ${state.openRenderInto}`);
      return false;
    }
    if (ord !== state.next) {
      failProtocol(`${kind} declared ordinal ${ord}, host expected ${state.next}`);
      return false;
    }
    return true;
  };
  const qip = {
    set_uniform_u32(namePtr, nameLen, value) {
      if (state.openRenderInto !== null) {
        failProtocol(`set_uniform_u32 called inside open must_render_into case ${state.openRenderInto}`);
        return 0;
      }
      if (nameLen === 0 || nameLen > 128) {
        failProtocol(`set_uniform_u32 name length ${nameLen} is outside 1..128`);
        return 0;
      }
      const nameBytes = readOracle(namePtr, nameLen);
      if (!nameBytes) {
        failProtocol("set_uniform_u32 name pointer out of range");
        return 0;
      }
      const name = decoder.decode(nameBytes);
      if (!validUniformKey(name)) {
        failProtocol(`set_uniform_u32 name ${JSON.stringify(name)} is not a valid uniform key`);
        return 0;
      }
      const setter = impl.exports[`uniform_set_${name}`];
      if (typeof setter !== "function") {
        failProtocol(`implementation does not export uniform_set_${name}`);
        return 0;
      }
      try {
        return Number(setter(Number(value) >>> 0)) | 0;
      } catch (error) {
        failProtocol(`uniform_set_${name} trapped: ${error.message ?? error}`);
        return 0;
      }
    },
    must_render_exactly(ordinal, inPtr, inLen, expPtr, expLen) {
      if (!caseOpen(ordinal, "must_render_exactly")) return 0;
      state.next += 1n;
      const input = readOracle(inPtr, inLen);
      const expected = readOracle(expPtr, expLen);
      if (!input || !expected) {
        failProtocol(`must_render_exactly pointers out of range at ordinal ${ordinal}`);
        return 0;
      }
      try {
        const actual = renderComponent(impl, input);
        if (actual.byteLength !== expected.byteLength || actual.some((byte, index) => byte !== expected[index])) {
          state.failCount += 1;
          state.failures.push(`case ${ordinal}: output mismatch`);
          return 0;
        }
        return 1;
      } catch (error) {
        state.failCount += 1;
        state.failures.push(`case ${ordinal}: trapped: ${error.message ?? error}`);
        return 0;
      }
    },
    must_trap(ordinal, inPtr, inLen) {
      if (!caseOpen(ordinal, "must_trap")) return 0;
      state.next += 1n;
      const input = readOracle(inPtr, inLen);
      if (!input) {
        failProtocol(`must_trap pointer out of range at ordinal ${ordinal}`);
        return 0;
      }
      try {
        renderComponent(impl, input);
        state.failCount += 1;
        state.failures.push(`case ${ordinal}: expected trap, got output`);
        return 0;
      } catch {
        return 1;
      }
    },
    must_render_into(ordinal, inPtr, inLen, outPtr, outCap) {
      const ord = BigInt(ordinal);
      if (state.openRenderInto !== null) {
        failProtocol(`must_render_into opened ordinal ${ord} while ordinal ${state.openRenderInto} is still open`);
        return -1;
      }
      if (ord !== state.next) {
        failProtocol(`must_render_into opened ordinal ${ord}, host expected ${state.next}`);
        return -1;
      }
      state.openRenderInto = ord;
      state.openRenderIntoFailed = false;
      state.openRenderIntoErrorCount = 0;
      const input = readOracle(inPtr, inLen);
      if (!input) {
        state.openRenderIntoFailed = true;
        failProtocol(`must_render_into pointer out of range at ordinal ${ord}`);
        return -1;
      }
      let output;
      try {
        output = renderComponent(impl, input);
      } catch {
        state.openRenderIntoFailed = true;
        return -1;
      }
      if (output.byteLength > (Number(outCap) >>> 0)) {
        state.openRenderIntoFailed = true;
        return -2;
      }
      const memory = oracleMemory();
      const outStart = Number(outPtr) >>> 0;
      if (outStart + output.byteLength > memory.buffer.byteLength) {
        state.openRenderIntoFailed = true;
        failProtocol(`must_render_into out pointer out of range at ordinal ${ord}`);
        return -1;
      }
      new Uint8Array(memory.buffer, outStart, output.byteLength).set(output);
      return output.byteLength;
    },
    must_render_into_emit_error(ordinal, messagePtr, messageSize) {
      const ord = BigInt(ordinal);
      if (state.openRenderInto === null || state.openRenderInto !== ord) {
        failProtocol(`must_render_into_emit_error ordinal ${ord} does not match open must_render_into case ${state.openRenderInto}`);
        return 0;
      }
      const message = readOracle(messagePtr, messageSize);
      if (!message) {
        failProtocol(`must_render_into_emit_error message pointer out of range at ordinal ${ord}`);
        return 0;
      }
      state.openRenderIntoErrorCount += 1;
      state.failures.push(`case ${ord}: render_into error: ${decoder.decode(message)}`);
      return 1;
    },
    must_render_into_finish(ordinal, errorCount) {
      const ord = BigInt(ordinal);
      const count = Number(errorCount) >>> 0;
      if (state.openRenderInto === null || state.openRenderInto !== ord) {
        failProtocol(`must_render_into_finish ordinal ${ord} does not match open must_render_into case ${state.openRenderInto}`);
        return 0;
      }
      if (count !== state.openRenderIntoErrorCount) {
        failProtocol(`must_render_into_finish ordinal ${ord} reported ${count} errors, host observed ${state.openRenderIntoErrorCount}`);
        return 0;
      }
      if (state.openRenderIntoFailed && count === 0) {
        failProtocol(`must_render_into_finish ordinal ${ord} reported 0 errors after render failure`);
        return 0;
      }
      if (count > 0) state.failCount += 1;
      state.openRenderInto = null;
      state.openRenderIntoFailed = false;
      state.openRenderIntoErrorCount = 0;
      state.next += 1n;
      return 1;
    },
  };
  oracleInstance = instantiateComplianceOracle(oracleWasm, oraclePath, { qip });
  if (options.seed !== undefined) {
    const setSeed = oracleInstance.exports.uniform_set_seed;
    if (typeof setSeed !== "function") throw new Error(`${oraclePath}: --seed given but Compliance oracle does not export uniform_set_seed`);
    try {
      setSeed(options.seed >>> 0);
    } catch (error) {
      throw new Error(`${oraclePath}: uniform_set_seed failed: ${error.message ?? error}`);
    }
  }
  let declared;
  try {
    declared = Number(oracleInstance.exports.comply()) | 0;
  } catch (error) {
    throw new Error(`${oraclePath}: comply() trapped: ${error.message ?? error}`);
  }
  if (state.protocolError) throw new Error(`${oraclePath}: bridge protocol violation: ${state.protocolError}`);
  if (state.openRenderInto !== null) throw new Error(`${oraclePath}: comply() returned with must_render_into case ${state.openRenderInto} still open`);
  if (declared <= 0) throw new Error(`${oraclePath}: comply() declared no cases (returned ${declared})`);
  if (BigInt(declared >>> 0) !== state.next) throw new Error(`${oraclePath}: comply() returned ${declared} cases but host counted ${state.next}`);
  if (state.failCount > 0) throw new Error(`${oraclePath}: ${state.failCount}/${state.next} cases failed; ${state.failures[0]}`);
  return { cases: Number(state.next) };
}

async function complyCommand(argv) {
  const { options, paths } = parseComplyCLI(argv);
  const files = await discoverWasmFiles(paths);
  if (files.length === 0) throw new Error("No .wasm files found");
  let pass = 0;
  let fail = 0;
  for (const file of files) {
    let wasm;
    try {
      wasm = await readFile(file);
      await instantiateContentComponent(wasm, file, options);
      console.log(`PASS ${file}`);
      pass += 1;
    } catch (error) {
      console.log(`FAIL ${file}: ${error.message ?? error}`);
      fail += 1;
      continue;
    }
    for (const oracle of options.with) {
      try {
        const result = await runComplianceOracle(wasm, file, oracle, options);
        console.log(`PASS ${file} --with ${oracle} (${result.cases} cases)`);
        pass += 1;
      } catch (error) {
        console.log(`FAIL ${file} --with ${oracle}: ${error.message ?? error}`);
        fail += 1;
      }
    }
  }
  console.log(`\npass=${pass} fail=${fail} total=${pass + fail}`);
  if (fail > 0) process.exitCode = 1;
}

function parseStageArgs(args) {
  const stages = [];
  for (const arg of args) {
    if (arg.startsWith("?")) {
      if (stages.length === 0) throw new Error(`uniform query ${arg} has no preceding component`);
      for (const [key, value] of new URLSearchParams(arg)) stages.at(-1).uniforms.push([key, value]);
      continue;
    }
    const queryIndex = arg.indexOf("?");
    const filePath = queryIndex === -1 ? arg : arg.slice(0, queryIndex);
    const query = queryIndex === -1 ? "" : arg.slice(queryIndex);
    const stage = { filePath, label: filePath, uniforms: [] };
    if (!stage.filePath) throw new Error("component path must not be empty");
    if (query) for (const [key, value] of new URLSearchParams(query)) stage.uniforms.push([key, value]);
    stages.push(stage);
  }
  return stages;
}

function parseCLI(argv) {
  const options = { input: "-", output: "-", maxMemory: undefined, capacitiesMustFit: false };
  const components = [];
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--") {
      components.push(...argv.slice(index + 1));
      break;
    } else if (arg === "-i" || arg === "--input") {
      options.input = argv[++index];
    } else if (arg === "-o" || arg === "--output") {
      options.output = argv[++index];
    } else if (arg === "--max-memory") {
      options.maxMemory = parseMaxMemory(argv[++index]);
    } else if (arg === "--capacities-must-fit") {
      options.capacitiesMustFit = true;
    } else if (arg.startsWith("-") && !arg.startsWith("?")) {
      throw new Error(`unknown option ${arg}`);
    } else {
      components.push(arg);
    }
  }
  if (!options.input) throw new Error("--input requires a path");
  if (!options.output) throw new Error("--output requires a path");
  return { options, components: parseStageArgs(components) };
}

async function loadStages(componentSpecs, options) {
  const stages = [];
  for (const spec of componentSpecs) {
    const wasm = await readFile(spec.filePath);
    wasmMustComplyWithComponentContract(wasm, { maxMemory: options.maxMemory, label: spec.label });
    const module = new WebAssembly.Module(wasm);
    const instance = new WebAssembly.Instance(module);
    const component = newComponent(instance, { label: spec.label });
    stages.push({ component, label: spec.label, uniforms: spec.uniforms });
  }
  return stages;
}

async function prepareRunPipeline(argv) {
  const { options, components } = parseCLI(argv);
  const stages = await loadStages(components, options);
  const pipeline = createPipeline(stages, {
    capacitiesMustFit: options.capacitiesMustFit,
  });
  return { options, pipeline };
}

function formatBytes(count) {
  if (count < 1024) return `${count} bytes`;
  const units = ["KiB", "MiB", "GiB"];
  let value = count;
  let unit = "bytes";
  for (const next of units) {
    if (value < 1024) break;
    value /= 1024;
    unit = next;
  }
  return `${value.toFixed(1)} ${unit} (${count} bytes)`;
}

function applyPipelineUniforms(plan) {
  for (const stage of plan.stages) applyUniforms(stage);
}

function printDryRunPlan(plan) {
  console.log(`Pipeline compatible: ${plan.stages.length} step(s)`);
  let total = 0;
  plan.stages.forEach((stage, index) => {
    const buffers = stage.inputCapacity + stage.outputCapacity;
    total += buffers;
    console.log(`${index + 1}. ${stage.label} — Content`);
    console.log(`   Input:  encoding=${stage.input.encoding === "utf8" ? "UTF-8" : "bytes"}, type=${stage.input.contentType || "unspecified"}, capacity=${formatBytes(stage.inputCapacity)}`);
    console.log(`   Output: encoding=${stage.output.encoding === "utf8" ? "UTF-8" : "bytes"}, type=${stage.output.contentType || "unspecified"}, capacity=${formatBytes(stage.outputCapacity)}`);
    console.log(`   Buffers: ${formatBytes(buffers)}`);
  });
  console.log(`Total declared buffer capacity: ${formatBytes(total)}`);
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(bytes(chunk));
  const length = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0);
  const out = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

export async function main(argv = process.argv.slice(2)) {
  if (argv.length === 0 || argv[0] === "--help" || argv[0] === "-h" || argv[0] === "help") {
    console.log(usage());
    return;
  }
  if (argv[0] === "comply") {
    await complyCommand(argv.slice(1));
    return;
  }
  if (argv[0] === "bench") {
    throw new Error("qipx bench is coming soon");
  }
  let dryRun = false;
  if (argv[0] === "dry" && argv[1] === "run") {
    dryRun = true;
    argv = argv.slice(2);
  } else if (argv[0] === "dry-run") {
    dryRun = true;
    argv = argv.slice(1);
  } else if (argv[0] === "run") {
    argv = argv.slice(1);
  }
  const { options, pipeline } = await prepareRunPipeline(argv);
  if (dryRun) {
    applyPipelineUniforms(pipeline);
    printDryRunPlan(pipeline);
    return;
  }
  const input = options.input === "-" ? await readStdin() : await readFile(options.input);
  const result = pipeline.run(input);
  if (options.output === "-") {
    process.stdout.write(result.bytes);
    if (result.outputEncoding === "utf8") process.stdout.write("\n");
  } else {
    await writeFile(options.output, result.bytes);
  }
}

const invokedPath = process.argv[1] ? realpathSync(resolve(process.argv[1])) : "";
const modulePath = realpathSync(fileURLToPath(import.meta.url));
if (invokedPath === modulePath) {
  main().catch((error) => {
    console.error(error.message ?? error);
    process.exitCode = 1;
  });
}
