import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { access, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileP = promisify(execFile);

const qip = fileURLToPath(new URL("../qip", import.meta.url));
const strictProfile = fileURLToPath(
  new URL("../components/application/wasm/wasm-strict-profile.wasm", import.meta.url),
);
const readInputContentType = fileURLToPath(
  new URL("../components/application/wasm/wasm-read-input-content-type.wasm", import.meta.url),
);
const componentsDir = fileURLToPath(new URL("../components", import.meta.url));
const boundedLoops = fileURLToPath(
  new URL("../components/application/wasm/wasm-bounded-loops.wasm", import.meta.url),
);
const core10Validator = fileURLToPath(
  new URL("../components/application/wasm/wasm-validate-core-1.0.wasm", import.meta.url),
);
const luhn = fileURLToPath(new URL("../components/utf8/luhn.wasm", import.meta.url));
const infiniteLoop = fileURLToPath(new URL("../components/utf8/infinite-loop.wasm", import.meta.url));
const helloNaive = fileURLToPath(new URL("../components/utf8/hello-naive.wasm", import.meta.url));

async function ensurePrerequisites(t) {
  try {
    await access(qip, constants.X_OK);
    await access(strictProfile, constants.R_OK);
    await access(readInputContentType, constants.R_OK);
    await access(boundedLoops, constants.R_OK);
    await access(core10Validator, constants.R_OK);
    await access(luhn, constants.R_OK);
    await access(infiniteLoop, constants.R_OK);
    await access(helloNaive, constants.R_OK);
  } catch {
    t.skip("build ./qip and components first");
  }
}

test("Core 1.0 validator agrees with WebAssembly.validate and recovers after a trap", async (t) => {
  await ensurePrerequisites(t);

  const valid = await readFile(helloNaive);
  const invalid = Buffer.from(
    "0061736d0100000001070160027f7e017f030201000a09010700200020016a0b",
    "hex",
  );
  assert.equal(WebAssembly.validate(valid), true);
  assert.equal(WebAssembly.validate(invalid), false);

  const validatorBytes = await readFile(core10Validator);
  const instance = await WebAssembly.instantiate(validatorBytes);
  const wasm = instance.instance.exports;
  const validate = (bytes) => {
    new Uint8Array(wasm.memory.buffer, wasm.input_ptr(), bytes.length).set(bytes);
    try {
      return wasm.render(bytes.length) === bytes.length;
    } catch {
      return false;
    }
  };

  assert.equal(validate(invalid), WebAssembly.validate(invalid));
  assert.equal(validate(valid), WebAssembly.validate(valid));

  const result = await runQip(["run", "-i", helloNaive, "--", core10Validator]);
  assert.equal(result.code, 0, result.stderr.toString("utf8"));
  assert.deepEqual(result.stdout, valid);
});

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
