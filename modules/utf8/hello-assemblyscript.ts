// hello-assemblyscript.ts - qip-compatible WebAssembly module in AssemblyScript

const INPUT_PTR: i32 = 0x10000;
const INPUT_CAP: i32 = 0x10000;
const OUTPUT_PTR: i32 = 0x20000;
const OUTPUT_CAP: i32 = 0x10000;

const PREFIX = [72, 101, 108, 108, 111, 44, 32]; // "Hello, "
const DEFAULT_NAME = [87, 111, 114, 108, 100]; // "World"

export function input_ptr(): i32 {
  return INPUT_PTR;
}

export function input_utf8_cap(): i32 {
  return INPUT_CAP;
}

export function output_ptr(): i32 {
  return OUTPUT_PTR;
}

export function output_utf8_cap(): i32 {
  return OUTPUT_CAP;
}

export function render(input_size: i32): i32 {
  // Copy "Hello, " prefix into output
  for (let i: i32 = 0; i < PREFIX.length; i++) {
    store<u8>(OUTPUT_PTR + i, <u8>PREFIX[i]);
  }

  if (input_size > 0) {
    // Copy input bytes after prefix
    for (let i: i32 = 0; i < input_size; i++) {
      const b = load<u8>(INPUT_PTR + i);
      store<u8>(OUTPUT_PTR + PREFIX.length + i, b);
    }
    return PREFIX.length + input_size;
  }

  // No input: copy "World"
  for (let i: i32 = 0; i < DEFAULT_NAME.length; i++) {
    store<u8>(OUTPUT_PTR + PREFIX.length + i, <u8>DEFAULT_NAME[i]);
  }
  return PREFIX.length + DEFAULT_NAME.length;
}
