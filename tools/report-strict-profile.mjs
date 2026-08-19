#!/usr/bin/env node

import { readdir, readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { validateWasmStrictProfile } from "../npm/qip-run/qip-run.mjs";

async function walk(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  entries.sort((a, b) => a.name.localeCompare(b.name));
  const files = [];
  for (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await walk(path));
    else if (entry.isFile() && entry.name.endsWith(".wasm")) files.push(path);
    else if (entry.isSymbolicLink()) {
      const info = await stat(path);
      if (info.isFile() && entry.name.endsWith(".wasm")) files.push(path);
      else if (info.isDirectory()) files.push(...await walk(path));
    }
  }
  return files;
}

function parseArgs(argv) {
  const options = { root: "components", maxMemory: undefined };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--max-memory") options.maxMemory = argv[++index];
    else if (arg === "-h" || arg === "--help") {
      console.log("Usage: report-strict-profile.mjs [--max-memory <bytes>] [components-dir]");
      process.exit(0);
    } else if (arg.startsWith("-")) {
      throw new Error(`unknown option ${arg}`);
    } else {
      options.root = arg;
    }
  }
  if (!options.root) throw new Error("components directory must not be empty");
  return options;
}

const options = parseArgs(process.argv.slice(2));
const files = await walk(options.root);
if (files.length === 0) throw new Error(`No .wasm files found under ${options.root}/`);

let pass = 0;
let fail = 0;
for (const file of files) {
  try {
    const wasm = await readFile(file);
    validateWasmStrictProfile(wasm, { label: file, maxMemory: options.maxMemory });
    console.log(`PASS ${file}`);
    pass += 1;
  } catch (error) {
    console.log(`FAIL ${file}: ${error.message ?? error}`);
    fail += 1;
  }
}

console.log(`\npass=${pass} fail=${fail} total=${pass + fail}`);
