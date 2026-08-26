<title>High-quality image resizer</title>

# High-quality image resizer

Resize JPEG, PNG, WebP, or AVIF images locally in your browser. Add several
images, choose one set of output options, then resize each image when you
download it. Files are not uploaded.

<style>
.image-resize-tool {
  display: grid;
  gap: 1rem;
}
.image-resize-tool input,
.image-resize-tool select,
.image-resize-tool button {
  font: inherit;
}
.image-resize-options,
.image-resize-toolbar,
.image-resize-row-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.75rem;
  align-items: end;
}
.image-resize-options label {
  display: grid;
  gap: 0.25rem;
}
.image-resize-options input[type="number"] {
  box-sizing: border-box;
  width: 9rem;
}
.image-resize-options input[type="range"] {
  width: min(16rem, 65vw);
}
.image-resize-options .image-resize-check {
  display: flex;
  align-items: center;
  min-height: 2.2rem;
}
.image-resize-drop {
  display: grid;
  place-items: center;
  min-height: 8rem;
  padding: 1.5rem;
  text-align: center;
  border: 2px dashed color-mix(in srgb, currentColor 32%, transparent);
  border-radius: 0.6rem;
  background: color-mix(in srgb, currentColor 3%, transparent);
}
.image-resize-drop[data-dragging] {
  border-color: currentColor;
  background: color-mix(in srgb, currentColor 9%, transparent);
}
.image-resize-drop input {
  max-width: 100%;
}
.image-resize-status {
  min-height: 1.5rem;
  margin: 0;
  font-variant-numeric: tabular-nums;
}
.image-resize-list {
  display: grid;
  gap: 0.75rem;
  padding: 0;
  margin: 0;
  list-style: none;
}
.image-resize-row {
  display: grid;
  grid-template-columns: 5rem minmax(0, 1fr) auto;
  gap: 0.9rem;
  align-items: center;
  padding: 0.75rem;
  border: 1px solid color-mix(in srgb, currentColor 18%, transparent);
  border-radius: 0.45rem;
}
.image-resize-row img {
  display: block;
  width: 5rem;
  height: 5rem;
  object-fit: contain;
  background: repeating-conic-gradient(#ddd 0 25%, #fff 0 50%) 50% / 1rem 1rem;
}
.image-resize-row-name {
  overflow-wrap: anywhere;
}
.image-resize-row-meta {
  margin: 0.2rem 0 0;
  font-size: 0.9em;
  font-variant-numeric: tabular-nums;
}
@media (max-width: 40rem) {
  .image-resize-row {
    grid-template-columns: 4rem minmax(0, 1fr);
  }
  .image-resize-row img {
    width: 4rem;
    height: 4rem;
  }
  .image-resize-row-actions {
    grid-column: 1 / -1;
  }
}
</style>

<div class="image-resize-tool">
  <div class="image-resize-options">
    <label>Maximum width
      <input id="image-resize-width" type="number" min="1" max="8192" step="1" value="1600">
    </label>
    <label>Maximum height
      <input id="image-resize-height" type="number" min="1" max="8192" step="1" value="1600">
    </label>
    <label class="image-resize-check">
      <input id="image-resize-enlarge" type="checkbox"> Enlarge
    </label>
    <label>Output
      <select id="image-resize-format">
        <option value="webp-lossy" selected>WebP lossy</option>
        <option value="webp-lossless">WebP lossless</option>
        <option value="jpeg">JPEG</option>
        <option value="png">PNG</option>
      </select>
    </label>
    <label id="image-resize-quality-label">Quality: <output id="image-resize-quality-output">85</output>
      <input id="image-resize-quality" type="range" min="1" max="100" step="1" value="85">
    </label>
  </div>

  <label id="image-resize-drop" class="image-resize-drop">
    <span><strong>Drop images here</strong><br>or choose several files</span>
    <input id="image-resize-input" type="file" multiple
      accept="image/jpeg,image/png,image/webp,image/avif,.jpg,.jpeg,.png,.webp,.avif">
  </label>

  <div class="image-resize-toolbar">
    <button id="image-resize-clear" type="button" disabled>Clear list</button>
    <button id="image-resize-cancel" type="button" hidden>Cancel current resize</button>
  </div>
  <p id="image-resize-status" class="image-resize-status" role="status" aria-live="polite"></p>
  <ol id="image-resize-list" class="image-resize-list"></ol>
</div>

<script type="module">
const fileInput = document.getElementById("image-resize-input");
const dropZone = document.getElementById("image-resize-drop");
const widthInput = document.getElementById("image-resize-width");
const heightInput = document.getElementById("image-resize-height");
const enlargeInput = document.getElementById("image-resize-enlarge");
const formatInput = document.getElementById("image-resize-format");
const qualityInput = document.getElementById("image-resize-quality");
const qualityOutput = document.getElementById("image-resize-quality-output");
const qualityLabel = document.getElementById("image-resize-quality-label");
const clearButton = document.getElementById("image-resize-clear");
const cancelButton = document.getElementById("image-resize-cancel");
const status = document.getElementById("image-resize-status");
const list = document.getElementById("image-resize-list");

const records = new Map();
const pendingIds = [];
let nextId = 0;
let activeId = 0;
let worker = null;

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} bytes`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KiB`;
  return `${(bytes / (1024 * 1024)).toFixed(2)} MiB`;
}

