(module $CRC
  (memory (export "memory") 3)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0x10000))
  (global $input_cap (export "input_cap") i32 (i32.const 0x10000))
  (global $output_ptr (export "output_ptr") i32 (i32.const 0x20000))
  (;global $output_utf8_cap (export "output_utf8_cap") i32 (i32.const 0x10000);)
  (func $run (export "run") (param $input_size i32) (result i32)
    (local $ptr i32)
    (local $i i32)
    (local $c i32)
    (local.set $ptr (global.get $input_ptr))
    (i32.eq (local.get $input_size) (i32.const 0))
    (if
      (then
        (return (i32.const 0))
      )
    )
    (i32.const 4294967295)
    (local.set $c)
    (loop $EachByte
      (i32.xor
        (local.get $c)
        (i32.load8_u (i32.add (local.get $ptr) (local.get $i)))
      )
      (local.set $c)
      (i32.and
        (local.get $c)
        (i32.const 1)
      )
      (if (result i32)
        (then
          (i32.xor (i32.shr_u (local.get $c) (i32.const 1)) (i32.const 3988292384))
        )
        (else
          (i32.shr_u (local.get $c) (i32.const 1))
        )
      )
      (local.set $c)
      (i32.and
        (local.get $c)
        (i32.const 1)
      )
      (if (result i32)
        (then
          (i32.xor (i32.shr_u (local.get $c) (i32.const 1)) (i32.const 3988292384))
        )
        (else
          (i32.shr_u (local.get $c) (i32.const 1))
        )
      )
      (local.set $c)
      (i32.and
        (local.get $c)
        (i32.const 1)
      )
      (if (result i32)
        (then
          (i32.xor (i32.shr_u (local.get $c) (i32.const 1)) (i32.const 3988292384))
        )
        (else
          (i32.shr_u (local.get $c) (i32.const 1))
        )
      )
      (local.set $c)
      (i32.and
        (local.get $c)
        (i32.const 1)
      )
      (if (result i32)
        (then
          (i32.xor (i32.shr_u (local.get $c) (i32.const 1)) (i32.const 3988292384))
        )
        (else
          (i32.shr_u (local.get $c) (i32.const 1))
        )
      )
      (local.set $c)
      (i32.and
        (local.get $c)
        (i32.const 1)
      )
      (if (result i32)
        (then
          (i32.xor (i32.shr_u (local.get $c) (i32.const 1)) (i32.const 3988292384))
        )
        (else
          (i32.shr_u (local.get $c) (i32.const 1))
        )
      )
      (local.set $c)
      (i32.and
        (local.get $c)
        (i32.const 1)
      )
      (if (result i32)
        (then
          (i32.xor (i32.shr_u (local.get $c) (i32.const 1)) (i32.const 3988292384))
        )
        (else
          (i32.shr_u (local.get $c) (i32.const 1))
        )
      )
      (local.set $c)
      (i32.and
        (local.get $c)
        (i32.const 1)
      )
      (if (result i32)
        (then
          (i32.xor (i32.shr_u (local.get $c) (i32.const 1)) (i32.const 3988292384))
        )
        (else
          (i32.shr_u (local.get $c) (i32.const 1))
        )
      )
      (local.set $c)
      (i32.and
        (local.get $c)
        (i32.const 1)
      )
      (if (result i32)
        (then
          (i32.xor (i32.shr_u (local.get $c) (i32.const 1)) (i32.const 3988292384))
        )
        (else
          (i32.shr_u (local.get $c) (i32.const 1))
        )
      )
      (local.set $c)
      (i32.add (local.get $i) (i32.const 1))
      (local.set $i)
      (i32.lt_s (local.get $i) (local.get $input_size))
      (if
        (then
          (br $EachByte)
        )
      )
    )
    (i32.xor (local.get $c) (i32.const 4294967295))
  )
)
