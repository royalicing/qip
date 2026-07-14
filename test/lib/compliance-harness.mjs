// Shared host harness for Content Compliance components.
//
// This is the JS reference for the future `qip comply` bridge. It provides
// the qip.* imports, enforces the wire protocol on every run (sequential u64
// ordinals, examination open/continue/close discipline — violations throw at
// the exact offending call), and registers the *generic* meta-contract tests
// every Compliance component must satisfy: deterministic declarations and
// seed behavior. Per-component harnesses should only add component-specific
// checks (curated-case spot checks, duels against real implementations).
// Eventually the generic layer belongs in `qip comply` base validation, the
// way static contract checks already work for render components.
import assert from "node:assert/strict";

// Drives the component with a given impl function (bytes -> bytes, or null
// to echo input as a null impl). Records equality cases (the extractable
// corpus) and examination verdicts separately.
export async function runComplianceComponent(wasmBytes, { seed, impl } = {}) {
  const cases = [];
  const predicates = [];
  let memory;
  const view = (ptr, len) => new Uint8Array(memory.buffer, ptr, len);
  const bytes = (ptr, len) => Buffer.from(view(ptr, len));
  const applyImpl = (input) => (impl ? impl(input) : input);
  let hostOrdinal = 0n;
  let openExamination = null;
  const checkOrdinal = (declared) => {
    assert.equal(declared, hostOrdinal, "component and host disagree on case ordinal");
    hostOrdinal++;
  };
  const closeExamination = (declaredOrdinal, ok) => {
    assert.equal(openExamination, declaredOrdinal, "verdict must close the open examination");
    openExamination = null;
    checkOrdinal(declaredOrdinal);
    predicates.push({ ordinal: Number(declaredOrdinal), ok });
    return 1;
  };
  const { instance } = await WebAssembly.instantiate(wasmBytes, {
    qip: {
      render_must_equal(declaredOrdinal, inputPtr, inputLen, expectedPtr, expectedLen) {
        assert.equal(openExamination, null, "requirement declared inside an open examination");
        checkOrdinal(declaredOrdinal);
        cases.push({
          ordinal: Number(declaredOrdinal),
          input: bytes(inputPtr, inputLen),
          expected: bytes(expectedPtr, expectedLen),
        });
        return 1;
      },
      render_must_trap(declaredOrdinal, inputPtr, inputLen) {
        assert.equal(openExamination, null, "requirement declared inside an open examination");
        checkOrdinal(declaredOrdinal);
        cases.push({
          ordinal: Number(declaredOrdinal),
          input: bytes(inputPtr, inputLen),
          expected: null, // must trap
        });
        return 1;
      },
      render_examine(declaredOrdinal, inputPtr, inputLen, outPtr, outCap) {
        if (openExamination === null) {
          assert.equal(declaredOrdinal, hostOrdinal, "render_examine should open the pending case");
          openExamination = declaredOrdinal;
        } else {
          assert.equal(declaredOrdinal, openExamination, "render_examine ordinal changed mid-case");
        }
        const output = applyImpl(bytes(inputPtr, inputLen));
        if (output === null) return -1;
        if (output.length > outCap) return -2;
        view(outPtr, output.length).set(output);
        return output.length;
      },
      render_examine_pass(declaredOrdinal) {
        return closeExamination(declaredOrdinal, true);
      },
      render_examine_fail(declaredOrdinal) {
        return closeExamination(declaredOrdinal, false);
      },
    },
  });
  memory = instance.exports.memory;
  if (seed !== undefined) {
    instance.exports.uniform_set_seed(seed);
  }
  const declared = instance.exports.comply();
  assert.equal(openExamination, null, "comply() returned with an unclosed examination");
  return { cases, predicates, declared };
}

function assertSameDeclarations(a, b) {
  assert.equal(a.cases.length, b.cases.length);
  assert.equal(a.predicates.length, b.predicates.length);
  for (let i = 0; i < a.cases.length; i++) {
    assert.deepEqual(a.cases[i].input, b.cases[i].input, `case ${a.cases[i].ordinal} input`);
    assert.deepEqual(a.cases[i].expected, b.cases[i].expected, `case ${a.cases[i].ordinal} expected`);
  }
}

// The meta-contract every Content Compliance component must satisfy.
// `curatedCount` = declarations that must not vary with the seed;
// set `expectSeedVariation: false` for components with no fuzz phase.
export function registerGenericComplianceTests(
  test,
  wasmBytes,
  { seedVariant = 42, curatedCount = 0, expectSeedVariation = true } = {},
) {
  test("generic: declares at least one case and counts them correctly", async () => {
    const { cases, predicates, declared } = await runComplianceComponent(wasmBytes);
    assert.ok(cases.length + predicates.length > 0);
    assert.equal(declared, cases.length + predicates.length);
  });

  test("generic: declarations are deterministic — same component, same bytes, every run", async () => {
    assertSameDeclarations(
      await runComplianceComponent(wasmBytes),
      await runComplianceComponent(wasmBytes),
    );
  });

  test("generic: a reseeded corpus is itself deterministic", async () => {
    assertSameDeclarations(
      await runComplianceComponent(wasmBytes, { seed: seedVariant }),
      await runComplianceComponent(wasmBytes, { seed: seedVariant }),
    );
  });

  if (expectSeedVariation) {
    test("generic: seed varies the fuzz corpus but not the curated cases", async () => {
      const base = await runComplianceComponent(wasmBytes);
      const reseeded = await runComplianceComponent(wasmBytes, { seed: seedVariant });
      assert.equal(base.cases.length, reseeded.cases.length);
      for (let i = 0; i < curatedCount; i++) {
        assert.deepEqual(reseeded.cases[i].input, base.cases[i].input, `curated ${i}`);
      }
      const fuzzDiffers = base.cases.some(
        (c, i) => i >= curatedCount && !c.input.equals(reseeded.cases[i].input),
      );
      assert.ok(fuzzDiffers, "reseeding should produce a different fuzz corpus");
    });
  }
}
