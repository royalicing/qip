self.onmessage = async (event) => {
  try {
    const input = new Uint8Array(event.data.input);
    const module = await WebAssembly.compileStreaming(
      fetch("/components/image/bmp/bmp-to-png.wasm"),
    );
    const exports = new WebAssembly.Instance(module, {}).exports;
    const inputCap = exports.input_bytes_cap() >>> 0;
    if (input.length > inputCap) {
      throw Error(`Decoded BMP exceeds component capacity: ${input.length} > ${inputCap} bytes.`);
    }
    new Uint8Array(exports.memory.buffer, exports.input_ptr() >>> 0, input.length)
      .set(input);
    const started = performance.now();
    const outputSize = exports.render(input.length) >>> 0;
    const elapsedMs = performance.now() - started;
    if (outputSize === 0) {
      throw Error("The PNG component rejected the decoded BMP.");
    }
    if (outputSize > (exports.output_bytes_cap() >>> 0)) {
      throw Error("The PNG component returned output beyond its declared capacity.");
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
