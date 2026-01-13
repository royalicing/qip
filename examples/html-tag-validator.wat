(module $HTMLTagValidator
  (memory (export "memory") 3)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0x10000))
  (global $input_cap (export "input_cap") i32 (i32.const 0x10000))
  (global $output_ptr (export "output_ptr") i32 (i32.const 0x20000))
  (global $output_cap (export "output_cap") i32 (i32.const 0x10000))

  ;; Check if character is lowercase letter (a-z)
  (func $is_lowercase (param $c i32) (result i32)
    (i32.and
      (i32.ge_u (local.get $c) (i32.const 97))   ;; a
      (i32.le_u (local.get $c) (i32.const 122))) ;; z
  )

  ;; Check if character is uppercase letter (A-Z)
  (func $is_uppercase (param $c i32) (result i32)
    (i32.and
      (i32.ge_u (local.get $c) (i32.const 65))   ;; A
      (i32.le_u (local.get $c) (i32.const 90)))  ;; Z
  )

  ;; Check if character is digit (0-9)
  (func $is_digit (param $c i32) (result i32)
    (i32.and
      (i32.ge_u (local.get $c) (i32.const 48))  ;; 0
      (i32.le_u (local.get $c) (i32.const 57))) ;; 9
  )

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

  ;; Write string to output
  (func $write_output (param $str_offset i32) (param $str_len i32) (result i32)
    (local $i i32)
    (loop $continue
      (br_if $continue (i32.ge_u (local.get $i) (local.get $str_len)))
      (i32.store8
        (i32.add (global.get $output_ptr) (local.get $i))
        (i32.load8_u (i32.add (local.get $str_offset) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $continue)
    )
    (local.get $str_len)
  )

  ;; Check if tag is a built-in HTML5 element
  ;; For simplicity, we assume any tag without a hyphen is built-in
  ;; A complete implementation would maintain a list of all HTML5 elements
  (func $is_builtin (param $start i32) (param $len i32) (result i32)
    (i32.const 1)
  )

  ;; Returns output describing tag type: "builtin", "custom", or "invalid"
  (func $run (export "run") (param $input_size i32) (result i32)
    (local $start i32)
    (local $end i32)
    (local $len i32)
    (local $i i32)
    (local $char i32)
    (local $has_hyphen i32)
    (local $first_char i32)
    (local $last_char i32)

    ;; Trim leading whitespace
    (local.set $start (i32.const 0))
    (block $break_leading
      (loop $continue_leading
        (br_if $break_leading (i32.ge_u (local.get $start) (local.get $input_size)))
        (local.set $char (i32.load8_u (i32.add (global.get $input_ptr) (local.get $start))))
        (br_if $break_leading (i32.eqz (call $is_whitespace (local.get $char))))
        (local.set $start (i32.add (local.get $start) (i32.const 1)))
        (br $continue_leading)
      )
    )

    ;; Trim trailing whitespace
    (local.set $end (local.get $input_size))
    (block $break_trailing
      (loop $continue_trailing
        (br_if $break_trailing (i32.le_u (local.get $end) (local.get $start)))
        (local.set $char (i32.load8_u (i32.add (global.get $input_ptr) (i32.sub (local.get $end) (i32.const 1)))))
        (br_if $break_trailing (i32.eqz (call $is_whitespace (local.get $char))))
        (local.set $end (i32.sub (local.get $end) (i32.const 1)))
        (br $continue_trailing)
      )
    )

    (local.set $len (i32.sub (local.get $end) (local.get $start)))

    ;; Empty tag name is invalid
    (if (i32.eq (local.get $len) (i32.const 0))
      (then
        (i32.store8 (global.get $output_ptr) (i32.const 105)) ;; i
        (i32.store8 (i32.add (global.get $output_ptr) (i32.const 1)) (i32.const 110)) ;; n
        (i32.store8 (i32.add (global.get $output_ptr) (i32.const 2)) (i32.const 118)) ;; v
        (i32.store8 (i32.add (global.get $output_ptr) (i32.const 3)) (i32.const 97)) ;; a
        (i32.store8 (i32.add (global.get $output_ptr) (i32.const 4)) (i32.const 108)) ;; l
        (i32.store8 (i32.add (global.get $output_ptr) (i32.const 5)) (i32.const 105)) ;; i
        (i32.store8 (i32.add (global.get $output_ptr) (i32.const 6)) (i32.const 100)) ;; d
        (return (i32.const 7))
      )
    )

    ;; Get first and last character
    (local.set $first_char (i32.load8_u (i32.add (global.get $input_ptr) (local.get $start))))
    (local.set $last_char (i32.load8_u (i32.add (global.get $input_ptr) (i32.sub (local.get $end) (i32.const 1)))))

    ;; First character must be lowercase ASCII letter
    (if (i32.eqz (call $is_lowercase (local.get $first_char)))
      (then
        (i32.store8 (global.get $output_ptr) (i32.const 105)) ;; i
        (i32.store8 (i32.add (global.get $output_ptr) (i32.const 1)) (i32.const 110)) ;; n
        (i32.store8 (i32.add (global.get $output_ptr) (i32.const 2)) (i32.const 118)) ;; v
        (i32.store8 (i32.add (global.get $output_ptr) (i32.const 3)) (i32.const 97)) ;; a
        (i32.store8 (i32.add (global.get $output_ptr) (i32.const 4)) (i32.const 108)) ;; l
        (i32.store8 (i32.add (global.get $output_ptr) (i32.const 5)) (i32.const 105)) ;; i
        (i32.store8 (i32.add (global.get $output_ptr) (i32.const 6)) (i32.const 100)) ;; d
        (return (i32.const 7))
      )
    )

    ;; Check all characters and look for hyphen
    (local.set $i (local.get $start))
    (block $break
      (loop $continue
        (br_if $break (i32.ge_u (local.get $i) (local.get $end)))
        (local.set $char (i32.load8_u (i32.add (global.get $input_ptr) (local.get $i))))

        ;; Check if hyphen
        (if (i32.eq (local.get $char) (i32.const 45))
          (then
            (local.set $has_hyphen (i32.const 1))
          )
        )

        ;; Valid characters: lowercase, digit, hyphen, dot, underscore
        (if (i32.eqz
          (i32.or
            (call $is_lowercase (local.get $char))
            (i32.or
              (call $is_digit (local.get $char))
              (i32.or
                (i32.eq (local.get $char) (i32.const 45))  ;; hyphen
                (i32.or
                  (i32.eq (local.get $char) (i32.const 46))  ;; dot
                  (i32.eq (local.get $char) (i32.const 95))  ;; underscore
                )
              )
            )
          ))
          (then
            (i32.store8 (global.get $output_ptr) (i32.const 105)) ;; i
            (i32.store8 (i32.add (global.get $output_ptr) (i32.const 1)) (i32.const 110)) ;; n
            (i32.store8 (i32.add (global.get $output_ptr) (i32.const 2)) (i32.const 118)) ;; v
            (i32.store8 (i32.add (global.get $output_ptr) (i32.const 3)) (i32.const 97)) ;; a
            (i32.store8 (i32.add (global.get $output_ptr) (i32.const 4)) (i32.const 108)) ;; l
            (i32.store8 (i32.add (global.get $output_ptr) (i32.const 5)) (i32.const 105)) ;; i
            (i32.store8 (i32.add (global.get $output_ptr) (i32.const 6)) (i32.const 100)) ;; d
            (return (i32.const 7))
          )
        )

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $continue)
      )
    )

    ;; If contains hyphen, it's a custom element
    (if (local.get $has_hyphen)
      (then
        ;; Cannot start with hyphen (already checked first char is letter)
        ;; Cannot end with hyphen
        (if (i32.eq (local.get $last_char) (i32.const 45))
          (then
            (i32.store8 (global.get $output_ptr) (i32.const 105)) ;; i
            (i32.store8 (i32.add (global.get $output_ptr) (i32.const 1)) (i32.const 110)) ;; n
            (i32.store8 (i32.add (global.get $output_ptr) (i32.const 2)) (i32.const 118)) ;; v
            (i32.store8 (i32.add (global.get $output_ptr) (i32.const 3)) (i32.const 97)) ;; a
            (i32.store8 (i32.add (global.get $output_ptr) (i32.const 4)) (i32.const 108)) ;; l
            (i32.store8 (i32.add (global.get $output_ptr) (i32.const 5)) (i32.const 105)) ;; i
            (i32.store8 (i32.add (global.get $output_ptr) (i32.const 6)) (i32.const 100)) ;; d
            (return (i32.const 7))
          )
        )

        ;; Valid custom element
        (i32.store8 (global.get $output_ptr) (i32.const 99)) ;; c
        (i32.store8 (i32.add (global.get $output_ptr) (i32.const 1)) (i32.const 117)) ;; u
        (i32.store8 (i32.add (global.get $output_ptr) (i32.const 2)) (i32.const 115)) ;; s
        (i32.store8 (i32.add (global.get $output_ptr) (i32.const 3)) (i32.const 116)) ;; t
        (i32.store8 (i32.add (global.get $output_ptr) (i32.const 4)) (i32.const 111)) ;; o
        (i32.store8 (i32.add (global.get $output_ptr) (i32.const 5)) (i32.const 109)) ;; m
        (return (i32.const 6))
      )
    )

    ;; No hyphen - check if it's a built-in element
    ;; For now, assume it's built-in if valid (simplified)
    (i32.store8 (global.get $output_ptr) (i32.const 98)) ;; b
    (i32.store8 (i32.add (global.get $output_ptr) (i32.const 1)) (i32.const 117)) ;; u
    (i32.store8 (i32.add (global.get $output_ptr) (i32.const 2)) (i32.const 105)) ;; i
    (i32.store8 (i32.add (global.get $output_ptr) (i32.const 3)) (i32.const 108)) ;; l
    (i32.store8 (i32.add (global.get $output_ptr) (i32.const 4)) (i32.const 116)) ;; t
    (i32.store8 (i32.add (global.get $output_ptr) (i32.const 5)) (i32.const 105)) ;; i
    (i32.store8 (i32.add (global.get $output_ptr) (i32.const 6)) (i32.const 110)) ;; n
    (i32.const 7)
  )
)
