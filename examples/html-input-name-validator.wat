(module $HTMLInputNameValidator
  (memory (export "memory") 3)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0x10000))
  (global $input_utf8_cap (export "input_utf8_cap") i32 (i32.const 0x10000))
  (global $output_ptr (export "output_ptr") i32 (i32.const 0x20000))
  (global $output_utf8_cap (export "output_utf8_cap") i32 (i32.const 0x10000))

  ;; Check if character is ASCII whitespace
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

  ;; Check if character is a letter (a-z or A-Z)
  (func $is_letter (param $c i32) (result i32)
    (i32.or
      (i32.and
        (i32.ge_u (local.get $c) (i32.const 97))   ;; a
        (i32.le_u (local.get $c) (i32.const 122))) ;; z
      (i32.and
        (i32.ge_u (local.get $c) (i32.const 65))   ;; A
        (i32.le_u (local.get $c) (i32.const 90)))  ;; Z
    )
  )

  ;; Check if character is a digit (0-9)
  (func $is_digit (param $c i32) (result i32)
    (i32.and
      (i32.ge_u (local.get $c) (i32.const 48))  ;; 0
      (i32.le_u (local.get $c) (i32.const 57))) ;; 9
  )

  ;; Check if character is valid in a practical input name
  ;; Allows: letters, digits, hyphen, underscore, dot, square brackets, colon
  ;; These are safe for form submission and common server-side frameworks
  (func $is_valid_char (param $c i32) (result i32)
    (i32.or
      (call $is_letter (local.get $c))
      (i32.or
        (call $is_digit (local.get $c))
        (i32.or
          (i32.eq (local.get $c) (i32.const 45))  ;; hyphen -
          (i32.or
            (i32.eq (local.get $c) (i32.const 95))  ;; underscore _
            (i32.or
              (i32.eq (local.get $c) (i32.const 46))  ;; dot .
              (i32.or
                (i32.eq (local.get $c) (i32.const 91))  ;; left bracket [
                (i32.or
                  (i32.eq (local.get $c) (i32.const 93))  ;; right bracket ]
                  (i32.eq (local.get $c) (i32.const 58))  ;; colon :
                )
              )
            )
          )
        )
      )
    )
  )

  ;; Returns: length of valid trimmed input name, or 0 if invalid
  ;; Outputs the trimmed input name to output buffer
  ;; Checks for characters that are safe for form submission
  ;; Avoids: whitespace, =, &, ?, #, /, and other URL-special characters
  ;; Leading and trailing whitespace is trimmed
  (func $run (export "run") (param $input_size i32) (result i32)
    (local $start i32)
    (local $end i32)
    (local $len i32)
    (local $i i32)
    (local $current_char i32)

    ;; Empty name is invalid
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

    ;; Check all characters in trimmed range
    (local.set $i (local.get $start))
    (block $break
      (loop $continue
        (br_if $break (i32.ge_u (local.get $i) (local.get $end)))

        (local.set $current_char (i32.load8_u (i32.add (global.get $input_ptr) (local.get $i))))

        ;; Character must be valid
        (if (i32.eqz (call $is_valid_char (local.get $current_char)))
          (then (return (i32.const 0)))
        )

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $continue)
      )
    )

    ;; All checks passed - copy trimmed content to output
    (local.set $len (i32.sub (local.get $end) (local.get $start)))
    (local.set $i (i32.const 0))
    (block $break_copy
      (loop $copy
        (br_if $break_copy (i32.ge_u (local.get $i) (local.get $len)))
        (i32.store8
          (i32.add (global.get $output_ptr) (local.get $i))
          (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $start) (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $copy)
      )
    )
    (local.get $len)
  )
)
