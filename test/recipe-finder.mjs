import assert from "node:assert/strict";
import test from "node:test";
import { findRankedRecipes } from "../site/_elements/lib/recipe-finder.js";

function component(path, inputMime, outputMime, inputEncoding = "bytes", outputEncoding = "bytes") {
  return { path, inputMime, outputMime, inputEncoding, outputEncoding };
}

test("recipe finder keeps incompatible KTX2 profiles apart", () => {
  const catalog = [
    component("/svg-to-ktx2-rgba32float-bt709-linear.wasm", "image/svg+xml", "image/ktx2", "utf8"),
    component("/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm", "image/ktx2", "image/webp"),
    component("/svg-to-ktx2-r8g8b8a8-srgb.wasm", "image/svg+xml", "image/ktx2", "utf8"),
  ];

  const recipes = findRankedRecipes(catalog, "image/svg+xml", "image/webp");
  assert.deepEqual(recipes.map((recipe) => recipe.map((step) => step.path)), [[
    "/svg-to-ktx2-r8g8b8a8-srgb.wasm",
    "/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm",
  ]]);
});

test("recipe finder ranks canonical KTX2 bridges before BMP bridges", () => {
  const catalog = [
    component("/svg-to-bmp.wasm", "image/svg+xml", "image/bmp", "utf8"),
    component("/bmp-to-webp-lossless.wasm", "image/bmp", "image/webp"),
    component("/svg-to-ktx2-r8g8b8a8-srgb.wasm", "image/svg+xml", "image/ktx2", "utf8"),
    component("/ktx2-r8g8b8a8-srgb-to-webp-lossless.wasm", "image/ktx2", "image/webp"),
  ];

  const recipes = findRankedRecipes(catalog, "image/svg+xml", "image/webp", "balanced");
  assert.deepEqual(recipes[0].map((step) => step.path), [
    "/svg-to-ktx2-r8g8b8a8-srgb.wasm",
    "/ktx2-r8g8b8a8-srgb-to-webp-lossless.wasm",
  ]);
});

test("quality keeps lossless recipes ahead while smallest prefers lossy output", () => {
  const catalog = [
    component("/bmp-to-webp-lossless.wasm", "image/bmp", "image/webp"),
    component("/bmp-to-webp-lossy.wasm", "image/bmp", "image/webp"),
  ];

  assert.equal(
    findRankedRecipes(catalog, "image/bmp", "image/webp", "quality")[0][0].path,
    "/bmp-to-webp-lossless.wasm",
  );
  assert.equal(
    findRankedRecipes(catalog, "image/bmp", "image/webp", "smallest")[0][0].path,
    "/bmp-to-webp-lossy.wasm",
  );
});
