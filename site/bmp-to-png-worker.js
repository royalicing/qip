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
    const renderResult = exports.render(input.length);
    if (typeof renderResult !== "bigint") throw TypeError("render must return i64");
    const renderBits = BigInt.asUintN(64, renderResult);
    if ((renderBits & (1n << 63n)) !== 0n) throw Error("The PNG component rejected the decoded BMP.");
    const outputSize = Number(renderBits & 0xffff_ffffn);
    const outputPointer = Number((renderBits >> 32n) & 0x7fff_ffffn);
    const elapsedMs = performance.now() - started;
    if (outputSize === 0) {
      throw Error("The PNG component rejected the decoded BMP.");
    }
    if (outputSize > (exports.output_bytes_cap() >>> 0)) {
      throw Error("The PNG component returned output beyond its declared capacity.");
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
