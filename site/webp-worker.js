self.onmessage = async (event) => {
  try {
    const { input, mode, options } = event.data;
    const modulePath = mode === "lossless"
      ? "/image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossless.wasm"
      : mode === "opaque"
        ? "/image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy-opaque.wasm"
        : "/image/bmp/bmp-b8g8r8a8-srgb-to-webp-lossy.wasm";
    const module = await WebAssembly.compileStreaming(fetch(modulePath));
    const { exports } = new WebAssembly.Instance(module, {});
    const inputBytes = new Uint8Array(input);
    const inputCap = exports.input_bytes_cap() >>> 0;
    if (inputBytes.length > inputCap) {
      throw Error(`Input exceeds component capacity: ${inputBytes.length} > ${inputCap} bytes.`);
    }

    if (mode === "lossless") {
      exports.uniform_set_level(options.level);
    } else {
      exports.uniform_set_quality(options.quality);
      exports.uniform_set_method(options.method);
      exports.uniform_set_sharp_yuv(options.sharpYuv ? 1 : 0);
      exports.uniform_set_low_memory(options.lowMemory ? 1 : 0);
      if (mode === "opaque") {
        exports.uniform_set_background_color_rgb(options.backgroundColor);
      }
    }

    new Uint8Array(exports.memory.buffer, exports.input_ptr() >>> 0, inputBytes.length)
      .set(inputBytes);
    const started = performance.now();
    const renderResult = exports.render(inputBytes.length);
    if (typeof renderResult !== "bigint") throw TypeError("render must return i64");
    const renderBits = BigInt.asUintN(64, renderResult);
    if ((renderBits & (1n << 63n)) !== 0n) throw Error("The component rejected the BMP.");
    const outputSize = Number(renderBits & 0xffff_ffffn);
    const outputPointer = Number((renderBits >> 32n) & 0x7fff_ffffn);
    const elapsedMs = performance.now() - started;
    if (outputSize === 0) {
      throw Error("The component rejected the BMP or ran out of fixed output/encoder memory.");
    }
    if (outputSize > (exports.output_bytes_cap() >>> 0)) {
      throw Error("The component returned an output larger than its declared capacity.");
    }
    const output = new Uint8Array(
      exports.memory.buffer,
      outputPointer,
      outputSize,
    ).slice();
    self.postMessage({
      type: "done",
      output: output.buffer,
      elapsedMs,
      peakBytes: exports.arena_peak_bytes() >>> 0,
      allocations: exports.arena_allocation_count() >>> 0,
    }, [output.buffer]);
  } catch (error) {
    self.postMessage({
      type: "error",
      message: error instanceof Error ? error.message : String(error),
    });
  } finally {
    self.close();
  }
};
