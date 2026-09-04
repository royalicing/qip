const KTX2_RGBA8_SRGB = "ktx2-r8g8b8a8-srgb";
const KTX2_BGRA8_SRGB = "ktx2-b8g8r8a8-srgb";
const KTX2_RGBA32FLOAT_BT709_LINEAR = "ktx2-rgba32float-bt709-linear";
const KTX2_RGBA32FLOAT_DISPLAY_P3_LINEAR = "ktx2-rgba32float-display-p3-linear";
const KTX2_RGBA32FLOAT_DISPLAY_P3 = "ktx2-rgba32float-display-p3";

const MAX_RECIPES = 512;

export const PREFERENCES = new Set(["balanced", "quality", "smallest", "fastest"]);

export function encodingAccepted(actual, expected) {
  return actual === expected || (actual === "utf8" && expected === "bytes");
}

export function outputRole(mime) {
  if (mime === "image/ktx2") return "working";
  return "deliverable";
}

function inputProfiles(component) {
  if (component.inputMime !== "image/ktx2") return [null];
  const { path } = component;
  if (path.includes("r8g8b8a8-or-b8g8r8a8-srgb")) {
    return [KTX2_RGBA8_SRGB, KTX2_BGRA8_SRGB];
  }
  if (path.includes("r8g8b8a8-srgb")) return [KTX2_RGBA8_SRGB];
  if (path.includes("b8g8r8a8-srgb")) return [KTX2_BGRA8_SRGB];
  if (path.includes("rgba32float-display-p3-linear")) {
    return [KTX2_RGBA32FLOAT_DISPLAY_P3_LINEAR];
  }
  if (path.includes("rgba32float-display-p3")) {
    return [KTX2_RGBA32FLOAT_DISPLAY_P3];
  }
  if (path.includes("rgba32float")) return [KTX2_RGBA32FLOAT_BT709_LINEAR];
  return [];
}

function outputProfile(component) {
  if (component.outputMime !== "image/ktx2") return null;
  const { path } = component;
  if (path.includes("rgba32float-display-p3-linear")) {
    return KTX2_RGBA32FLOAT_DISPLAY_P3_LINEAR;
  }
  if (path.includes("rgba32float-display-p3")) return KTX2_RGBA32FLOAT_DISPLAY_P3;
  if (path.includes("rgba32float")) return KTX2_RGBA32FLOAT_BT709_LINEAR;
  if (path.includes("r8g8b8a8-srgb")) return KTX2_RGBA8_SRGB;
  if (path.includes("b8g8r8a8-srgb")) return KTX2_BGRA8_SRGB;
  return null;
}

function initialProfile(mime) {
  // The finder has no file inspector. Treat a user-selected KTX2 source as
  // QIP's documented canonical profile rather than connecting it to every
  // component that happens to use image/ktx2.
  return mime === "image/ktx2" ? KTX2_RGBA8_SRGB : null;
}

function stateKey(state) {
  return `${state.mime}\0${state.encoding}\0${state.profile ?? ""}`;
}

function accepts(component, state) {
  if (component.inputMime !== state.mime) return false;
  if (state.encoding !== null && !encodingAccepted(state.encoding, component.inputEncoding)) return false;
  const profiles = inputProfiles(component);
  return profiles.includes(state.profile);
}

function nextState(component) {
  return {
    mime: component.outputMime,
    encoding: component.outputEncoding,
    profile: outputProfile(component),
  };
}

function countLossy(recipe) {
  return recipe.filter((component) => component.path.includes("-lossy")).length;
}

function countLossless(recipe) {
  return recipe.filter((component) => component.path.includes("-lossless")).length;
}

function intermediatePenalty(recipe) {
  let penalty = 0;
  for (const component of recipe.slice(0, -1)) {
    if (component.outputMime === "image/ktx2") {
      // Canonical RGBA8 KTX2 is the preferred QIP image bridge. Float profiles
      // stay valid, but are more specialised working representations.
      penalty += outputProfile(component) === KTX2_RGBA8_SRGB ? 0 : 1;
    } else if (component.outputMime === "image/bmp") {
      penalty += 2;
    }
  }
  return penalty;
}

function scalarPenalty(recipe) {
  return recipe.filter((component) =>
    component.path.includes("rasterize") && !component.path.includes("-simd"),
  ).length;
}

function compareNumbers(left, right) {
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) return left[index] - right[index];
  }
  return 0;
}

function score(recipe, preference) {
  const lossiness = countLossy(recipe);
  const losslessness = countLossless(recipe);
  const bridge = intermediatePenalty(recipe);
  const scalar = scalarPenalty(recipe);
  switch (preference) {
    case "quality":
      return [lossiness, bridge, recipe.length, scalar];
    case "smallest":
      return [losslessness, recipe.length, bridge, scalar];
    case "fastest":
      return [recipe.length, scalar, bridge, lossiness];
    default:
      return [lossiness, recipe.length, bridge, scalar];
  }
}

/**
 * Finds executable, non-cyclic format-conversion pipelines. A graph node has
 * an encoding, MIME type, and optional KTX2 profile; MIME alone is not enough
 * to connect QIP image components safely.
 */
export function findRecipes(catalog, inputMime, outputMime) {
  if (inputMime === outputMime) return [[]];

  const recipes = [];
  const start = {
    mime: inputMime,
    encoding: null,
    profile: initialProfile(inputMime),
  };

  function visit(state, steps, visited) {
    if (recipes.length >= MAX_RECIPES) return;
    for (const component of catalog) {
      if (!accepts(component, state)) continue;
      const next = nextState(component);
      const nextKey = stateKey(next);
      if (visited.has(nextKey)) continue;

      const nextSteps = [...steps, component];
      if (next.mime === outputMime) {
        recipes.push(nextSteps);
        continue;
      }

      const nextVisited = new Set(visited);
      nextVisited.add(nextKey);
      visit(next, nextSteps, nextVisited);
    }
  }

  visit(start, [], new Set([stateKey(start)]));
  return recipes;
}

export function reachableOutputMimes(catalog, inputMime) {
  const mimes = new Set(catalog.flatMap((component) => [component.inputMime, component.outputMime]));
  const reachable = new Set([inputMime]);
  for (const mime of mimes) {
    if (mime !== inputMime && findRecipes(catalog, inputMime, mime).length > 0) {
      reachable.add(mime);
    }
  }
  return reachable;
}

export function rankRecipes(recipes, preference = "balanced") {
  if (!PREFERENCES.has(preference)) throw new RangeError(`Unknown recipe preference: ${preference}`);
  return [...recipes].sort((left, right) => {
    const result = compareNumbers(score(left, preference), score(right, preference));
    if (result !== 0) return result;
    return left.map((component) => component.path).join("\n").localeCompare(
      right.map((component) => component.path).join("\n"),
    );
  });
}

export function findRankedRecipes(catalog, inputMime, outputMime, preference = "balanced") {
  return rankRecipes(findRecipes(catalog, inputMime, outputMime), preference);
}