function fileFormat(file) {
  if (file.type === "image/jpeg" || /\.jpe?g$/i.test(file.name)) return "jpeg";
  if (file.type === "image/png" || /\.png$/i.test(file.name)) return "png";
  if (file.type === "image/webp" || /\.webp$/i.test(file.name)) return "webp";
  if (file.type === "image/avif" || /\.avif$/i.test(file.name)) return "avif";
  return "";
}

function currentBounds() {
  const maxWidth = Number(widthInput.value);
  const maxHeight = Number(heightInput.value);
  if (!Number.isInteger(maxWidth) || !Number.isInteger(maxHeight) ||
      maxWidth < 1 || maxHeight < 1 || maxWidth > 8192 || maxHeight > 8192) {
    return null;
  }
  return { maxWidth, maxHeight };
}

function targetDimensions(width, height) {
  const bounds = currentBounds();
  if (bounds === null || width === 0 || height === 0) return null;
  const scale = Math.min(
    bounds.maxWidth / width,
    bounds.maxHeight / height,
    enlargeInput.checked ? Infinity : 1,
  );
  return {
    width: Math.max(1, Math.floor(width * scale)),
    height: Math.max(1, Math.floor(height * scale)),
  };
}

function updateRow(record) {
  const target = targetDimensions(record.width, record.height);
  const dimensions = record.width === 0
    ? "Dimensions will be checked during resize"
    : `${record.width}×${record.height} → ${target?.width ?? "?"}×${target?.height ?? "?"}`;
  record.meta.textContent = `${dimensions} · ${formatBytes(record.file.size)} · ${record.state}`;
}

function updateRows() {
  for (const record of records.values()) updateRow(record);
}

function settingsChanged() {
  for (const record of records.values()) {
    if (record.job === null && record.id !== activeId) record.state = "Ready";
  }
  updateRows();
}

function outputName(format) {
  return {
    jpeg: "JPEG",
    png: "PNG",
    "webp-lossless": "WebP lossless",
    "webp-lossy": "WebP lossy",
  }[format] ?? format;
}

function setIdleStatus() {
  if (activeId !== 0) return;
  if (records.size === 0) {
    status.textContent = "Add JPEG, PNG, WebP, or AVIF images.";
  } else {
    status.textContent = `${records.size} image${records.size === 1 ? "" : "s"} ready. Resizing starts when you download one.`;
  }
}

function updateControls() {
  clearButton.disabled = records.size === 0 || activeId !== 0;
  cancelButton.hidden = activeId === 0;
}

function removeRecord(id) {
  const record = records.get(id);
  if (!record || id === activeId) return;
  const pendingIndex = pendingIds.indexOf(id);
  if (pendingIndex !== -1) pendingIds.splice(pendingIndex, 1);
  URL.revokeObjectURL(record.previewURL);
  record.row.remove();
  records.delete(id);
  updateControls();
  setIdleStatus();
}

