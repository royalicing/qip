import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const BOARD_X = 18;
const BOARD_Y = 18;
const CELL_PX = 56;
const NUMBER_PAD_X = 562;
const NUMBER_PAD_Y = 142;
const CLEAR_X = 562;
const NEW_X = 658;
const ACTION_Y = 342;

async function makeGame() {
  const moduleBytes = await readFile("modules/interactive/sudoku.wasm");
  const { instance } = await WebAssembly.instantiate(moduleBytes, {});
  return instance.exports;
}

function press(exportsObj, x, y) {
  const changed = exportsObj.pointer_event(1, x, y, 0n);
  exportsObj.pointer_event(0, x, y, 0n);
  return changed;
}

function renderCopy(exportsObj) {
  const outputLen = exportsObj.render(0);
  return new Uint8Array(
    new Uint8Array(exportsObj.memory.buffer, exportsObj.output_ptr(), outputLen),
  );
}

function countColorInCell(bytes, renderWidth, idx, color) {
  const cellX = BOARD_X + (idx % 9) * CELL_PX;
  const cellY = BOARD_Y + Math.floor(idx / 9) * CELL_PX;
  let count = 0;
  for (let y = cellY + 2; y < cellY + CELL_PX - 2; y++) {
    for (let x = cellX + 2; x < cellX + CELL_PX - 2; x++) {
      const off = (y * renderWidth + x) * 4;
      if (
        bytes[off] === color[0] &&
        bytes[off + 1] === color[1] &&
        bytes[off + 2] === color[2] &&
        bytes[off + 3] === color[3]
      ) {
        count++;
      }
    }
  }
  return count;
}

function findCellWithColor(bytes, renderWidth, color, minimumPixels) {
  for (let idx = 0; idx < 81; idx++) {
    if (countColorInCell(bytes, renderWidth, idx, color) >= minimumPixels) {
      return idx;
    }
  }
  return -1;
}

function hashBytes(bytes) {
  let hash = 2166136261;
  for (const byte of bytes) {
    hash ^= byte;
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}

test("sudoku exposes a wide pointer-operated number pad", async () => {
  const game = await makeGame();
  assert.equal(game.render_width_px(), 780);
  assert.equal(game.render_height_px(), 540);
  const initialFrame = renderCopy(game);
  const editableIdx = findCellWithColor(
    initialFrame,
    780,
    [242, 201, 76, 255],
    2000,
  );
  assert.notEqual(editableIdx, -1, "expected at least one editable cell");

  let frame = null;
  let readableDigitPixels = 0;
  for (let digit = 1; digit <= 9; digit++) {
    const col = (digit - 1) % 3;
    const row = Math.floor((digit - 1) / 3);
    press(
      game,
      NUMBER_PAD_X + col * 64 + 28,
      NUMBER_PAD_Y + row * 64 + 28,
    );
    frame = renderCopy(game);
    readableDigitPixels = countColorInCell(
      frame,
      780,
      editableIdx,
      [15, 15, 14, 255],
    );
    if (readableDigitPixels > 0) break;
  }
  assert.ok(
    readableDigitPixels > 0,
    "number-pad input should draw a dark digit on the selected yellow cell",
  );

  assert.equal(press(game, CLEAR_X + 44, ACTION_Y + 28), 1);
  frame = renderCopy(game);
  assert.equal(countColorInCell(frame, 780, editableIdx, [15, 15, 14, 255]), 0);
});

test("sudoku puzzle givens cannot be selected", async () => {
  const game = await makeGame();
  const before = renderCopy(game);
  const givenIdx = findCellWithColor(before, 780, [255, 255, 255, 255], 1);
  assert.notEqual(givenIdx, -1, "expected at least one puzzle given");

  const x = BOARD_X + (givenIdx % 9) * CELL_PX + Math.floor(CELL_PX / 2);
  const y = BOARD_Y + Math.floor(givenIdx / 9) * CELL_PX + Math.floor(CELL_PX / 2);
  assert.equal(press(game, x, y), 0);

  const after = renderCopy(game);
  assert.equal(hashBytes(after), hashBytes(before));
});

test("sudoku can generate a new puzzle from the pointer controls", async () => {
  const game = await makeGame();
  const before = renderCopy(game);

  assert.equal(press(game, NEW_X + 44, ACTION_Y + 28), 1);
  const after = renderCopy(game);

  assert.notEqual(hashBytes(after), hashBytes(before));
});
