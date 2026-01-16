(module $Hello
  ;; Memory must be exported with name "memory"
  ;; At least 3 pages needed: input at 0x10000, output at 0x20000
  (memory (export "memory") 3)

  ;; Required globals for qip integration
  (global $input_ptr (export "input_ptr") i32 (i32.const 0x10000))
  (global $input_cap (export "input_cap") i32 (i32.const 0x10000))
  (global $output_ptr (export "output_ptr") i32 (i32.const 0x20000))
  (global $output_cap (export "output_cap") i32 (i32.const 0x10000))

  ;; Check if character is ASCII whitespace
  (func $is_whitespace (param $c i32) (result i32)
    (i32.or
      (i32.eq (local.get $c) (i32.const 32))   ;; space
      (i32.or
        (i32.eq (local.get $c) (i32.const 9))  ;; tab
        (i32.or
          (i32.eq (local.get $c) (i32.const 10))  ;; LF
          (i32.eq (local.get $c) (i32.const 13))  ;; CR
        )
      )
    )
  )

  ;; Required export: run(input_size) -> output_size
  ;; Input is at input_ptr, output goes to output_ptr
  ;; Return 0 for no output, or the length of output written
  (func $run (export "run") (param $input_size i32) (result i32)
    (local $i i32)
    (local $out_pos i32)
    (local $is_blank i32)
    (local $c i32)

    ;; Check if input is blank (empty or all whitespace)
    (local.set $is_blank (i32.const 1))
    (if (i32.gt_u (local.get $input_size) (i32.const 0))
      (then
        (block $break
          (loop $continue
            (br_if $break (i32.ge_u (local.get $i) (local.get $input_size)))
            (local.set $c (i32.load8_u (i32.add (global.get $input_ptr) (local.get $i))))
            (if (i32.eqz (call $is_whitespace (local.get $c)))
              (then
                (local.set $is_blank (i32.const 0))
                (br $break)
              )
            )
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $continue)
          )
        )
      )
    )

    ;; Write "Hello, World" as i64 + i32 (always write the default first)
    ;; "Hello, W" as i64 (little-endian: 0x57202c6f6c6c6548)
    (i64.store (global.get $output_ptr) (i64.const 0x57202c6f6c6c6548))
    ;; "orld" as i32 (little-endian: 0x646c726f)
    (i32.store (i32.add (global.get $output_ptr) (i32.const 8)) (i32.const 0x646c726f))
    (local.set $out_pos (i32.const 12))

    ;; If input is not blank, overwrite after "Hello, "
    (if (i32.eqz (local.get $is_blank))
      (then
        ;; Copy input starting at position 7 (after "Hello, ")
        (local.set $i (i32.const 0))
        (local.set $out_pos (i32.const 7))
        (block $break_copy
          (loop $continue_copy
            (br_if $break_copy (i32.ge_u (local.get $i) (local.get $input_size)))
            (i32.store8
              (i32.add (global.get $output_ptr) (local.get $out_pos))
              (i32.load8_u (i32.add (global.get $input_ptr) (local.get $i))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (local.set $out_pos (i32.add (local.get $out_pos) (i32.const 1)))
            (br $continue_copy)
          )
        )
      )
    )

    ;; Return output length
    (local.get $out_pos)
  )
)
