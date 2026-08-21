const DECODER_PATHS = {
  jpeg: [
    "/components/image/jpeg/jpeg-to-bmp-b8g8r8a8-srgb.wasm",
  ],
  png: [
    "/components/image/png/png-to-bmp-b8g8r8a8-srgb-simd.wasm",
    "/components/image/png/png-to-bmp-b8g8r8a8-srgb.wasm",
  ],
};

function decoderError(error) {
  return error instanceof Error ? error.message : String(error);
}

async function compileDecoder(format) {
  let lastError = null;
  for (const path of DECODER_PATHS[format]) {
    try {
      const module = await WebAssembly.compileStreaming(fetch(path));
      return { module, path };
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError || Error(`No decoder is available for ${format}.`);
}

function readBMPMetadata(bytes) {
  if (bytes.length < 54 || bytes[0] !== 0x42 || bytes[1] !== 0x4d) {
    throw Error("The decoder did not return a BMP.");
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const pixelOffset = view.getUint32(10, true);
  const width = view.getInt32(18, true);
  const signedHeight = view.getInt32(22, true);
  const bits = view.getUint16(28, true);
  const compression = view.getUint32(30, true);
  const height = Math.abs(signedHeight);
  if (width <= 0 || signedHeight === 0 || bits !== 32 || compression !== 0) {
    throw Error("The decoder returned an unsupported BMP layout.");
  }
  const pixelBytes = width * height * 4;
  if (pixelOffset < 54 || pixelOffset + pixelBytes > bytes.length) {
    throw Error("The decoder returned a truncated BMP.");
  }
  let hasAlpha = false;
  for (let offset = pixelOffset + 3; offset < pixelOffset + pixelBytes; offset += 4) {
    if (bytes[offset] !== 255) {
      hasAlpha = true;
      break;
    }
  }
  return { width, height, pixels: width * height, hasAlpha };
}

function run(exports, input) {
  const inputCap = exports.input_bytes_cap() >>> 0;
  if (input.length > inputCap) {
    throw Error(`Input exceeds decoder capacity: ${input.length} > ${inputCap} bytes.`);
  }
  new Uint8Array(exports.memory.buffer, exports.input_ptr() >>> 0, input.length)
    .set(input);
  const outputSize = exports.render(input.length) >>> 0;
  if (outputSize === 0) {
    throw Error("The decoder rejected the image or exceeded its fixed output capacity.");
  }
  if (outputSize > (exports.output_bytes_cap() >>> 0)) {
    throw Error("The decoder returned output beyond its declared capacity.");
  }
  return new Uint8Array(
    exports.memory.buffer,
    exports.output_ptr() >>> 0,
    outputSize,
  ).slice();
}

self.onmessage = async (event) => {
  try {
    const { format, input } = event.data;
    if (!DECODER_PATHS[format]) throw Error("Choose a JPEG or PNG image.");
    const inputBytes = new Uint8Array(input);
    const { module, path } = await compileDecoder(format);
    const { exports } = new WebAssembly.Instance(module, {});
    exports._initialize?.();
    const started = performance.now();
    const bmp = run(exports, inputBytes);
    const metadata = readBMPMetadata(bmp);
    self.postMessage({
      type: "done",
      output: bmp.buffer,
      ...metadata,
      decoderPath: path,
      elapsedMs: performance.now() - started,
    }, [bmp.buffer]);
  } catch (error) {
    self.postMessage({ type: "error", message: decoderError(error) });
  } finally {
    self.close();
  }
};
