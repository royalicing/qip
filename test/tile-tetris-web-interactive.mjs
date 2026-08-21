import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const wasm = Object.fromEntries(
  await Promise.all(
    ["tile-world-12x12", "tetris", "web-mechanics"].map(async (name) => [
      name,
      await readFile(`components/interactive/${name}.wasm`),
    ]),
  ),
);

function instantiate(bytes) {
  return new WebAssembly.Instance(new WebAssembly.Module(bytes), {}).exports;
}

function digest(exports, size) {
  const bytes = new Uint8Array(exports.memory.buffer, exports.output_ptr(), size);
  return createHash("sha256").update(bytes).digest("hex");
}

function assertABI(exports) {
  for (const legacy of ["tick", "render_width_px", "render_height_px", "output_rgba8_srgb_bytes"]) {
    assert.equal(exports[legacy], undefined);
  }
  assert.equal(exports.input_bytes_cap(), 0);
  assert.equal(exports.key_event.length, 2);
  assert.equal(exports.pointer_event.length, 3);
  const type = new TextDecoder("utf-8", { fatal: true }).decode(
    new Uint8Array(exports.memory.buffer, exports.output_content_type_ptr(), exports.output_content_type_size()),
  );
  assert.equal(type, "image/ktx2");
}

test("tile world retains movement and bounds a maximum-time catch-up", () => {
  const world = instantiate(wasm["tile-world-12x12"]);
  assertABI(world);
  const size = world.render(0);
  assert.equal(size, 224 + 288 * 288 * 4);
  assert.equal(world.begin_at, undefined);
  assert.equal(world.commit, undefined);
  const initial = digest(world, size);

  world.begin_update_at(1n);
  assert.equal(world.pointer_event(1, 12, 5 * 24 + 12), 1);
  assert.equal(world.key_event(0xff53, 1), 1);
  assert.equal(world.finish_update(), 121n);
  assert.equal(digest(world, size), initial);

  world.begin_update_at(121n);
  assert.equal(world.finish_update(), 241n);
  assert.equal(world.render(0), size);
  assert.notEqual(digest(world, size), initial);

  world.begin_update_at(0x7fff_ffff_ffff_ffffn);
  assert.equal(world.finish_update(), 0x7fff_ffff_ffff_ffffn);
});

test("tetris pause updates separately from presentation", () => {
  const tetris = instantiate(wasm.tetris);
  assertABI(tetris);
  const size = tetris.render(0);
  assert.equal(size, 224 + 262 * 304 * 4);
  assert.equal(tetris.begin_at, undefined);
  assert.equal(tetris.commit, undefined);
  const initial = digest(tetris, size);

  tetris.begin_update_at(1n);
  assert.equal(tetris.key_event("P".codePointAt(0), 1), 1);
  assert.equal(tetris.finish_update(), 1n);
  assert.equal(digest(tetris, size), initial);

  assert.equal(tetris.render(0), size);
  assert.notEqual(digest(tetris, size), initial);

  const longJump = instantiate(wasm.tetris);
  longJump.render(0);
  longJump.begin_update_at(1n);
  assert.equal(longJump.finish_update(), 520n);
  longJump.begin_update_at(0x7fff_ffff_ffff_ffffn);
  assert.equal(longJump.finish_update(), 0x7fff_ffff_ffff_ffffn);
});

test("web mechanics publishes a selected topic only when rendered", () => {
  const web = instantiate(wasm["web-mechanics"]);
  assertABI(web);
  const size = web.render(0);
  assert.equal(size, 224 + 640 * 420 * 4);
  assert.equal(web.begin_at, undefined);
  assert.equal(web.commit, undefined);
  const initial = digest(web, size);

  web.begin_update_at(1n);
  assert.equal(web.pointer_event(1, 120, 60), 1);
  assert.equal(web.pointer_event(0, 120, 60), 1);
  assert.equal(web.finish_update(), 1n);
  assert.equal(digest(web, size), initial);

  assert.equal(web.render(0), size);
  assert.notEqual(digest(web, size), initial);
});

test("all three components trap on lifecycle misuse", () => {
  for (const bytes of Object.values(wasm)) {
    const exports = instantiate(bytes);
    assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
    exports.render(0);
    assert.throws(() => exports.finish_update(), WebAssembly.RuntimeError);
    exports.begin_update_at(1n);
    assert.throws(() => exports.render(0), WebAssembly.RuntimeError);
    exports.finish_update();
    assert.throws(() => exports.begin_update_at(1n), WebAssembly.RuntimeError);
  }
});