function addFile(file) {
  const format = fileFormat(file);
  if (format === "") {
    status.textContent = `${file.name} is not a supported JPEG, PNG, WebP, or AVIF image.`;
    return;
  }
  if (file.size > 64 * 1024 * 1024) {
    status.textContent = `${file.name} exceeds the 64 MiB compressed-input limit.`;
    return;
  }

  const id = ++nextId;
  const previewURL = URL.createObjectURL(file);
  const row = document.createElement("li");
  row.className = "image-resize-row";
  const preview = document.createElement("img");
  preview.src = previewURL;
  preview.alt = "";
  const details = document.createElement("div");
  const name = document.createElement("strong");
  name.className = "image-resize-row-name";
  name.textContent = file.name;
  const meta = document.createElement("p");
  meta.className = "image-resize-row-meta";
  details.append(name, meta);
  const actions = document.createElement("div");
  actions.className = "image-resize-row-actions";
  const download = document.createElement("button");
  download.type = "button";
  download.textContent = "Resize and download";
  const remove = document.createElement("button");
  remove.type = "button";
  remove.textContent = "Remove";
  actions.append(download, remove);
  row.append(preview, details, actions);
  list.append(row);

  const record = {
    id,
    file,
    format,
    previewURL,
    row,
    meta,
    download,
    remove,
    width: 0,
    height: 0,
    state: "Ready",
    job: null,
  };
  records.set(id, record);
  updateRow(record);

  preview.addEventListener("load", () => {
    record.width = preview.naturalWidth;
    record.height = preview.naturalHeight;
    updateRow(record);
  }, { once: true });
  preview.addEventListener("error", () => {
    preview.hidden = true;
    updateRow(record);
  }, { once: true });

  download.addEventListener("click", () => queueDownload(id));
  remove.addEventListener("click", () => removeRecord(id));
  updateControls();
  setIdleStatus();
}

function addFiles(files) {
  for (const file of files) addFile(file);
  fileInput.value = "";
}

function ensureWorker() {
  if (worker !== null) return worker;
  worker = new Worker("/image-resize-worker.js", { type: "module" });
  worker.addEventListener("message", finishJob);
  worker.addEventListener("error", (event) => {
    const record = records.get(activeId);
    if (record) {
      record.job = null;
      record.state = "Failed";
      record.download.disabled = false;
      record.remove.disabled = false;
      updateRow(record);
    }
    status.textContent = event.message || "The resize worker failed.";
    worker?.terminate();
    worker = null;
    activeId = 0;
    updateControls();
    startNext();
  });
  return worker;
}

function queueDownload(id) {
  const record = records.get(id);
  const bounds = currentBounds();
  if (!record || record.job !== null) return;
  if (bounds === null) {
    status.textContent = "Maximum width and height must be integers from 1 through 8192.";
    return;
  }
  record.job = {
    ...bounds,
    enlarge: enlargeInput.checked,
    outputFormat: formatInput.value,
    quality: Number(qualityInput.value),
  };
  record.state = activeId === 0 ? "Starting…" : "Queued";
  record.download.disabled = true;
  record.remove.disabled = true;
  pendingIds.push(id);
  updateRow(record);
  startNext();
}

async function startNext() {
  if (activeId !== 0) return;
  const id = pendingIds.shift();
  if (id === undefined) {
    updateControls();
    return;
  }
  const record = records.get(id);
  if (!record || record.job === null) {
    startNext();
    return;
  }
  activeId = id;
  record.state = "Decoding and resizing…";
  updateRow(record);
  updateControls();
  status.textContent = `Processing ${record.file.name}…`;
  try {
    const input = await record.file.arrayBuffer();
    ensureWorker().postMessage({
      id,
      format: record.format,
      input,
      ...record.job,
    }, [input]);
  } catch (error) {
    finishJob({ data: {
      type: "error",
      id,
      message: error instanceof Error ? error.message : String(error),
    } });
  }
}

function finishJob(event) {
  const data = event.data;
  if (data.id !== activeId) return;
  const record = records.get(data.id);
  activeId = 0;
  if (!record) {
    updateControls();
    startNext();
    return;
  }
  const completedJob = record.job;
  record.job = null;
  record.download.disabled = false;
  record.remove.disabled = false;
  if (data.type === "error") {
    record.state = "Failed";
    status.textContent = `${record.file.name}: ${data.message}`;
  } else {
    const output = new Uint8Array(data.output);
    const outputURL = URL.createObjectURL(new Blob([output], { type: data.contentType }));
    const link = document.createElement("a");
    link.href = outputURL;
    const base = record.file.name.replace(/\.[^.]+$/, "");
    link.download = `${base}-${data.width}x${data.height}.${data.extension}`;
    link.click();
    setTimeout(() => URL.revokeObjectURL(outputURL), 10_000);
    record.state = `${outputName(completedJob?.outputFormat)} · ${formatBytes(output.byteLength)} · ${data.algorithm}`;
    status.textContent =
      `${record.file.name}: ${data.sourceWidth}×${data.sourceHeight} → ` +
      `${data.width}×${data.height} in ${(data.elapsedMs / 1000).toFixed(2)} s.`;
  }
  updateRow(record);
  updateControls();
  startNext();
}

