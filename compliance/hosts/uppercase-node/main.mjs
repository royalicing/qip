// Self-contained example: testing a Node.js-stdlib uppercase implementation
// against the QIP Content Compliance component for Unicode 17 uppercase.
//
//   node compliance/hosts/uppercase-node/main.mjs
//
// Uses only Node built-ins. The implementation under test is
// String.prototype.toUpperCase (Node's bundled ICU), wrapped so invalid
// UTF-8 bytes pass through unchanged, since the contract is bytes -> bytes.
// Exit code 0 = compliant, 1 = divergences found.
import { readFile } from "node:fs/promises";

// --- implementation under test (Node stdlib) -------------------------------

// Length of the valid UTF-8 sequence at buf[i], or 0 if invalid (strict:
// rejects overlong forms, surrogates, > U+10FFFF).
function utf8SequenceLength(buf, i) {
  const b0 = buf[i];
  if (b0 < 0x80) return 1;
  if (b0 < 0xc2) return 0;
  const b1 = buf[i + 1];
  if (b0 < 0xe0) {
    return b1 >= 0x80 && b1 <= 0xbf ? 2 : 0;
  }
  if (b0 < 0xf0) {
    const lo = b0 === 0xe0 ? 0xa0 : 0x80;
    const hi = b0 === 0xed ? 0x9f : 0xbf;
    if (!(b1 >= lo && b1 <= hi)) return 0;
    const b2 = buf[i + 2];
    return b2 >= 0x80 && b2 <= 0xbf ? 3 : 0;
  }
  if (b0 < 0xf5) {
    const lo = b0 === 0xf0 ? 0x90 : 0x80;
    const hi = b0 === 0xf4 ? 0x8f : 0xbf;
    if (!(b1 >= lo && b1 <= hi)) return 0;
    const b2 = buf[i + 2];
    const b3 = buf[i + 3];
    return b2 >= 0x80 && b2 <= 0xbf && b3 >= 0x80 && b3 <= 0xbf ? 4 : 0;
  }
  return 0;
}

function uppercaseBytes(input) {
  const parts = [];
  let runStart = 0;
  let i = 0;
  const flushRun = (end) => {
    if (end > runStart) {
      parts.push(Buffer.from(input.toString("utf8", runStart, end).toUpperCase(), "utf8"));
    }
  };
  while (i < input.length) {
    const len = utf8SequenceLength(input, i);
    if (len === 0) {
      flushRun(i);
      parts.push(input.subarray(i, i + 1)); // invalid byte passes through
      i += 1;
      runStart = i;
    } else {
      i += len;
    }
  }
  flushRun(i);
  return Buffer.concat(parts);
}

// --- qip compliance bridge --------------------------------------------------

const wasmBytes = await readFile(new URL("../../unicode-17-uppercase.comply.wasm", import.meta.url));

const failures = [];
let equalityCases = 0;
let examineCases = 0;
let memory;
let openExamination = null;

const bytes = (ptr, len) => Buffer.from(new Uint8Array(memory.buffer, ptr, len));

const { instance } = await WebAssembly.instantiate(wasmBytes, {
  qip: {
    render_must_equal(ordinal, inPtr, inLen, expectedPtr, expectedLen) {
      equalityCases++;
      const input = bytes(inPtr, inLen);
      const expected = bytes(expectedPtr, expectedLen);
      const actual = uppercaseBytes(input);
      if (!actual.equals(expected)) {
        failures.push({ ordinal, kind: "equal", input, expected, actual });
        return 0;
      }
      return 1;
    },
    render_must_trap(ordinal, inPtr, inLen) {
      // A pure function cannot trap; any expect-trap case is a failure here.
      failures.push({ ordinal, kind: "trap", input: bytes(inPtr, inLen) });
      return 0;
    },
    render_examine(ordinal, inPtr, inLen, outPtr, outCap) {
      openExamination = ordinal;
      const output = uppercaseBytes(bytes(inPtr, inLen));
      if (output.length > outCap) return -2;
      new Uint8Array(memory.buffer, outPtr, output.length).set(output);
      return output.length;
    },
    render_examine_pass() {
      examineCases++;
      openExamination = null;
      return 1;
    },
    render_examine_fail(ordinal) {
      examineCases++;
      failures.push({ ordinal, kind: "examine" });
      openExamination = null;
      return 1;
    },
  },
});
memory = instance.exports.memory;
const declared = instance.exports.comply();

// --- report -----------------------------------------------------------------

console.log(`impl: Node ${process.version} String.prototype.toUpperCase (ICU ${process.versions.icu}, Unicode ${process.versions.unicode})`);
console.log(`cases: ${declared} declared (${equalityCases} equality, ${examineCases} examination)`);
if (failures.length === 0) {
  console.log("COMPLIANT: all cases pass");
  process.exit(0);
}
console.log(`NON-COMPLIANT: ${failures.length} failing case(s)`);
for (const f of failures.slice(0, 10)) {
  if (f.kind === "equal") {
    console.log(`  case ${f.ordinal}: input=${JSON.stringify(f.input.toString("latin1"))}`);
    console.log(`    expected ${f.expected.toString("hex")}`);
    console.log(`    actual   ${f.actual.toString("hex")}`);
  } else {
    console.log(`  case ${f.ordinal}: ${f.kind} failed`);
  }
}
process.exit(1);
