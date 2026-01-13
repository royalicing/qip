(module $Trim
  (memory (export "memory") 3)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0x10000))
  (global $input_cap (export "input_cap") i32 (i32.const 0x10000))
  (global $output_ptr (export "output_ptr") i32 (i32.const 0x20000))
  (global $output_cap (export "output_cap") i32 (i32.const 0x10000))

  ;; Check if byte is whitespace (space, tab, newline, carriage return, form feed, vertical tab)
  (func $is_whitespace (param $byte i32) (result i32)
    (i32.or
      (i32.eq (local.get $byte) (i32.const 32))  ;; space
      (i32.or
        (i32.eq (local.get $byte) (i32.const 9))   ;; tab
        (i32.or
          (i32.eq (local.get $byte) (i32.const 10))  ;; newline
          (i32.or
            (i32.eq (local.get $byte) (i32.const 13))  ;; carriage return
            (i32.or
              (i32.eq (local.get $byte) (i32.const 12))  ;; form feed
              (i32.eq (local.get $byte) (i32.const 11))  ;; vertical tab
            )
          )
        )
      )
    )
  )

  (func $run (export "run") (param $input_size i32) (result i32)
    (local $start i32)
    (local $end i32)
    (local $byte i32)
    (local $i i32)
    (local $output_idx i32)

    ;; Return 0 if input is empty
    (if (i32.eq (local.get $input_size) (i32.const 0))
      (then (return (i32.const 0)))
    )

    ;; Find first non-whitespace character
    (local.set $start (i32.const 0))
    (block $break_start
      (loop $continue_start
        (br_if $break_start (i32.ge_u (local.get $start) (local.get $input_size)))
        (local.set $byte (i32.load8_u (i32.add (global.get $input_ptr) (local.get $start))))
        (br_if $break_start (i32.eqz (call $is_whitespace (local.get $byte))))
        (local.set $start (i32.add (local.get $start) (i32.const 1)))
        (br $continue_start)
      )
    )

    ;; If all whitespace, return empty
    (if (i32.ge_u (local.get $start) (local.get $input_size))
      (then (return (i32.const 0)))
    )

    ;; Find last non-whitespace character
    (local.set $end (i32.sub (local.get $input_size) (i32.const 1)))
    (block $break_end
      (loop $continue_end
        (br_if $break_end (i32.lt_u (local.get $end) (local.get $start)))
        (local.set $byte (i32.load8_u (i32.add (global.get $input_ptr) (local.get $end))))
        (br_if $break_end (i32.eqz (call $is_whitespace (local.get $byte))))
        (local.set $end (i32.sub (local.get $end) (i32.const 1)))
        (br $continue_end)
      )
    )

    ;; Copy trimmed content to output
    (local.set $i (local.get $start))
    (local.set $output_idx (i32.const 0))
    (loop $copy
      (i32.store8
        (i32.add (global.get $output_ptr) (local.get $output_idx))
        (i32.load8_u (i32.add (global.get $input_ptr) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))
      (br_if $copy (i32.le_u (local.get $i) (local.get $end)))
    )

    ;; Return trimmed size
    (local.get $output_idx)
  )
)