fileInput.addEventListener("change", () => addFiles(fileInput.files ?? []));
for (const eventName of ["dragenter", "dragover"]) {
  dropZone.addEventListener(eventName, (event) => {
    event.preventDefault();
    dropZone.dataset.dragging = "";
  });
}
for (const eventName of ["dragleave", "drop"]) {
  dropZone.addEventListener(eventName, (event) => {
    event.preventDefault();
    delete dropZone.dataset.dragging;
  });
}
dropZone.addEventListener("drop", (event) => addFiles(event.dataTransfer?.files ?? []));

for (const input of [widthInput, heightInput, enlargeInput]) {
  input.addEventListener("input", settingsChanged);
}
qualityInput.addEventListener("input", () => {
  qualityOutput.value = qualityInput.value;
  settingsChanged();
});
formatInput.addEventListener("change", () => {
  const lossy = formatInput.value === "webp-lossy" || formatInput.value === "jpeg";
  qualityLabel.hidden = !lossy;
  settingsChanged();
});
clearButton.addEventListener("click", () => {
  for (const id of Array.from(records.keys())) removeRecord(id);
});
cancelButton.addEventListener("click", () => {
  const record = records.get(activeId);
  worker?.terminate();
  worker = null;
  activeId = 0;
  if (record) {
    record.job = null;
    record.state = "Cancelled";
    record.download.disabled = false;
    record.remove.disabled = false;
    updateRow(record);
  }
  status.textContent = "Resize cancelled.";
  updateControls();
  startNext();
});
addEventListener("beforeunload", () => {
  worker?.terminate();
  for (const record of records.values()) URL.revokeObjectURL(record.previewURL);
});

setIdleStatus();
</script>

## Processing

The maximum dimensions define a box. Every output preserves the source aspect
ratio and fits inside that box. **Enlarge** is off by default, so an image that
already fits is not enlarged. When enlargement is enabled, Mitchell-Netravali
reconstruction scales smaller images up to fit. Lanczos3 handles reductions.

The page chooses the decoder from the selected file type and chooses the
resizer after reading the decoded dimensions. This is direct dispatch in
JavaScript; the page does not use `<qip-step>` fallback. The decoded image,
resizer input and output, and encoder input use canonical RGBA8 sRGB KTX2.

WebP lossy and JPEG show a quality slider. WebP lossless and PNG do not,
because their pixel output is lossless. JPEG cannot store transparency, so its
component composites transparent pixels against white. Quality numbers are
specific to each codec; JPEG quality 85 and WebP quality 85 do not promise the
same visual result.

Processing is sequential to bound peak memory. The worker caches compiled Wasm
modules, but each operation creates fresh component instances. Changing the
maximum dimensions or output settings does not process or retain output
images. Each row uses the settings in effect when **Resize and download** is
pressed.

The components limit images to 8192 pixels per edge and 25 megapixels. A
compressed input must be no larger than 64 MiB. This tool creates new pixels
and does not preserve indexed palettes, animation, or source metadata.

## Use the resize components directly

Set both dimensions explicitly:

```sh
./qip run -i input.ktx2 -o thumbnail.ktx2 \
  components/image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3.wasm \
  -u width=1200 -u height=800
```

Omit one dimension to preserve the source aspect ratio. Omit both to halve with
Lanczos3 or double with Mitchell. Each component accepts and emits canonical
RGBA8 sRGB `image/ktx2`, is limited to 8192 pixels per axis and 25 megapixels,
and reserves 287.4 MiB of fixed Wasm memory.

The filters decode sRGB to linear light and premultiply alpha before sampling.
They return straight-alpha sRGB bytes. Lanczos3 preserves detail well during
reduction, but can ring around sharp high-contrast edges.
