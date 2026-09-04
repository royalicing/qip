import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { ContentComponentHost } from "./lib/content-component-host.mjs";

const debuggerPath = fileURLToPath(new URL("../components/interactive/wasm-debugger.wasm", import.meta.url));
const targetPath = fileURLToPath(new URL("../components/text/hello.wasm", import.meta.url));
const wcPath = fileURLToPath(new URL("../components/text/wc.wasm", import.meta.url));
const infiniteLoopPath = fileURLToPath(new URL("../components/text/infinite-loop.wasm", import.meta.url));
const bulkMemoryPath = fileURLToPath(new URL("./fixtures/wasm-debugger-bulk-memory.wasm", import.meta.url));
const stripAnsiPath = fileURLToPath(new URL("../components/text/strip-ansi-sgr.wasm", import.meta.url));
const ansiHTMLPath = fileURLToPath(new URL("../components/text/ansi-sgr-to-html.wasm", import.meta.url));
const decoder = new TextDecoder("utf-8", { fatal: true });
const boundary = "uuid-00000000-0000-0000-0000-000000000000";
const [stripAnsiBytes, ansiHTMLBytes] = await Promise.all([
  readFile(stripAnsiPath),
  readFile(ansiHTMLPath),
]);
const stripAnsiHost = new ContentComponentHost(stripAnsiBytes, { label: "strip ANSI" });
const ansiHTMLHost = new ContentComponentHost(ansiHTMLBytes, { label: "ANSI to HTML" });

function multipart(parts) {
  const chunks = [];
  for (const [name, body] of parts) {
    chunks.push(
      Buffer.from(
        `--${boundary}\r\n` +
        `Content-Disposition: form-data; name="${name}"; filename="${name}"\r\n` +
        `Content-Type: application/octet-stream\r\n\r\n`,
      ),
      Buffer.from(body),
      Buffer.from("\r\n"),
    );
  }
  chunks.push(Buffer.from(`--${boundary}--\r\n`));
  return Buffer.concat(chunks);
}

function renderedANSI(instance, inputSize) {
  const result = BigInt.asUintN(64, instance.exports.render(inputSize));
  assert.equal(result >> 63n, 0n);
  const size = Number(result & 0xffff_ffffn);
  const pointer = Number((result >> 32n) & 0x7fff_ffffn);
  return decoder.decode(new Uint8Array(instance.exports.memory.buffer, pointer, size));
}

function runTextComponent(host, input) {
  const result = host.run(input);
  assert.equal(result.status, "accepted");
  return decoder.decode(result.output);
}

function stripANSI(input) {
  return runTextComponent(stripAnsiHost, input);
}

function renderedText(instance, inputSize) {
  return stripANSI(renderedANSI(instance, inputSize));
}

function sendKey(instance, time, keysym, flags = 1) {
  instance.exports.begin_update_at(time);
  assert.equal(instance.exports.key_event(keysym, flags), 1);
  assert.equal(instance.exports.finish_update(), time);
}

function sendKeyWithBudget(instance, time, keysym, budget, flags = 1) {
  instance.exports.begin_update_at(time);
  assert.equal(instance.exports.uniform_set_instruction_budget(budget), budget);
  assert.equal(instance.exports.key_event(keysym, flags), 1);
  assert.equal(instance.exports.finish_update(), time);
}

function assertTerminalWidth(text) {
  for (const line of text.split("\n")) assert.ok(line.length <= 80, `${line.length}-column line: ${line}`);
}

function instructionRowCount(text) {
  return text.split("\n").filter((line) => /^[@rnf←→ ]{3}f\d+ 0x[0-9a-f]+/.test(line)).length;
}

