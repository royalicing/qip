self.onmessage = async (event) => {
  try {
    const { input, mode, options } = event.data;
    const modulePath = mode === "lossless"
      ? "/components/image/bmp/bmp-to-webp-lossless.wasm"
      : mode === "opaque"
        ? "/components/image/bmp/bmp-to-webp-lossy-opaque.wasm"
        : "/components/image/bmp/bmp-to-webp-lossy.wasm";
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
        exports.uniform_set_background_color(options.backgroundColor);
      }
    }

    new Uint8Array(exports.memory.buffer, exports.input_ptr() >>> 0, inputBytes.length)
      .set(inputBytes);
    const started = performance.now();
    const outputSize = exports.render(inputBytes.length) >>> 0;
    const elapsedMs = performance.now() - started;
    if (outputSize === 0) {
      throw Error("The component rejected the BMP or ran out of fixed output/encoder memory.");
    }
    if (outputSize > (exports.output_bytes_cap() >>> 0)) {
      throw Error("The component returned an output larger than its declared capacity.");
    }
    const output = new Uint8Array(
      exports.memory.buffer,
      exports.output_ptr() >>> 0,
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
