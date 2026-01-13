(module $CSSClassValidator
  (memory (export "memory") 3)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0x10000))
  (global $input_cap (export "input_cap") i32 (i32.const 0x10000))

  ;; Check if character is ASCII whitespace (space, tab, LF, FF, CR)
  ;; Per HTML5 spec, class attributes cannot contain ASCII whitespace
  (func $is_whitespace (param $c i32) (result i32)
    (i32.or
      (i32.eq (local.get $c) (i32.const 32))  ;; space
      (i32.or
        (i32.eq (local.get $c) (i32.const 9))   ;; tab
        (i32.or
          (i32.eq (local.get $c) (i32.const 10))  ;; LF
          (i32.or
            (i32.eq (local.get $c) (i32.const 12))  ;; FF
            (i32.eq (local.get $c) (i32.const 13))  ;; CR
          )
        )
      )
    )
  )

  ;; Returns: 1 if valid HTML class name, 0 if invalid
  ;; Per HTML5: class names can contain any character except ASCII whitespace
  ;; This allows Tailwind classes like: hover:text-red-500, w-1/2, text-[#000]
  ;; Leading and trailing whitespace is ignored
  (func $run (export "run") (param $input_size i32) (result i32)
    (local $start i32)
    (local $end i32)
    (local $i i32)
    (local $current_char i32)

    ;; Empty class name is invalid
    (if (i32.eq (local.get $input_size) (i32.const 0))
      (then (return (i32.const 0)))
    )

    ;; Trim leading whitespace
    (local.set $start (i32.const 0))
    (block $break_leading
      (loop $continue_leading
        (br_if $break_leading (i32.ge_u (local.get $start) (local.get $input_size)))
        (local.set $current_char (i32.load8_u (i32.add (global.get $input_ptr) (local.get $start))))
        (br_if $break_leading (i32.eqz (call $is_whitespace (local.get $current_char))))
        (local.set $start (i32.add (local.get $start) (i32.const 1)))
        (br $continue_leading)
      )
    )

    ;; Trim trailing whitespace
    (local.set $end (local.get $input_size))
    (block $break_trailing
      (loop $continue_trailing
        (br_if $break_trailing (i32.le_u (local.get $end) (local.get $start)))
        (local.set $current_char (i32.load8_u (i32.add (global.get $input_ptr) (i32.sub (local.get $end) (i32.const 1)))))
        (br_if $break_trailing (i32.eqz (call $is_whitespace (local.get $current_char))))
        (local.set $end (i32.sub (local.get $end) (i32.const 1)))
        (br $continue_trailing)
      )
    )

    ;; If all whitespace or empty after trimming, invalid
    (if (i32.ge_u (local.get $start) (local.get $end))
      (then (return (i32.const 0)))
    )

    ;; Check all characters in trimmed range - none can be ASCII whitespace
    (local.set $i (local.get $start))
    (block $break
      (loop $continue
        (br_if $break (i32.ge_u (local.get $i) (local.get $end)))

        (local.set $current_char (i32.load8_u (i32.add (global.get $input_ptr) (local.get $i))))

        ;; If character is whitespace, invalid
        (if (call $is_whitespace (local.get $current_char))
          (then (return (i32.const 0)))
        )

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $continue)
      )
    )

    ;; All checks passed - valid class name
    (i32.const 1)
  )
)
