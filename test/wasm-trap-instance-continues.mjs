import assert from "node:assert/strict";
import test from "node:test";

const wasmBytes = Uint8Array.from(
  Buffer.from(
    "AGFzbQEAAAABCAJgAAF/YAAAAwUEAAABAQYGAX8BQQALByUEA2luYwAAA2dldAABBHRyYXAAAg50cmFwX2FmdGVyX2luYwADCiEECwAjAEEBaiQAIwALBAAjAAsDAAALCgAjAEEBaiQAAAs=",
    "base64",
  ),
);

test("a WebAssembly.Instance can continue after an exported function traps", async () => {
  const { instance } = await WebAssembly.instantiate(wasmBytes);
  const { get, inc, trap, trap_after_inc } = instance.exports;

  assert.equal(inc(), 1);

  assert.throws(() => trap(), WebAssembly.RuntimeError);
  assert.equal(get(), 1);
  assert.equal(inc(), 2);

  assert.throws(() => trap_after_inc(), WebAssembly.RuntimeError);
  assert.equal(get(), 3, "state mutated before a trap is not rolled back");
  assert.equal(inc(), 4);
});
