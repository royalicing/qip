#!/usr/bin/env node

import { pathToFileURL } from "node:url";

export function simulateFixedSteps(updateTimesMS, {
  stepMS = 10,
  maxCatchUpSteps = Number.POSITIVE_INFINITY,
} = {}) {
  let lastStepMS = 0;
  let steps = 0;
  let droppedSteps = 0;
  let largestUpdateWork = 0;

  for (const nowMS of updateTimesMS) {
    let updateWork = 0;
    while (
      updateWork < maxCatchUpSteps &&
      nowMS - lastStepMS >= stepMS
    ) {
      lastStepMS += stepMS;
      steps += 1;
      updateWork += 1;
    }
    largestUpdateWork = Math.max(largestUpdateWork, updateWork);

    if (nowMS - lastStepMS >= stepMS) {
      const dropped = Math.floor((nowMS - lastStepMS) / stepMS);
      droppedSteps += dropped;
      lastStepMS = nowMS;
    }
  }

  const nowMS = updateTimesMS.at(-1) ?? 0;
  return {
    steps,
    droppedSteps,
    largestUpdateWork,
    nextWakeAtMS: lastStepMS + stepMS,
    nowMS,
  };
}

export function integrateSpring(updateTimesMS, {
  fixedStepMS = null,
} = {}) {
  let position = 1;
  let velocity = 0;
  let previousMS = 0;
  let accumulatorMS = 0;

  function integrate(dtSeconds) {
    velocity += -10 * position * dtSeconds;
    position += velocity * dtSeconds;
  }

  for (const nowMS of updateTimesMS) {
    const elapsedMS = nowMS - previousMS;
    previousMS = nowMS;
    if (fixedStepMS === null) {
      integrate(elapsedMS / 1000);
      continue;
    }
    accumulatorMS += elapsedMS;
    while (accumulatorMS >= fixedStepMS) {
      integrate(fixedStepMS / 1000);
      accumulatorMS -= fixedStepMS;
    }
  }

  return { position, velocity };
}

export function simulateTimedInput(updateTimesMS, eventAtMS) {
  const timeline = [...new Set([...updateTimesMS, eventAtMS])].sort((a, b) => a - b);
  let lastStepMS = 0;
  let position = 0;
  let direction = 1;

  for (const nowMS of timeline) {
    while (nowMS - lastStepMS >= 100) {
      position += direction;
      lastStepMS += 100;
    }
    // Contract rule: due steps at T run before events delivered at T.
    if (nowMS === eventAtMS) direction = -1;
  }

  return { position, direction, nextWakeAtMS: lastStepMS + 100 };
}

function regularTimes(endMS, intervalMS) {
  const times = [];
  for (let timeMS = intervalMS; timeMS < endMS; timeMS += intervalMS) {
    times.push(timeMS);
  }
  times.push(endMS);
  return times;
}

export function runScenarios() {
  const regular = regularTimes(1000, 10);
  const irregular = [7, 41, 58, 143, 201, 377, 455, 612, 799, 1000];
  const fixedRegular = integrateSpring(regular, { fixedStepMS: 10 });
  const fixedIrregular = integrateSpring(irregular, { fixedStepMS: 10 });
  const variableRegular = integrateSpring(regular);
  const variableIrregular = integrateSpring(irregular);
  const exactGap = simulateFixedSteps([5000], { stepMS: 10 });
  const boundedGap = simulateFixedSteps([5000], {
    stepMS: 10,
    maxCatchUpSteps: 8,
  });
  const timedInputRegular = simulateTimedInput(regular, 455);
  const timedInputIrregular = simulateTimedInput(irregular, 455);

  return {
    fixedRegular,
    fixedIrregular,
    variableRegular,
    variableIrregular,
    exactGap,
    boundedGap,
    timedInputRegular,
    timedInputIrregular,
  };
}

function fixed(value) {
  return value.toFixed(9);
}

function printScenarios(results) {
  console.log("Fixed timestep: rendering/update cadence does not change the state");
  console.table([
    { schedule: "regular 10 ms", position: fixed(results.fixedRegular.position), velocity: fixed(results.fixedRegular.velocity) },
    { schedule: "irregular", position: fixed(results.fixedIrregular.position), velocity: fixed(results.fixedIrregular.velocity) },
  ]);

  console.log("Variable delta: the same elapsed second produces different state");
  console.table([
    { schedule: "regular 10 ms", position: fixed(results.variableRegular.position), velocity: fixed(results.variableRegular.velocity) },
    { schedule: "irregular", position: fixed(results.variableIrregular.position), velocity: fixed(results.variableIrregular.velocity) },
  ]);

  console.log("A 5 second late wake: bounded catch-up limits one update's work");
  console.table([
    { policy: "exact", steps_run: results.exactGap.steps, steps_dropped: results.exactGap.droppedSteps, largest_update: results.exactGap.largestUpdateWork },
    { policy: "max 8", steps_run: results.boundedGap.steps, steps_dropped: results.boundedGap.droppedSteps, largest_update: results.boundedGap.largestUpdateWork },
  ]);

  console.log("An event at 455 ms produces the same state under two host schedules");
  console.table([
    { schedule: "regular + event", ...results.timedInputRegular },
    { schedule: "irregular + event", ...results.timedInputIrregular },
  ]);
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  printScenarios(runScenarios());
}