test("interactive Wasm debugger steps and restarts a target component", async () => {
  const [debuggerBytes, targetBytes] = await Promise.all([
    readFile(debuggerPath),
    readFile(targetPath),
  ]);
  const { instance } = await WebAssembly.instantiate(debuggerBytes, {});
  const debuggerInput = multipart([["component", targetBytes]]);
  const inputPointer = instance.exports.input_ptr();
  new Uint8Array(instance.exports.memory.buffer, inputPointer, debuggerInput.length).set(debuggerInput);

  const initialANSI = renderedANSI(instance, debuggerInput.length);
  assert.match(initialANSI, /^\x1b\[1mMEMORY\x1b\[0m/);
  assert.match(initialANSI, /\x1b\[1;97m@\x1b\[0m/);
  assert.doesNotMatch(initialANSI, /\x1b\[1;97mr\x1b\[0m/);
  assert.match(initialANSI, /\x1b\[1;97m→\x1b\[0m/);
  assert.doesNotMatch(initialANSI, /\x1b\[1;97mn\x1b\[0m/);
  assert.match(initialANSI, /\x1b\[1;97mx\x1b\[0m examine  \x1b\[1;97m↑\/↓\x1b\[0m page/);
  assert.match(initialANSI, /\x1b\[1;97mSpace\x1b\[0m run/);
  assert.match(initialANSI, /\x1b\[94m0x00010000\x1b\[0m/);
  assert.match(initialANSI, /\x1b\[2m00 00 00 00/);
  assert.match(initialANSI, /\x1b\[2m0x[0-9a-f]{6}\x1b\[0m/);
  assert.match(initialANSI, /\x1b\[34mglobal\x1b\[95m\.get\x1b\[0m 2\x1b\[0m/);
  assert.match(initialANSI, /\x1b\[34mlocal\x1b\[95m\.get\x1b\[0m 0\x1b\[0m/);
  assert.match(initialANSI, /\x1b\[95m  global\[2\] 0x0000000000020000\x1b\[0m/);
  const initialHTML = runTextComponent(ansiHTMLHost, initialANSI);
  assert.match(initialHTML, /<b>MEMORY<\/b>/);
  assert.match(initialHTML, /<b><span style="color:#ffffff;">@<\/span><\/b>/);
  assert.match(initialHTML, /<span style="color:#3b8eea;">0x00010000<\/span>/);
  assert.match(initialHTML, /<span style="opacity:\.65;">0x[0-9a-f]{6}<\/span>/);
  const initial = stripANSI(initialANSI);
  assert.doesNotMatch(initial, /\x1b\[/);
  assert.equal(instance.exports.target_input_ptr(), 0x10000);
  assertTerminalWidth(initial);
  assert.match(initial, /^MEMORY  /);
  assert.match(initial, /INSTRUCTIONS  ready/);
  assert.match(initial, /^@ {2}f\d+ 0x[0-9a-f]+.*\n→ {2}f\d+/m);
  assert.match(initial, /wasm=274 B  input=0 B/);
  assert.match(initial, /Space run[\s\S]*f\/Shift-F11 finish/);
  assert.doesNotMatch(initial, /r restart/);
  assert.doesNotMatch(initial, /n\/F10 next  s\/F11 step/);
  assert.match(initial, /STACKS\/LOCALS  calls=0 returns=0/);
  assert.match(initial, /global\[0\] 0x[0-9a-f]{16}/);
  assert.match(initial, /global\[2\] 0x0000000000020000/);
  assert.match(initial, /frame f4 render/);
  assert.match(initial, /param\[0\] 0x0000000000000000/);
  assert.match(initial, /stack empty[\s\S]*global\.get 2\n[^\n]*-> i32 0x00020000/);
  assert.match(initial, /COUNTERS  instructions=0  branches=0/);
  assert.match(initial, /loop f\d+ 0x[0-9a-f]+ iterations=0/);
  assert.match(initial, /MEMORY  196608 B  r=0 w=0  x examine  ↑\/↓ page\n  view 0x00010000\.\.0x00010080/);

  instance.exports.begin_update_at(1n);
  assert.equal(instance.exports.finish_update(), 1n);

  // Right Arrow is the visible step-in control; s remains a debugger-style alias.
  sendKey(instance, 2n, 0xff53);
  assert.doesNotMatch(renderedANSI(instance, 0), /\x1b\[1;97mr\x1b\[0m/);
  for (let time = 3n; time <= 4n; time++) sendKey(instance, time, 0x73); // s
  const beforeShift = renderedText(instance, 0);
  const beforeShiftANSI = renderedANSI(instance, 0);
  assert.match(beforeShift, /^@ {2}f4 .* i64\.shl/m);
  assert.match(beforeShift, /stack\[1\] i64 0x0000000000000020/);
  assert.match(beforeShift, /stack\[0\] i64 0x0000000000020000/);
  assert.match(beforeShift, /stack\[0\] i64 0x0000000000020000[^\n]*\n[^\n]*stack\[1\] i64 0x0000000000000020/);
  assert.match(beforeShiftANSI, /\x1b\[93m  stack\[1\] i64 0x0000000000000020\x1b\[0m/);
  assert.match(beforeShiftANSI, /\x1b\[93m  stack\[0\] i64 0x0000000000020000\x1b\[0m/);
  assert.match(beforeShift, /i64\.shl\n[^\n]*-> i64 0x0002000000000000/);
  assert.doesNotMatch(beforeShift, /;; 0x[0-9a-f]+ <</);
  assert.doesNotMatch(beforeShift, /value\[/);
  for (let time = 5n; time <= 6n; time++) sendKey(instance, time, 0x73); // s
  assert.match(renderedANSI(instance, 0), /\x1b\[96m  stack\[1\] i32 0x00000000\x1b\[0m/);
  assert.match(renderedText(instance, 0), /^@ {2}f4 .* call f3[^\n]*\n {4};; \(param i32\) \(result i32\)\n→ {4}f3 .*\n {4}…\nn {2}f4 .*i64\.extend_i32_u/m);
  assert.match(renderedText(instance, 0), /COUNTERS  instructions=5/);
  sendKey(instance, 7n, 0x6e); // n: step over the call.
  assert.match(renderedText(instance, 0), /calls=1 returns=1[\s\S]*^@ {2}f\d+ 0x[0-9a-f]+ i64\.extend_i32_u/m);

  sendKey(instance, 8n, 0x72); // r: restart.
  assert.match(renderedText(instance, 0), /COUNTERS  instructions=0/);
  sendKey(instance, 9n, 0x6e); // n: step over an ordinary instruction.
  assert.match(renderedText(instance, 0), /COUNTERS  instructions=1/);
  sendKey(instance, 10n, 0x72); // r
  sendKey(instance, 11n, 0x66); // f: finish the current frame.
  const normallyFinishedANSI = renderedANSI(instance, 0);
  const normallyFinished = stripANSI(normallyFinishedANSI);
  assertTerminalWidth(normallyFinished);
  assert.match(normallyFinishedANSI, /\x1b\[92m48 65 6c 6c 6f/);
  assert.match(normallyFinished, /last write 0x00020008 width=4[\s\S]*INSTRUCTIONS  halted/);
  assert.match(normallyFinished, /r restart/);
  assert.doesNotMatch(normallyFinished, /Space run|f\/Shift-F11 finish/);
  assert.match(normallyFinished, /Hello, World[\s\S]*\^\^ \^\^ \^\^ \^\^[^\n]*last write/);
  assert.match(normallyFinished, /view 0x00020000\.\.[\s\S]*Hello, World/);
  sendKey(instance, 12n, 0x72); // r
  sendKey(instance, 13n, 0x63); // c
  assert.match(renderedText(instance, 0), /INSTRUCTIONS  halted/);

  // Visual Studio-style function keys remain aliases.
  sendKey(instance, 14n, 0x72); // r
  sendKey(instance, 15n, 0xffc8); // F11: step into.
  sendKey(instance, 16n, 0xffc7); // F10: step over.
  assert.match(renderedText(instance, 0), /COUNTERS  instructions=2/);
  sendKey(instance, 17n, 0xffc8, 1 | (1 << 2)); // Shift-F11: step out.
  assert.match(renderedText(instance, 0), /INSTRUCTIONS  halted/);

  const nativeTarget = (await WebAssembly.instantiate(targetBytes, {})).instance;
  const expectedResult = BigInt.asUintN(64, nativeTarget.exports.render(0));
  sendKey(instance, 18n, 0x72); // r
  sendKey(instance, 19n, 0xffc2); // F5: continue.
  const completed = renderedText(instance, 0);
  assert.match(completed, /INSTRUCTIONS  halted/);
  assert.match(completed, /OUTPUT succeeded size=12 ptr=0x00020000 packed=/);
  assert.match(completed, new RegExp("packed=0x" + expectedResult.toString(16).padStart(16, "0")));

  sendKey(instance, 20n, 0x78); // x: enter a memory address.
  assert.match(renderedText(instance, 0), /x address 0x00000000 \(0\/8\)  i input  o output  w last-write\n  0-9\/a-f hex  Backspace edit  Enter accept  Esc cancel/);
  sendKey(instance, 21n, 0x69); // i: input_ptr.
  assert.match(renderedText(instance, 0), /view 0x00010000\.\./);
  sendKey(instance, 22n, 0x78); // x
  sendKey(instance, 23n, 0x6f); // o: completed output pointer.
  const expectedPointer = Number((expectedResult >> 32n) & 0x7fff_ffffn);
  assert.match(renderedText(instance, 0), new RegExp(`view 0x${expectedPointer.toString(16).padStart(8, "0")}\\.\\.`));

  sendKey(instance, 24n, 0x78); // x: enter a hexadecimal address.
  for (const [time, digit] of [[25n, "2"], [26n, "0"], [27n, "0"], [28n, "0"], [29n, "8"]]) {
    sendKey(instance, time, digit.codePointAt(0));
  }
  sendKey(instance, 30n, 0xff0d); // Enter.
  assert.match(renderedText(instance, 0), /view 0x00020008\.\./);
  sendKey(instance, 31n, 0xff54); // Down Arrow: next 128-byte page.
  assert.match(renderedText(instance, 0), /view 0x00020088\.\./);
  sendKey(instance, 32n, 0xff52); // Up Arrow: previous page.
  assert.match(renderedText(instance, 0), /view 0x00020008\.\./);

  sendKey(instance, 33n, 0x72); // r
  for (let time = 34n; time <= 38n; time++) sendKey(instance, time, 0x73); // s to call.
  sendKey(instance, 39n, 0x73); // s into the callee.
  const insideCallee = renderedText(instance, 0);
  assert.match(insideCallee, /^@ {2}f3 .*\n→ {2}f3/m);
  assert.match(insideCallee, /^f {2}f4 /m);
  assert.ok(insideCallee.indexOf("\n→  f3 ") < insideCallee.indexOf("\nf  f4 "));

  instance.exports.begin_update_at(40n);
  assert.equal(instance.exports.key_event(0x6f, 1), 0); // o is not an alias for n.
  assert.equal(instance.exports.key_event(0x69, 1), 0); // i is not an alias for s.
  assert.equal(instance.exports.key_event(0x20, 1), 1); // Space continues to the end.
  assert.equal(instance.exports.finish_update(), 40n);
  assert.match(renderedText(instance, 0), /INSTRUCTIONS  halted/);
});

test("steps memory.copy and memory.fill with memory provenance", async () => {
  const [debuggerBytes, targetBytes] = await Promise.all([
    readFile(debuggerPath),
    readFile(bulkMemoryPath),
  ]);
  const { instance } = await WebAssembly.instantiate(debuggerBytes, {});
  const debuggerInput = multipart([["component", targetBytes]]);
  const inputPointer = instance.exports.input_ptr();
  new Uint8Array(instance.exports.memory.buffer, inputPointer, debuggerInput.length).set(debuggerInput);
  renderedText(instance, debuggerInput.length);
  instance.exports.begin_update_at(1n);
  instance.exports.finish_update();

  sendKey(instance, 2n, 0x73);
  sendKey(instance, 3n, 0x73);
  sendKey(instance, 4n, 0x73);
  const beforeCopyANSI = renderedANSI(instance, 0);
  const beforeCopy = stripANSI(beforeCopyANSI);
  assertTerminalWidth(beforeCopy);
  assert.match(beforeCopyANSI, /\x1b\[93mmemory\x1b\[92m\.copy\x1b\[0m/);
  assert.match(beforeCopy, /^@ {2}f\d+ .* memory\.copy/m);
  assert.match(beforeCopy, /stack\[2\] i32 0x00000006/);
  assert.match(beforeCopy, /stack\[1\] i32 0x00000010/);
  assert.match(beforeCopy, /stack\[0\] i32 0x00000012/);
  assert.match(beforeCopy, /memory\.copy[\s\S]*-> dst 00000012\+6[\s\S]*src 00000010/);

  sendKey(instance, 5n, 0x73);
  sendKey(instance, 6n, 0x73);
  sendKey(instance, 7n, 0x73);
  sendKey(instance, 8n, 0x73);
  const beforeFill = renderedText(instance, 0);
  assert.match(beforeFill, /^@ {2}f\d+ .* memory\.fill/m);
  assert.match(beforeFill, /memory\.fill[\s\S]*-> dst 00000020\+4[\s\S]*byte 34/);

  sendKey(instance, 9n, 0x73);
  sendKey(instance, 10n, 0x63);
  const completedANSI = renderedANSI(instance, 0);
  const completed = stripANSI(completedANSI);
  assertTerminalWidth(completed);
  assert.match(completed, /OUTPUT succeeded size=4 ptr=0x00000020/);
  assert.match(completed, /MEMORY  65536 B  r=1 w=2/);
  assert.match(completed, /view 0x00000020\.\./);
  assert.match(completedANSI, /\x1b\[92m34 34 34 34 /);

  sendKey(instance, 11n, 0x78);
  sendKey(instance, 12n, 0x72);
  const copiedMemory = renderedText(instance, 0);
  assert.match(copiedMemory, /view 0x00000010\.\./);
  assert.match(copiedMemory, /00000010  61 62 61 62 63 64 65 66/);

  sendKey(instance, 13n, 0x78);
  sendKey(instance, 14n, 0x77);
  assert.match(renderedText(instance, 0), /view 0x00000020\.\./);
});

test("step backward replays an uninterrupted step-into history", async () => {
  const [debuggerBytes, targetBytes] = await Promise.all([
    readFile(debuggerPath),
    readFile(targetPath),
  ]);
  const { instance } = await WebAssembly.instantiate(debuggerBytes, {});
  const debuggerInput = multipart([["component", targetBytes]]);
  const inputPointer = instance.exports.input_ptr();
  new Uint8Array(instance.exports.memory.buffer, inputPointer, debuggerInput.length).set(debuggerInput);
  renderedText(instance, debuggerInput.length);
  instance.exports.begin_update_at(1n);
  instance.exports.finish_update();

  sendKey(instance, 2n, 0xff53); // Right Arrow
  sendKey(instance, 3n, 0xff53); // Right Arrow
  const afterTwoStepsANSI = renderedANSI(instance, 0);
  assert.match(afterTwoStepsANSI, /\x1b\[1;97m←\x1b\[0m/);
  assert.match(afterTwoStepsANSI, /\x1b\[1;97mr\x1b\[0m/);
  const afterTwoSteps = stripANSI(afterTwoStepsANSI);
  assert.match(afterTwoSteps, /^← {2}f\d+ .+\n@ {2}f\d+/m);
  assert.doesNotMatch(afterTwoSteps, /Alt-\[ back/);
  sendKey(instance, 4n, 0xff53); // Right Arrow
  sendKey(instance, 5n, 0xff51); // Left Arrow: step backward.
  assert.equal(renderedText(instance, 0), afterTwoSteps);

  sendKey(instance, 6n, 0x6e); // n disables the s-only replay history.
  const afterNext = renderedText(instance, 0);
  assert.doesNotMatch(afterNext, /^←/m);
  sendKey(instance, 7n, 0x5b, 1 | (1 << 4));
  assert.equal(renderedText(instance, 0), afterNext);

  sendKey(instance, 8n, 0x72); // r starts a fresh history.
  sendKey(instance, 9n, 0x73); // s
  sendKey(instance, 10n, 0x5b, 1 | (1 << 4));
  assert.match(renderedText(instance, 0), /COUNTERS  instructions=0/);

  sendKey(instance, 11n, 0x66); // f
  const afterFinish = renderedText(instance, 0);
  const finishCount = Number(afterFinish.match(/COUNTERS  instructions=(\d+)/)?.[1]);
  assert.match(afterFinish, /INSTRUCTIONS  halted/);
  assert.match(afterFinish, /^← {2}f\d+ .* end/m);
  sendKey(instance, 12n, 0x5b, 1 | (1 << 4)); // Alt/Option-[: undo the final instruction.
  const beforeFinish = renderedText(instance, 0);
  assert.match(beforeFinish, /INSTRUCTIONS  ready/);
  assert.match(beforeFinish, new RegExp(`COUNTERS  instructions=${finishCount - 1}`));

  sendKey(instance, 13n, 0x72); // r
  sendKey(instance, 14n, 0x63); // c reaches the same initial-frame result.
  assert.equal(renderedText(instance, 0), afterFinish);
  sendKey(instance, 15n, 0x5b, 1 | (1 << 4));
  assert.equal(renderedText(instance, 0), beforeFinish);
});

test("continue pauses and resumes an infinite component at command budgets", async () => {
  const [debuggerBytes, targetBytes] = await Promise.all([
    readFile(debuggerPath),
    readFile(infiniteLoopPath),
  ]);
  const { instance } = await WebAssembly.instantiate(debuggerBytes, {});
  const debuggerInput = multipart([["component", targetBytes]]);
  const inputPointer = instance.exports.input_ptr();
  new Uint8Array(instance.exports.memory.buffer, inputPointer, debuggerInput.length).set(debuggerInput);
  renderedText(instance, debuggerInput.length);
  instance.exports.begin_update_at(1n);
  instance.exports.finish_update();

  instance.exports.begin_update_at(2n);
  assert.equal(instance.exports.uniform_set_instruction_budget(0), 1);
  assert.equal(instance.exports.uniform_set_instruction_budget(0xffff_ffff), 1_000_000);
  assert.equal(instance.exports.finish_update(), 2n);

  sendKeyWithBudget(instance, 3n, 0x63, 7); // c
  const firstPause = renderedText(instance, 0);
  assert.match(firstPause, /INSTRUCTIONS  ready/);
  assert.match(firstPause, /COUNTERS  instructions=7/);
  assert.match(firstPause, /Space continue/);
  assert.match(firstPause, /paused: 7-instruction budget/);
  assert.doesNotMatch(firstPause, /trap/);

  sendKeyWithBudget(instance, 4n, 0x20, 11); // Space: another independent budget.
  const secondPause = renderedText(instance, 0);
  assert.match(secondPause, /INSTRUCTIONS  ready/);
  assert.match(secondPause, /COUNTERS  instructions=18/);
  assert.match(secondPause, /paused: 11-instruction budget/);

  sendKey(instance, 5n, 0x73); // s: one instruction clears the budget pause.
  const afterStep = renderedText(instance, 0);
  assert.match(afterStep, /INSTRUCTIONS  ready/);
  assert.match(afterStep, /COUNTERS  instructions=19/);
  assert.doesNotMatch(afterStep, /paused:/);
});

test("memory examine shortcuts retain the last read and write separately", async () => {
  const [debuggerBytes, targetBytes] = await Promise.all([
    readFile(debuggerPath),
    readFile(targetPath),
  ]);
  const { instance } = await WebAssembly.instantiate(debuggerBytes, {});
  const debuggerInput = multipart([
    ["component", targetBytes],
    ["input", Buffer.from("QIP")],
  ]);
  const inputPointer = instance.exports.input_ptr();
  new Uint8Array(instance.exports.memory.buffer, inputPointer, debuggerInput.length).set(debuggerInput);
  renderedText(instance, debuggerInput.length);
  instance.exports.begin_update_at(1n);
  instance.exports.finish_update();

  sendKey(instance, 2n, 0x63); // c
  sendKey(instance, 3n, 0x78); // x
  const memoryPrompt = renderedText(instance, 0);
  assertTerminalWidth(memoryPrompt);
  assert.match(memoryPrompt, /r last-read  w last-write/);
  sendKey(instance, 4n, 0x77); // w: final store8 destination.
  assert.match(renderedText(instance, 0), /view 0x00020009\.\./);
  sendKey(instance, 5n, 0x78); // x
  sendKey(instance, 6n, 0x72); // r: final load8_u source.
  assert.match(renderedText(instance, 0), /view 0x00010002\.\./);

  sendKey(instance, 7n, 0x72); // r outside x still restarts.
  sendKey(instance, 8n, 0x78); // x
  assert.doesNotMatch(renderedText(instance, 0), /last-read|last-write/);
});

test("multipart input reaches the target component and survives restart", async () => {
  const [debuggerBytes, targetBytes] = await Promise.all([
    readFile(debuggerPath),
    readFile(wcPath),
  ]);
  const targetInput = Buffer.from("one two\n");
  const debuggerInput = multipart([
    ["component", targetBytes],
    ["input", targetInput],
  ]);
  const { instance } = await WebAssembly.instantiate(debuggerBytes, {});
  const inputPointer = instance.exports.input_ptr();
  new Uint8Array(instance.exports.memory.buffer, inputPointer, debuggerInput.length).set(debuggerInput);

  const initialANSI = renderedANSI(instance, debuggerInput.length);
  const initial = stripANSI(initialANSI);
  assert.equal(instance.exports.target_input_ptr(), 0x100000);
  assert.match(initial, /param\[0\] 0x0000000000000008/);
  assert.match(initial, /wasm=645 B  input=8 B/);
  assert.match(initial, /COUNTERS  instructions=0  branches=0/);
  assert.match(initial, /view 0x00100000\.\.0x00100080/);
  assert.match(initial, /\|one two\.\.{8}\|/);
  assert.match(initialANSI, /\x1b\[34m6f 6e 65 20 74 77 6f 0a /);
  assert.match(initialANSI, /\x1b\[34mone two\.\x1b\[0m/);
  assert.match(initialANSI, /\x1b\[2m00 00 00 00/);
  assert.equal(instructionRowCount(initial), 11);

  sendKey(instance, 2n, 0x73); // s: global.get
  assert.equal(instructionRowCount(renderedText(instance, 0)), 11);
  sendKey(instance, 3n, 0x73); // s: i32.const
  sendKey(instance, 4n, 0x73); // s: i32.sub, landing on local.tee
  const teeANSI = renderedANSI(instance, 0);
  assert.match(teeANSI, /\x1b\[34mlocal\x1b\[92m\.tee\x1b\[0m 1\x1b\[0m/);
  assert.match(teeANSI, /\x1b\[34mglobal\x1b\[92m\.set\x1b\[0m 0\x1b\[0m/);
  assert.match(teeANSI, /\x1b\[1;92m    local\[0\] 0x0000000000000000\x1b\[0m/);
  assert.match(teeANSI, /\x1b\[92m  stack\[0\] i32 0x000ffff0\x1b\[0m/);
  assertTerminalWidth(stripANSI(teeANSI));
  sendKey(instance, 5n, 0x73); // s: write local[0]
  assert.match(renderedANSI(instance, 0), /\x1b\[1;92m    local\[0\] 0x00000000000ffff0\x1b\[0m/);
  assert.match(renderedANSI(instance, 0), /\x1b\[1;92m  global\[0\] 0x0000000000100000\x1b\[0m/);
  sendKey(instance, 6n, 0x73); // s: write global[0]
  assert.match(renderedANSI(instance, 0), /\x1b\[1;92m  global\[0\] 0x00000000000ffff0\x1b\[0m/);
  sendKey(instance, 7n, 0x72); // r

  for (let time = 8n; time <= 17n; time++) sendKey(instance, time, 0x73); // s to select.
  const selectANSI = renderedANSI(instance, 0);
  const selectText = stripANSI(selectANSI);
  assert.match(selectANSI, /\x1b\[91mselect\x1b\[0m/);
  assert.match(selectANSI, /\x1b\[91m  stack\[2\] i32 0x00000001\x1b\[0m/);
  assert.match(selectANSI, /\x1b\[91m  stack\[1\] i32 0x00400000\x1b\[0m/);
  assert.match(selectANSI, /\x1b\[4;94m  stack\[0\] i32 0x00000008\x1b\[0m/);
  assert.match(selectText, /select\n[^\n]*-> i32 0x00000008/);
  assertTerminalWidth(selectText);

  const nativeTarget = (await WebAssembly.instantiate(targetBytes, {})).instance;
  new Uint8Array(
    nativeTarget.exports.memory.buffer,
    nativeTarget.exports.input_ptr(),
    targetInput.length,
  ).set(targetInput);
  const expectedResult = BigInt.asUintN(64, nativeTarget.exports.render(targetInput.length));
  const expectedPacked = expectedResult.toString(16).padStart(16, "0");
  const expectedPointer = Number((expectedResult >> 32n) & 0x7fff_ffffn);
  const expectedMemoryView = new RegExp(`view 0x${expectedPointer.toString(16).padStart(8, "0")}\\.\\.`);

  sendKey(instance, 18n, 0x72); // r
  sendKey(instance, 19n, 0x63); // c
  const firstCompleted = renderedText(instance, 0);
  assert.match(firstCompleted, new RegExp(`packed=0x${expectedPacked}`));
  assert.match(firstCompleted, expectedMemoryView);
  sendKey(instance, 20n, 0x72); // r
  assert.match(renderedText(instance, 0), /param\[0\] 0x0000000000000008/);
  sendKey(instance, 21n, 0x63); // c
  const secondCompleted = renderedText(instance, 0);
  assert.match(secondCompleted, new RegExp(`packed=0x${expectedPacked}`));
  assert.match(secondCompleted, expectedMemoryView);
});

test("Go qip and Node qipx feed the same multipart debugger input", () => {
  const input = Buffer.from("one two\n");
  const args = [
    "run",
    "--form", `component=@${wcPath}`,
    "--form", "input=@-",
    debuggerPath,
  ];
  const go = spawnSync("./qip", args, { input });
  assert.equal(go.status, 0, go.stderr.toString());
  const node = spawnSync(process.execPath, ["npm/qipx/cli.mjs", ...args], { input });
  assert.equal(node.status, 0, node.stderr.toString());
  assert.deepEqual(node.stdout, go.stdout);
  assert.match(stripANSI(go.stdout.toString()), /param\[0\] 0x0000000000000008/);
});
