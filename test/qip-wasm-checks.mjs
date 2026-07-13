import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { access } from "node:fs/promises";
import { constants } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileP = promisify(execFile);

const qip = fileURLToPath(new URL("../qip", import.meta.url));
const strictProfile = fileURLToPath(
  new URL("../modules/application/wasm/wasm-strict-profile.wasm", import.meta.url),
);
const boundedLoops = fileURLToPath(
  new URL("../modules/application/wasm/wasm-bounded-loops.wasm", import.meta.url),
);
const luhn = fileURLToPath(new URL("../modules/utf8/luhn.wasm", import.meta.url));
const infiniteLoop = fileURLToPath(new URL("../modules/utf8/infinite-loop.wasm", import.meta.url));

async function ensurePrerequisites(t) {
  try {
    await access(qip, constants.X_OK);
    await access(strictProfile, constants.R_OK);
    await access(boundedLoops, constants.R_OK);
    await access(luhn, constants.R_OK);
    await access(infiniteLoop, constants.R_OK);
  } catch {
    t.skip("build ./qip and modules first");
  }
}

async function runQip(args) {
  try {
    const { stdout, stderr } = await execFileP(qip, args, {
      encoding: "buffer",
      maxBuffer: 1024 * 1024,
    });
    return { code: 0, stdout, stderr };
  } catch (err) {
    if (err && Object.hasOwn(err, "stdout") && Object.hasOwn(err, "stderr")) {
      return {
        code: typeof err.code === "number" ? err.code : 1,
        stdout: err.stdout ?? Buffer.alloc(0),
        stderr: err.stderr ?? Buffer.alloc(0),
      };
    }
    throw err;
  }
}

test("strict tier pipeline accepts fixed-bound luhn loops", async (t) => {
  await ensurePrerequisites(t);

  const result = await runQip(["run", "-i", luhn, "--", strictProfile, boundedLoops]);
  assert.equal(result.code, 0, result.stderr.toString("utf8"));
  assert.equal(result.stdout.length > 0, true);
});

test("strict profile alone accepts an unbounded loop", async (t) => {
  await ensurePrerequisites(t);

  // Loop bounds are wasm-bounded-loops' job: the profile stage checks the
  // factual rules only.
  const result = await runQip(["run", "-i", infiniteLoop, "--", strictProfile]);
  assert.equal(result.code, 0, result.stderr.toString("utf8"));
  assert.equal(result.stdout.length > 0, true);
});

test("bounded loops stage rejects an unbounded loop", async (t) => {
  await ensurePrerequisites(t);

  const result = await runQip(["run", "-i", infiniteLoop, "--", boundedLoops]);
  assert.notEqual(result.code, 0);
  assert.match(result.stderr.toString("utf8"), /wasm error: unreachable/);
});

test("qip score reports fixed-bound loop warnings", async (t) => {
  await ensurePrerequisites(t);

  const result = await runQip(["score", infiniteLoop]);
  assert.equal(result.code, 0, result.stderr.toString("utf8"));
  const stdout = result.stdout.toString("utf8");
  assert.match(stdout, /WARN\(loop-bound\)/);
  assert.match(stdout, /fixed_bound_loops: WARN/);
});
