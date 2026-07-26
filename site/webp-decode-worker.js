function run(exports, input) {
  const inputCap = exports.input_bytes_cap() >>> 0;
  if (input.length > inputCap) {
    throw Error(`Input exceeds component capacity: ${input.length} > ${inputCap} bytes.`);
  }
  new Uint8Array(exports.memory.buffer, exports.input_ptr() >>> 0, input.length)
    .set(input);
  const outputSize = exports.render(input.length) >>> 0;
  if (outputSize === 0) {
    return null;
  }
  if (outputSize > (exports.output_bytes_cap() >>> 0)) {
    throw Error("A component returned output beyond its declared capacity.");
  }
  return new Uint8Array(
    exports.memory.buffer,
    exports.output_ptr() >>> 0,
    outputSize,
  ).slice();
}

self.onmessage = async (event) => {
  try {
    const { input, format } = event.data;
    const inputBytes = new Uint8Array(input);
    const decoderModule = await WebAssembly.compileStreaming(
      fetch("/components/image/webp/webp-to-bmp-bgra32.wasm"),
    );
    const decoder = new WebAssembly.Instance(decoderModule, {}).exports;
    decoder._initialize?.();
    const started = performance.now();
    const bmp = run(decoder, inputBytes);
    if (bmp === null) {
      throw Error(
        "The decoder rejected this WebP. It may be malformed, animated, or larger than 25 MP.",
      );
    }
    const view = new DataView(bmp.buffer, bmp.byteOffset, bmp.byteLength);
    const width = view.getInt32(18, true);
    const height = Math.abs(view.getInt32(22, true));
    let output = bmp;
    if (format === "png") {
      const pngModule = await WebAssembly.compileStreaming(
        fetch("/components/image/bmp/bmp-to-png.wasm"),
      );
      const pngEncoder = new WebAssembly.Instance(pngModule, {}).exports;
      pngEncoder._initialize?.();
      if (bmp.length > (pngEncoder.input_bytes_cap() >>> 0)) {
        throw Error(
          `PNG output supports decoded BMPs up to ${pngEncoder.input_bytes_cap() >>> 0} bytes; ` +
          "choose BMP for this larger image.",
        );
      }
      output = run(pngEncoder, bmp);
      if (output === null) {
        throw Error("The PNG component rejected the decoded BMP.");
      }
    } else if (format !== "bmp") {
      throw Error("Unknown output format.");
    }
    const elapsedMs = performance.now() - started;
    self.postMessage({
      type: "done",
      output: output.buffer,
      width,
      height,
      elapsedMs,
      peakBytes: decoder.arena_peak_bytes() >>> 0,
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
