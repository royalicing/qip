(module $E164
  (memory (export "memory") 3)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0x10000))
  (global $input_cap (export "input_cap") i32 (i32.const 0x10000))
  (global $output_ptr (export "output_ptr") i32 (i32.const 0x20000))
  (global $output_utf8_cap (export "output_utf8_cap") i32 (i32.const 0x10000))
  (func $run (export "run") (param $input_size i32) (result i32)
    (local $input_idx i32)
    (local $output_idx i32)
    (local $char i32)
    (local $is_first i32)

    ;; Return 0 if input is empty
    (if (i32.eq (local.get $input_size) (i32.const 0))
      (then (return (i32.const 0)))
    )

    ;; Initialize: is_first = 1 (true)
    (local.set $is_first (i32.const 1))

    ;; Loop through each input character
    (block $break
      (loop $continue
        ;; Break if we've processed all input
        (br_if $break (i32.ge_u (local.get $input_idx) (local.get $input_size)))

        ;; Load current character from input
        (local.set $char
          (i32.load8_u
            (i32.add (global.get $input_ptr) (local.get $input_idx))))

        ;; Check if character is a digit ('0'-'9' = ASCII 48-57)
        (if (i32.and
              (i32.ge_u (local.get $char) (i32.const 48))
              (i32.le_u (local.get $char) (i32.const 57)))
          (then
            ;; It's a digit - copy to output
            (i32.store8
              (i32.add (global.get $output_ptr) (local.get $output_idx))
              (local.get $char))
            (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))
            (local.set $is_first (i32.const 0))
          )
          (else
            ;; Check if it's '+' (ASCII 43) and we're at the start
            (if (i32.and
                  (i32.eq (local.get $char) (i32.const 43))
                  (local.get $is_first))
              (then
                ;; Copy the '+' to output
                (i32.store8
                  (i32.add (global.get $output_ptr) (local.get $output_idx))
                  (local.get $char))
                (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))
                (local.set $is_first (i32.const 0))
              )
            )
          )
        )

        ;; Move to next input character
        (local.set $input_idx (i32.add (local.get $input_idx) (i32.const 1)))
        (br $continue)
      )
    )

    ;; Return the output size
    (local.get $output_idx)
  )
)
