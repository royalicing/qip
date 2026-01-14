(module $LuhnValidator
  (memory (export "memory") 3)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0x10000))
  (global $input_cap (export "input_cap") i32 (i32.const 0x10000))
  (global $output_ptr (export "output_ptr") i32 (i32.const 0x20000))
  (global $output_cap (export "output_cap") i32 (i32.const 0x10000))

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

  ;; Check if character should be kept during normalization (digit)
  ;; Spaces and hyphens are removed
  (func $should_keep (param $c i32) (result i32)
    (call $is_digit (local.get $c))
  )

  ;; Luhn algorithm validation
  ;; Takes normalized digit string and its length
  (func $validate_luhn (param $digits_ptr i32) (param $len i32) (result i32)
    (local $sum i32)
    (local $i i32)
    (local $digit i32)
    (local $doubled i32)
    (local $is_second i32)

    ;; Need at least 2 digits for Luhn
    (if (i32.lt_u (local.get $len) (i32.const 2))
      (then (return (i32.const 0)))
    )

    ;; Start from rightmost digit, work backwards
    (local.set $i (local.get $len))
    (local.set $is_second (i32.const 0))

    (block $break
      (loop $continue
        ;; Check if we've processed all digits
        (br_if $break (i32.eq (local.get $i) (i32.const 0)))

        ;; Move to previous digit
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))

        ;; Load digit and convert from ASCII
        (local.set $digit
          (i32.sub
            (i32.load8_u (i32.add (local.get $digits_ptr) (local.get $i)))
            (i32.const 48)
          )
        )

        ;; If this is every second digit (from right), double it
        (if (local.get $is_second)
          (then
            (local.set $doubled (i32.mul (local.get $digit) (i32.const 2)))
            ;; If doubled value > 9, subtract 9
            (if (i32.gt_u (local.get $doubled) (i32.const 9))
              (then
                (local.set $digit (i32.sub (local.get $doubled) (i32.const 9)))
              )
              (else
                (local.set $digit (local.get $doubled))
              )
            )
          )
        )

        ;; Add to sum
        (local.set $sum (i32.add (local.get $sum) (local.get $digit)))

        ;; Toggle is_second
        (local.set $is_second (i32.xor (local.get $is_second) (i32.const 1)))

        (br $continue)
      )
    )

    ;; Valid if sum is divisible by 10
    (i32.eqz (i32.rem_u (local.get $sum) (i32.const 10)))
  )

  ;; Returns: length of normalized valid number, or 0 if invalid
  (func $run (export "run") (param $input_size i32) (result i32)
    (local $start i32)
    (local $end i32)
    (local $i i32)
    (local $out_i i32)
    (local $current_char i32)

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

    ;; Normalize: copy only digits to output buffer, skip spaces/hyphens
    (local.set $i (local.get $start))
    (local.set $out_i (i32.const 0))
    (block $break_normalize
      (loop $continue_normalize
        (br_if $break_normalize (i32.ge_u (local.get $i) (local.get $end)))
        (local.set $current_char (i32.load8_u (i32.add (global.get $input_ptr) (local.get $i))))

        ;; Skip spaces and hyphens
        (if (i32.and
              (i32.ne (local.get $current_char) (i32.const 32))   ;; space
              (i32.ne (local.get $current_char) (i32.const 45)))  ;; hyphen
          (then
            ;; Must be a digit
            (if (i32.eqz (call $is_digit (local.get $current_char)))
              (then (return (i32.const 0)))  ;; Invalid character
            )
            ;; Copy digit to output
            (i32.store8
              (i32.add (global.get $output_ptr) (local.get $out_i))
              (local.get $current_char))
            (local.set $out_i (i32.add (local.get $out_i) (i32.const 1)))
          )
        )

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $continue_normalize)
      )
    )

    ;; Validate using Luhn algorithm
    (if (i32.eqz (call $validate_luhn (global.get $output_ptr) (local.get $out_i)))
      (then (return (i32.const 0)))
    )

    ;; Return length of normalized number
    (local.get $out_i)
  )
)
