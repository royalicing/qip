const utf8Decoder = new TextDecoder("utf-8", { fatal: true });
const utf8Encoder = new TextEncoder();

export class ContentRenderTrap extends Error {
  constructor(label, cause) {
    super(`${label} render trapped: ${cause?.message ?? cause}`);
    this.name = "ContentRenderTrap";
    this.cause = cause;
  }
}

export class ContentCommitTrap extends Error {
  constructor(label, cause) {
    super(`${label} commit trapped; commit() must not trap: ${cause?.message ?? cause}`);
    this.name = "ContentCommitTrap";
    this.cause = cause;
  }
}

export class ContentUniformTrap extends Error {
  constructor(label, key, cause) {
    super(`${label} uniform_set_${key} trapped: ${cause?.message ?? cause}`);
    this.name = "ContentUniformTrap";
    this.cause = cause;
  }
}

export class ContentComponentHost {
  constructor(wasmBytes, { label = "component" } = {}) {
    this.label = label;
    this.module = new WebAssembly.Module(wasmBytes);
    this.instance = null;
    this.instanceCount = 0;
  }

  instantiate() {
    this.instance = new WebAssembly.Instance(this.module);
    this.instanceCount += 1;
    return this.instance;
  }

  discard() {
    this.instance = null;
  }

  run(input, { uniforms = {} } = {}) {
    const instance = this.instance ?? this.instantiate();
    const exports = instance.exports;
    const inputBytes = typeof input === "string" ? utf8Encoder.encode(input) : new Uint8Array(input);
    const hasInputUTF8 = typeof exports.input_utf8_cap === "function";
    const hasInputBytes = typeof exports.input_bytes_cap === "function";
    if (hasInputUTF8 === hasInputBytes) {
      throw new TypeError(`${this.label} must export exactly one input capacity`);
    }
    if (hasInputUTF8 && typeof input !== "string") utf8Decoder.decode(inputBytes);

    const inputCapacity = Number((hasInputUTF8 ? exports.input_utf8_cap : exports.input_bytes_cap)()) >>> 0;
    const inputPointer = Number(exports.input_ptr()) >>> 0;
    if (inputBytes.byteLength > inputCapacity || inputPointer + inputBytes.byteLength > exports.memory.buffer.byteLength) {
      throw new RangeError(`${this.label} input exceeds its capacity`);
    }
    new Uint8Array(exports.memory.buffer, inputPointer, inputBytes.byteLength).set(inputBytes);

    for (const key of Object.keys(uniforms).sort()) {
      const setter = exports[`uniform_set_${key}`];
      if (typeof setter !== "function") throw new TypeError(`${this.label} does not export uniform_set_${key}`);
      try {
        setter(uniforms[key]);
      } catch (error) {
        this.discard();
        throw new ContentUniformTrap(this.label, key, error);
      }
    }

    let outputSize;
    try {
      outputSize = Number(exports.render(inputBytes.byteLength)) >>> 0;
    } catch (error) {
      this.discard();
      throw new ContentRenderTrap(this.label, error);
    }

    if (typeof exports.commit === "function") {
      let result;
      try {
        result = exports.commit();
      } catch (error) {
        this.discard();
        throw new ContentCommitTrap(this.label, error);
      }
      if (typeof result !== "bigint") {
        this.discard();
        throw new TypeError(`${this.label} commit export must have signature commit() -> i64`);
      }
      if (result < 0n) {
        const bits = BigInt.asUintN(64, result);
        return Object.freeze({
          status: "rejected",
          commitResult: result,
          invalidInput: (bits & (1n << 62n)) !== 0n,
          detail: Number(bits & 0xffff_ffffn),
        });
      }
    }

    const hasOutputUTF8 = typeof exports.output_utf8_cap === "function";
    const hasOutputBytes = typeof exports.output_bytes_cap === "function";
    if (hasOutputUTF8 === hasOutputBytes) throw new TypeError(`${this.label} must export exactly one output capacity`);
    const outputCapacity = Number((hasOutputUTF8 ? exports.output_utf8_cap : exports.output_bytes_cap)()) >>> 0;
    const outputPointer = Number(exports.output_ptr()) >>> 0;
    if (outputSize > outputCapacity || outputPointer + outputSize > exports.memory.buffer.byteLength) {
      this.discard();
      throw new RangeError(`${this.label} returned output outside its declared capacity`);
    }
    const output = new Uint8Array(exports.memory.buffer, outputPointer, outputSize).slice();
    if (hasOutputUTF8) {
      try {
        utf8Decoder.decode(output);
      } catch (error) {
        this.discard();
        throw new TypeError(`${this.label} returned malformed output despite output_utf8_cap: ${error.message}`);
      }
    }
    return Object.freeze({ status: "accepted", output, outputIsUTF8: hasOutputUTF8 });
  }
}
