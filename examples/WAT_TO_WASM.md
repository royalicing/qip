# WAT to WASM Converter Example

This example demonstrates a WebAssembly Text (WAT) to WebAssembly Binary (WASM) converter written in C that runs as a qip module.

## Features

- **Stack-only instructions**: Supports only stack-based WebAssembly operations
- **No memory operations**: Does not support memory load/store instructions
- **No locals**: Does not support local variables
- **No calls**: Does not support function calls, imports, or exports (except the generated calc function)

## Supported Instructions

### i32 Constant
- `i32.const` - Push a 32-bit integer constant onto the stack

### i32 Arithmetic Operations
- `i32.add` - Add two i32 values
- `i32.sub` - Subtract two i32 values  
- `i32.mul` - Multiply two i32 values
- `i32.div_s` - Signed division
- `i32.div_u` - Unsigned division
- `i32.rem_s` - Signed remainder
- `i32.rem_u` - Unsigned remainder

### i32 Bitwise Operations
- `i32.and` - Bitwise AND
- `i32.or` - Bitwise OR
- `i32.xor` - Bitwise XOR
- `i32.shl` - Shift left
- `i32.shr_s` - Signed shift right
- `i32.shr_u` - Unsigned shift right
- `i32.rotl` - Rotate left
- `i32.rotr` - Rotate right
- `i32.clz` - Count leading zeros
- `i32.ctz` - Count trailing zeros
- `i32.popcnt` - Count number of 1 bits

### i32 Comparison Operations
- `i32.eqz` - Test if zero
- `i32.eq` - Equal
- `i32.ne` - Not equal
- `i32.lt_s` - Signed less than
- `i32.lt_u` - Unsigned less than
- `i32.gt_s` - Signed greater than
- `i32.gt_u` - Unsigned greater than
- `i32.le_s` - Signed less than or equal
- `i32.le_u` - Unsigned less than or equal
- `i32.ge_s` - Signed greater than or equal
- `i32.ge_u` - Unsigned greater than or equal

### f32 Constant
- `f32.const` - Push a 32-bit floating point constant onto the stack

### f32 Arithmetic Operations
- `f32.add` - Add two f32 values
- `f32.sub` - Subtract two f32 values
- `f32.mul` - Multiply two f32 values
- `f32.div` - Divide two f32 values
- `f32.min` - Minimum of two f32 values
- `f32.max` - Maximum of two f32 values
- `f32.sqrt` - Square root
- `f32.abs` - Absolute value
- `f32.neg` - Negate
- `f32.copysign` - Copy sign from one value to another

### f32 Rounding Operations
- `f32.ceil` - Round up to integer
- `f32.floor` - Round down to integer
- `f32.trunc` - Round towards zero
- `f32.nearest` - Round to nearest integer

### f32 Comparison Operations
- `f32.eq` - Equal
- `f32.ne` - Not equal
- `f32.lt` - Less than
- `f32.gt` - Greater than
- `f32.le` - Less than or equal
- `f32.ge` - Greater than or equal

### Stack Operations
- `drop` - Drop the top value from the stack
- `select` - Select one of two values based on a condition
- `nop` - No operation
- `unreachable` - Trap unconditionally
- `return` - Return from function

## Usage

### Basic Example

```bash
echo "(i32.const 5) (i32.const 3) (i32.add)" | qip run examples/wat-to-wasm.wasm > result.wasm
```

This will generate a **binary WASM module** that exports a function called `calc` which returns the result of `5 + 3 = 8`. The output is binary WebAssembly bytecode, not text.

### Complex Example

```bash
# Calculate (5 + 3) * 2 = 16
echo "(i32.const 5) (i32.const 3) (i32.add) (i32.const 2) (i32.mul)" | qip run examples/wat-to-wasm.wasm > calc.wasm
```

### f32 Example

```bash
# Calculate 3.5 + 2.25 = 5.75
echo "(f32.const 3.5) (f32.const 2.25) (f32.add)" | qip run examples/wat-to-wasm.wasm > float-calc.wasm
```

### Running the Generated WASM

You can run the generated WASM using Node.js:

```javascript
const fs = require('fs');
const wasmBuffer = fs.readFileSync('result.wasm');

WebAssembly.instantiate(wasmBuffer).then(result => {
    const value = result.instance.exports.calc();
    console.log('Result:', value);
});
```

## Output Format

The converter generates a minimal WASM module with:
- A single function type: `() -> i32`
- A single function implementing your calculation
- An export named `calc` for the function
- No memory, globals, or other sections

## Building

```bash
make examples/wat-to-wasm.wasm
```

This uses clang to compile the C source to WebAssembly.

## Implementation Notes

- The parser skips whitespace and comments (both line comments `;;` and block comments `(; ;)`)
- Instructions must be in S-expression form: `(instruction arg1 arg2)`
- Numbers are parsed as signed integers
- The output is a complete, valid WASM module ready to run
- All instructions operate only on the value stack
- The generated function always returns an i32 value
