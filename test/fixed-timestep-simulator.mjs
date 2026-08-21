import assert from "node:assert/strict";
import test from "node:test";

import { runScenarios } from "../tools/fixed-timestep-simulator.mjs";

test("fixed-step state is independent of update cadence", () => {
  const results = runScenarios();
  assert.deepEqual(results.fixedRegular, results.fixedIrregular);
  assert.notDeepEqual(results.variableRegular, results.variableIrregular);
});

test("an event update preserves its exact time across render schedules", () => {
  const results = runScenarios();
  assert.deepEqual(results.timedInputRegular, results.timedInputIrregular);
});

test("bounded catch-up prevents one late update from doing unbounded work", () => {
  const results = runScenarios();
  assert.equal(results.exactGap.steps, 500);
  assert.equal(results.boundedGap.steps, 8);
  assert.equal(results.boundedGap.droppedSteps, 492);
  assert.equal(results.boundedGap.nextWakeAtMS, 5010);
});
