(module
  (import "qip" "must_render_exactly"
    (func $must_render_exactly (param i64 i32 i32 i32 i32) (result i32)))
  (import "qip" "must_reject"
    (func $must_reject (param i64 i32 i32) (result i32)))

  (memory (export "memory") 1)

  ;; The oracle owns this scratch memory. Inputs start at 0 and expected
  ;; normalized digits start at 256.
  (global $case_input_size (mut i32) (i32.const 0))
  (global $case_expected_size (mut i32) (i32.const 0))
  (global $ordinal (mut i64) (i64.const 0))

  (func $append_input (param $in_ptr i32) (param $value i32)
    (i32.store8
      (i32.add (local.get $in_ptr) (global.get $case_input_size))
      (local.get $value))
    (global.set $case_input_size
      (i32.add (global.get $case_input_size) (i32.const 1))))

  (func $append_expected (param $expected_ptr i32) (param $value i32)
    (i32.store8
      (i32.add (local.get $expected_ptr) (global.get $case_expected_size))
      (local.get $value))
    (global.set $case_expected_size
      (i32.add (global.get $case_expected_size) (i32.const 1))))

  (func $append_digit
    (param $in_ptr i32)
    (param $expected_ptr i32)
    (param $digit i32)
    (local $ascii i32)

    (local.set $ascii (i32.add (local.get $digit) (i32.const 48)))
    (call $append_input (local.get $in_ptr) (local.get $ascii))
    (call $append_expected (local.get $expected_ptr) (local.get $ascii)))

  (func $append_separator (param $in_ptr i32) (param $index i32)
    (call $append_input
      (local.get $in_ptr)
      (select
        (i32.const 45)
        (i32.const 32)
        (i32.and (local.get $index) (i32.const 1)))))

  (func $luhn_double (param $digit i32) (result i32)
    (i32.sub
      (i32.shl (local.get $digit) (i32.const 1))
      (i32.mul (i32.gt_u (local.get $digit) (i32.const 4)) (i32.const 9))))

  (func $make_valid_case
    (param $in_ptr i32)
    (param $expected_ptr i32)
    (param $seed i32)
    (param $prefix_len i32)
    (param $style i32)
    (local $i i32)
    (local $digit i32)
    (local $sum i32)
    (local $total_len i32)
    (local $check_digit i32)

    (global.set $case_input_size (i32.const 0))
    (global.set $case_expected_size (i32.const 0))
    (local.set $total_len (i32.add (local.get $prefix_len) (i32.const 1)))

    (if (i32.eq (local.get $style) (i32.const 2))
      (then (call $append_input (local.get $in_ptr) (i32.const 32))))

    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $prefix_len)))

        (if (i32.and
              (i32.ne (local.get $style) (i32.const 0))
              (i32.ne (local.get $i) (i32.const 0)))
          (then (call $append_separator (local.get $in_ptr) (local.get $i))))

        (local.set $digit
          (i32.rem_u
            (i32.add
              (i32.add (local.get $seed) (i32.mul (local.get $i) (i32.const 7)))
              (local.get $prefix_len))
            (i32.const 10)))
        (call $append_digit
          (local.get $in_ptr)
          (local.get $expected_ptr)
          (local.get $digit))

        (if (i32.eqz
              (i32.and
                (i32.sub (local.get $total_len) (local.get $i))
                (i32.const 1)))
          (then
            (local.set $sum
              (i32.add (local.get $sum) (call $luhn_double (local.get $digit)))))
          (else
            (local.set $sum (i32.add (local.get $sum) (local.get $digit)))))

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))

    (if (i32.ne (local.get $style) (i32.const 0))
      (then (call $append_separator (local.get $in_ptr) (local.get $prefix_len))))

    (local.set $check_digit
      (i32.rem_u
        (i32.sub (i32.const 10) (i32.rem_u (local.get $sum) (i32.const 10)))
        (i32.const 10)))
    (call $append_digit
      (local.get $in_ptr)
      (local.get $expected_ptr)
      (local.get $check_digit))

    (if (i32.eq (local.get $style) (i32.const 2))
      (then (call $append_input (local.get $in_ptr) (i32.const 32)))))

  (func $expect_current_case (param $in_ptr i32) (param $expected_ptr i32)
    (drop
      (call $must_render_exactly
        (global.get $ordinal)
        (local.get $in_ptr)
        (global.get $case_input_size)
        (local.get $expected_ptr)
        (global.get $case_expected_size)))
    (global.set $ordinal (i64.add (global.get $ordinal) (i64.const 1))))

  (func $expect_reject (param $in_ptr i32) (param $input_size i32)
    (drop
      (call $must_reject
        (global.get $ordinal)
        (local.get $in_ptr)
        (local.get $input_size)))
    (global.set $ordinal (i64.add (global.get $ordinal) (i64.const 1))))

  (func $flip_digit (param $in_ptr i32) (param $offset i32)
    (local $digit i32)

    (local.set $digit
      (i32.sub
        (i32.load8_u (i32.add (local.get $in_ptr) (local.get $offset)))
        (i32.const 48)))
    (i32.store8
      (i32.add (local.get $in_ptr) (local.get $offset))
      (i32.add
        (i32.rem_u (i32.add (local.get $digit) (i32.const 1)) (i32.const 10))
        (i32.const 48))))

  (func (export "comply") (result i32)
    (local $in_ptr i32)
    (local $expected_ptr i32)
    (local $prefix_len i32)
    (local $seed i32)
    (local $style i32)

    (global.set $ordinal (i64.const 0))
    (local.set $in_ptr (i32.const 0))
    (local.set $expected_ptr (i32.const 256))

    ;; Valid cases: 32 prefix lengths x 10 seeds x 3 formatting styles.
    (local.set $prefix_len (i32.const 1))
    (block $done_valid_lengths
      (loop $valid_length_loop
        (br_if $done_valid_lengths
          (i32.gt_u (local.get $prefix_len) (i32.const 32)))
        (local.set $seed (i32.const 0))

        (block $done_valid_seeds
          (loop $valid_seed_loop
            (br_if $done_valid_seeds (i32.ge_u (local.get $seed) (i32.const 10)))
            (local.set $style (i32.const 0))

            (block $done_styles
              (loop $style_loop
                (br_if $done_styles (i32.ge_u (local.get $style) (i32.const 3)))
                (call $make_valid_case
                  (local.get $in_ptr)
                  (local.get $expected_ptr)
                  (local.get $seed)
                  (local.get $prefix_len)
                  (local.get $style))
                (call $expect_current_case (local.get $in_ptr) (local.get $expected_ptr))
                (local.set $style (i32.add (local.get $style) (i32.const 1)))
                (br $style_loop)))

            (local.set $seed (i32.add (local.get $seed) (i32.const 1)))
            (br $valid_seed_loop)))

        (local.set $prefix_len (i32.add (local.get $prefix_len) (i32.const 1)))
        (br $valid_length_loop)))

    ;; Fixed rejection cases: empty, separator-only, and too short.
    (call $expect_reject (local.get $in_ptr) (i32.const 0))

    (global.set $case_input_size (i32.const 0))
    (call $append_input (local.get $in_ptr) (i32.const 32))
    (call $append_input (local.get $in_ptr) (i32.const 45))
    (call $append_input (local.get $in_ptr) (i32.const 32))
    (call $expect_reject (local.get $in_ptr) (global.get $case_input_size))

    (global.set $case_input_size (i32.const 0))
    (call $append_input (local.get $in_ptr) (i32.const 52))
    (call $expect_reject (local.get $in_ptr) (global.get $case_input_size))

    ;; For every generated prefix, reject a bad checksum and a non-digit.
    (local.set $prefix_len (i32.const 1))
    (block $done_invalid_lengths
      (loop $invalid_length_loop
        (br_if $done_invalid_lengths
          (i32.gt_u (local.get $prefix_len) (i32.const 32)))
        (local.set $seed (i32.const 0))

        (block $done_invalid_seeds
          (loop $invalid_seed_loop
            (br_if $done_invalid_seeds (i32.ge_u (local.get $seed) (i32.const 10)))

            (call $make_valid_case
              (local.get $in_ptr)
              (local.get $expected_ptr)
              (local.get $seed)
              (local.get $prefix_len)
              (i32.const 0))
            (call $flip_digit
              (local.get $in_ptr)
              (i32.sub (global.get $case_input_size) (i32.const 1)))
            (call $expect_reject (local.get $in_ptr) (global.get $case_input_size))

            (call $make_valid_case
              (local.get $in_ptr)
              (local.get $expected_ptr)
              (local.get $seed)
              (local.get $prefix_len)
              (i32.const 2))
            (i32.store8
              (i32.add
                (local.get $in_ptr)
                (i32.shr_u (global.get $case_input_size) (i32.const 1)))
              (i32.const 120))
            (call $expect_reject (local.get $in_ptr) (global.get $case_input_size))

            (local.set $seed (i32.add (local.get $seed) (i32.const 1)))
            (br $invalid_seed_loop)))

        (local.set $prefix_len (i32.add (local.get $prefix_len) (i32.const 1)))
        (br $invalid_length_loop)))

    (i32.wrap_i64 (global.get $ordinal)))
)
