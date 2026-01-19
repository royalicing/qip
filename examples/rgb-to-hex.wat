(module $RGBToHex
  (memory (export "memory") 4)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0x10000))
  (global $input_utf8_cap (export "input_utf8_cap") i32 (i32.const 0x10000))
  (global $output_ptr (export "output_ptr") i32 (i32.const 0x20000))
  (global $output_utf8_cap (export "output_utf8_cap") i32 (i32.const 0x10000))

  ;; Check if character is ASCII whitespace
  (func $is_whitespace (param $c i32) (result i32)
    (i32.or
      (i32.eq (local.get $c) (i32.const 32))
      (i32.or
        (i32.eq (local.get $c) (i32.const 9))
        (i32.or
          (i32.eq (local.get $c) (i32.const 10))
          (i32.or
            (i32.eq (local.get $c) (i32.const 12))
            (i32.eq (local.get $c) (i32.const 13))
          )
        )
      )
    )
  )

  ;; Check if character is a digit
  (func $is_digit (param $c i32) (result i32)
    (i32.and
      (i32.ge_u (local.get $c) (i32.const 48))  ;; '0'
      (i32.le_u (local.get $c) (i32.const 57))  ;; '9'
    )
  )

  ;; Parse a decimal number from input
  ;; Returns the number, or -1 if invalid
  ;; Updates the position parameter
  (func $parse_number (param $start i32) (param $end i32) (param $pos_ptr i32) (result i32)
    (local $pos i32)
    (local $num i32)
    (local $c i32)
    (local $has_digit i32)

    (local.set $pos (local.get $start))

    ;; Skip leading whitespace
    (block $break_ws
      (loop $continue_ws
        (br_if $break_ws (i32.ge_u (local.get $pos) (local.get $end)))
        (local.set $c (i32.load8_u (i32.add (global.get $input_ptr) (local.get $pos))))
        (br_if $break_ws (i32.eqz (call $is_whitespace (local.get $c))))
        (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
        (br $continue_ws)
      )
    )

    ;; Parse digits
    (block $break_digits
      (loop $continue_digits
        (br_if $break_digits (i32.ge_u (local.get $pos) (local.get $end)))
        (local.set $c (i32.load8_u (i32.add (global.get $input_ptr) (local.get $pos))))
        (br_if $break_digits (i32.eqz (call $is_digit (local.get $c))))

        (local.set $has_digit (i32.const 1))
        (local.set $num (i32.add
          (i32.mul (local.get $num) (i32.const 10))
          (i32.sub (local.get $c) (i32.const 48))
        ))
        (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
        (br $continue_digits)
      )
    )

    ;; If no digits found, return -1
    (if (i32.eqz (local.get $has_digit))
      (then
        (return (i32.const -1))
      )
    )

    ;; Update position
    (i32.store (local.get $pos_ptr) (local.get $pos))

    (local.get $num)
  )

  ;; Skip whitespace and comma
  (func $skip_separator (param $start i32) (param $end i32) (result i32)
    (local $pos i32)
    (local $c i32)
    (local $found_comma i32)

    (local.set $pos (local.get $start))

    ;; Skip whitespace and look for comma
    (block $break
      (loop $continue
        (br_if $break (i32.ge_u (local.get $pos) (local.get $end)))
        (local.set $c (i32.load8_u (i32.add (global.get $input_ptr) (local.get $pos))))

        (if (i32.eq (local.get $c) (i32.const 44))  ;; comma
          (then
            (local.set $found_comma (i32.const 1))
            (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
            (br $continue)
          )
        )

        (if (call $is_whitespace (local.get $c))
          (then
            (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
            (br $continue)
          )
        )

        (br $break)
      )
    )

    ;; Must have found a comma
    (if (i32.eqz (local.get $found_comma))
      (then (return (i32.const -1)))
    )

    (local.get $pos)
  )

  ;; Convert byte to hex digit
  (func $to_hex_digit (param $value i32) (result i32)
    (if (result i32)
      (i32.lt_u (local.get $value) (i32.const 10))
      (then
        (i32.add (local.get $value) (i32.const 48))  ;; '0'
      )
      (else
        (i32.add (i32.sub (local.get $value) (i32.const 10)) (i32.const 97))  ;; 'a'
      )
    )
  )

  ;; Convert byte to two hex digits and write to output
  (func $byte_to_hex (param $value i32) (param $out_pos i32)
    (local $high i32)
    (local $low i32)

    (local.set $high (i32.shr_u (local.get $value) (i32.const 4)))
    (local.set $low (i32.and (local.get $value) (i32.const 15)))

    (i32.store8
      (i32.add (global.get $output_ptr) (local.get $out_pos))
      (call $to_hex_digit (local.get $high)))

    (i32.store8
      (i32.add (global.get $output_ptr) (i32.add (local.get $out_pos) (i32.const 1)))
      (call $to_hex_digit (local.get $low)))
  )

  (func $run (export "run") (param $input_size i32) (result i32)
    (local $start i32)
    (local $end i32)
    (local $pos i32)
    (local $pos_ptr i32)
    (local $r i32)
    (local $g i32)
    (local $b i32)
    (local $current_char i32)

    ;; Allocate space for position pointer (after output buffer)
    (local.set $pos_ptr (i32.const 0x30000))

    ;; Empty input is invalid
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

    ;; If empty after trimming, invalid
    (if (i32.ge_u (local.get $start) (local.get $end))
      (then (return (i32.const 0)))
    )

    ;; Parse R value
    (local.set $r (call $parse_number (local.get $start) (local.get $end) (local.get $pos_ptr)))
    (if (i32.eq (local.get $r) (i32.const -1))
      (then (return (i32.const 0)))
    )
    (if (i32.gt_u (local.get $r) (i32.const 255))
      (then (return (i32.const 0)))
    )
    (local.set $pos (i32.load (local.get $pos_ptr)))

    ;; Skip separator (comma)
    (local.set $pos (call $skip_separator (local.get $pos) (local.get $end)))
    (if (i32.eq (local.get $pos) (i32.const -1))
      (then (return (i32.const 0)))
    )

    ;; Parse G value
    (local.set $g (call $parse_number (local.get $pos) (local.get $end) (local.get $pos_ptr)))
    (if (i32.eq (local.get $g) (i32.const -1))
      (then (return (i32.const 0)))
    )
    (if (i32.gt_u (local.get $g) (i32.const 255))
      (then (return (i32.const 0)))
    )
    (local.set $pos (i32.load (local.get $pos_ptr)))

    ;; Skip separator (comma)
    (local.set $pos (call $skip_separator (local.get $pos) (local.get $end)))
    (if (i32.eq (local.get $pos) (i32.const -1))
      (then (return (i32.const 0)))
    )

    ;; Parse B value
    (local.set $b (call $parse_number (local.get $pos) (local.get $end) (local.get $pos_ptr)))
    (if (i32.eq (local.get $b) (i32.const -1))
      (then (return (i32.const 0)))
    )
    (if (i32.gt_u (local.get $b) (i32.const 255))
      (then (return (i32.const 0)))
    )
    (local.set $pos (i32.load (local.get $pos_ptr)))

    ;; Skip any trailing whitespace
    (block $break_final
      (loop $continue_final
        (br_if $break_final (i32.ge_u (local.get $pos) (local.get $end)))
        (local.set $current_char (i32.load8_u (i32.add (global.get $input_ptr) (local.get $pos))))
        (br_if $break_final (i32.eqz (call $is_whitespace (local.get $current_char))))
        (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
        (br $continue_final)
      )
    )

    ;; Make sure we consumed all input
    (if (i32.ne (local.get $pos) (local.get $end))
      (then (return (i32.const 0)))
    )

    ;; Write # prefix
    (i32.store8 (global.get $output_ptr) (i32.const 35))  ;; '#'

    ;; Convert to hex: #RRGGBB
    (call $byte_to_hex (local.get $r) (i32.const 1))
    (call $byte_to_hex (local.get $g) (i32.const 3))
    (call $byte_to_hex (local.get $b) (i32.const 5))

    ;; Return length: 7 characters (#RRGGBB)
    (i32.const 7)
  )
)
