(module $WasmToJS
  (memory (export "memory") 4)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0x10000))
  (global $input_cap (export "input_cap") i32 (i32.const 0x10000))
  (global $output_ptr (export "output_ptr") i32 (i32.const 0x20000))
  (global $output_cap (export "output_cap") i32 (i32.const 0x10000))

  ;; Base64 encoding table
  (data (i32.const 0x1000) "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

  ;; Get base64 character for 6-bit value
  (func $base64_char (param $value i32) (result i32)
    (i32.load8_u (i32.add (i32.const 0x1000) (local.get $value)))
  )

  ;; Encode 3 bytes to 4 base64 characters
  (func $encode_triplet (param $b1 i32) (param $b2 i32) (param $b3 i32) (param $out_pos i32)
    (local $v1 i32)
    (local $v2 i32)
    (local $v3 i32)
    (local $v4 i32)

    ;; First 6 bits from b1
    (local.set $v1 (i32.shr_u (local.get $b1) (i32.const 2)))

    ;; Last 2 bits of b1, first 4 bits of b2
    (local.set $v2 (i32.or
      (i32.shl (i32.and (local.get $b1) (i32.const 3)) (i32.const 4))
      (i32.shr_u (local.get $b2) (i32.const 4))
    ))

    ;; Last 4 bits of b2, first 2 bits of b3
    (local.set $v3 (i32.or
      (i32.shl (i32.and (local.get $b2) (i32.const 15)) (i32.const 2))
      (i32.shr_u (local.get $b3) (i32.const 6))
    ))

    ;; Last 6 bits of b3
    (local.set $v4 (i32.and (local.get $b3) (i32.const 63)))

    ;; Write base64 characters
    (i32.store8
      (i32.add (global.get $output_ptr) (local.get $out_pos))
      (call $base64_char (local.get $v1)))
    (i32.store8
      (i32.add (global.get $output_ptr) (i32.add (local.get $out_pos) (i32.const 1)))
      (call $base64_char (local.get $v2)))
    (i32.store8
      (i32.add (global.get $output_ptr) (i32.add (local.get $out_pos) (i32.const 2)))
      (call $base64_char (local.get $v3)))
    (i32.store8
      (i32.add (global.get $output_ptr) (i32.add (local.get $out_pos) (i32.const 3)))
      (call $base64_char (local.get $v4)))
  )

  ;; Write string to output
  (func $write_string (param $str_ptr i32) (param $str_len i32) (param $out_pos i32) (result i32)
    (local $i i32)
    (block $break
      (loop $continue
        (br_if $break (i32.ge_u (local.get $i) (local.get $str_len)))
        (i32.store8
          (i32.add (global.get $output_ptr) (i32.add (local.get $out_pos) (local.get $i)))
          (i32.load8_u (i32.add (local.get $str_ptr) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $continue)
      )
    )
    (i32.add (local.get $out_pos) (local.get $str_len))
  )

  ;; JavaScript template parts
  (data (i32.const 0x2000) "export async function run(input) {\n")
  (data (i32.const 0x2100) "  const wasmBytes = Uint8Array.from(atob('")
  (data (i32.const 0x2200) "'), c => c.charCodeAt(0));\n")
  (data (i32.const 0x2300) "  const module = await WebAssembly.compile(wasmBytes);\n")
  (data (i32.const 0x2400) "  const instance = await WebAssembly.instantiate(module);\n")
  (data (i32.const 0x2500) "  const exports = instance.exports;\n")
  (data (i32.const 0x2600) "  const memory = exports.memory;\n")
  (data (i32.const 0x2700) "  const inputPtr = exports.input_ptr.value;\n")
  (data (i32.const 0x2800) "  const outputPtr = exports.output_ptr.value;\n")
  (data (i32.const 0x2900) "  const encoder = new TextEncoder();\n")
  (data (i32.const 0x2A00) "  const inputBytes = encoder.encode(input);\n")
  (data (i32.const 0x2B00) "  new Uint8Array(memory.buffer, inputPtr, inputBytes.length).set(inputBytes);\n")
  (data (i32.const 0x2C00) "  const outputLen = exports.run(inputBytes.length);\n")
  (data (i32.const 0x2D00) "  if (outputLen === 0) return '';\n")
  (data (i32.const 0x2E00) "  const decoder = new TextDecoder();\n")
  (data (i32.const 0x2F00) "  return decoder.decode(new Uint8Array(memory.buffer, outputPtr, outputLen));\n")
  (data (i32.const 0x3000) "}\n")

  (func $run (export "run") (param $input_size i32) (result i32)
    (local $out_pos i32)
    (local $in_pos i32)
    (local $b1 i32)
    (local $b2 i32)
    (local $b3 i32)
    (local $remaining i32)

    ;; Write JavaScript header
    (local.set $out_pos (call $write_string (i32.const 0x2000) (i32.const 35) (local.get $out_pos)))
    (local.set $out_pos (call $write_string (i32.const 0x2100) (i32.const 42) (local.get $out_pos)))

    ;; Base64 encode the WASM bytes
    (local.set $remaining (local.get $input_size))
    (block $break_encode
      (loop $continue_encode
        (br_if $break_encode (i32.lt_u (local.get $remaining) (i32.const 3)))

        ;; Read 3 bytes
        (local.set $b1 (i32.load8_u (i32.add (global.get $input_ptr) (local.get $in_pos))))
        (local.set $b2 (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $in_pos) (i32.const 1)))))
        (local.set $b3 (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $in_pos) (i32.const 2)))))

        ;; Encode to base64
        (call $encode_triplet (local.get $b1) (local.get $b2) (local.get $b3) (local.get $out_pos))

        (local.set $in_pos (i32.add (local.get $in_pos) (i32.const 3)))
        (local.set $out_pos (i32.add (local.get $out_pos) (i32.const 4)))
        (local.set $remaining (i32.sub (local.get $remaining) (i32.const 3)))
        (br $continue_encode)
      )
    )

    ;; Handle remaining bytes (1 or 2)
    (if (i32.eq (local.get $remaining) (i32.const 2))
      (then
        (local.set $b1 (i32.load8_u (i32.add (global.get $input_ptr) (local.get $in_pos))))
        (local.set $b2 (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $in_pos) (i32.const 1)))))
        (local.set $b3 (i32.const 0))
        (call $encode_triplet (local.get $b1) (local.get $b2) (local.get $b3) (local.get $out_pos))
        ;; Replace last char with =
        (i32.store8 (i32.add (global.get $output_ptr) (i32.add (local.get $out_pos) (i32.const 3))) (i32.const 61))
        (local.set $out_pos (i32.add (local.get $out_pos) (i32.const 4)))
      )
    )
    (if (i32.eq (local.get $remaining) (i32.const 1))
      (then
        (local.set $b1 (i32.load8_u (i32.add (global.get $input_ptr) (local.get $in_pos))))
        (local.set $b2 (i32.const 0))
        (local.set $b3 (i32.const 0))
        (call $encode_triplet (local.get $b1) (local.get $b2) (local.get $b3) (local.get $out_pos))
        ;; Replace last two chars with ==
        (i32.store8 (i32.add (global.get $output_ptr) (i32.add (local.get $out_pos) (i32.const 2))) (i32.const 61))
        (i32.store8 (i32.add (global.get $output_ptr) (i32.add (local.get $out_pos) (i32.const 3))) (i32.const 61))
        (local.set $out_pos (i32.add (local.get $out_pos) (i32.const 4)))
      )
    )

    ;; Write rest of JavaScript
    (local.set $out_pos (call $write_string (i32.const 0x2200) (i32.const 27) (local.get $out_pos)))
    (local.set $out_pos (call $write_string (i32.const 0x2300) (i32.const 55) (local.get $out_pos)))
    (local.set $out_pos (call $write_string (i32.const 0x2400) (i32.const 58) (local.get $out_pos)))
    (local.set $out_pos (call $write_string (i32.const 0x2500) (i32.const 36) (local.get $out_pos)))
    (local.set $out_pos (call $write_string (i32.const 0x2600) (i32.const 33) (local.get $out_pos)))
    (local.set $out_pos (call $write_string (i32.const 0x2700) (i32.const 44) (local.get $out_pos)))
    (local.set $out_pos (call $write_string (i32.const 0x2800) (i32.const 46) (local.get $out_pos)))
    (local.set $out_pos (call $write_string (i32.const 0x2900) (i32.const 37) (local.get $out_pos)))
    (local.set $out_pos (call $write_string (i32.const 0x2A00) (i32.const 44) (local.get $out_pos)))
    (local.set $out_pos (call $write_string (i32.const 0x2B00) (i32.const 78) (local.get $out_pos)))
    (local.set $out_pos (call $write_string (i32.const 0x2C00) (i32.const 52) (local.get $out_pos)))
    (local.set $out_pos (call $write_string (i32.const 0x2D00) (i32.const 34) (local.get $out_pos)))
    (local.set $out_pos (call $write_string (i32.const 0x2E00) (i32.const 37) (local.get $out_pos)))
    (local.set $out_pos (call $write_string (i32.const 0x2F00) (i32.const 78) (local.get $out_pos)))
    (local.set $out_pos (call $write_string (i32.const 0x3000) (i32.const 2) (local.get $out_pos)))

    (local.get $out_pos)
  )
)
