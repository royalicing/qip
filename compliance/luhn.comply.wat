(module
  (import "impl" "memory" (memory 1))
  (import "impl" "input_ptr" (func $input_ptr (result i32)))
  (import "impl" "input_utf8_cap" (func $input_utf8_cap (result i32)))
  (import "impl" "output_ptr" (func $output_ptr (result i32)))
  (import "impl" "render" (func $render (param i32) (result i32)))
  (import "qip" "render_must_trap" (func $render_must_trap (param i32) (result i32)))

  (global $case_input_size (mut i32) (i32.const 0))
  (global $case_expected_size (mut i32) (i32.const 0))
  (global $failure_input_ptr (mut i32) (i32.const 0))
  (global $failure_input_size (mut i32) (i32.const 0))
  (global $failure_expected_output_ptr (mut i32) (i32.const 0))
  (global $failure_expected_output_size (mut i32) (i32.const 0))
  (global $failure_actual_output_ptr (mut i32) (i32.const 0))
  (global $failure_actual_output_size (mut i32) (i32.const 0))

  (func (export "failure_input_ptr") (result i32)
    (global.get $failure_input_ptr))

  (func (export "failure_input_size") (result i32)
    (global.get $failure_input_size))

  (func (export "failure_expected_output_ptr") (result i32)
    (global.get $failure_expected_output_ptr))

  (func (export "failure_expected_output_size") (result i32)
    (global.get $failure_expected_output_size))

  (func (export "failure_actual_output_ptr") (result i32)
    (global.get $failure_actual_output_ptr))

  (func (export "failure_actual_output_size") (result i32)
    (global.get $failure_actual_output_size))

  (func $fail
    (param $in_ptr i32)
    (param $in_size i32)
    (param $expected_ptr i32)
    (param $expected_size i32)
    (param $actual_size i32)
    (global.set $failure_input_ptr (local.get $in_ptr))
    (global.set $failure_input_size (local.get $in_size))
    (global.set $failure_expected_output_ptr (local.get $expected_ptr))
    (global.set $failure_expected_output_size (local.get $expected_size))
    (global.set $failure_actual_output_ptr (call $output_ptr))
    (global.set $failure_actual_output_size (local.get $actual_size)))

  (func $fail_input (param $in_ptr i32) (param $in_size i32)
    (global.set $failure_input_ptr (local.get $in_ptr))
    (global.set $failure_input_size (local.get $in_size))
    (global.set $failure_expected_output_ptr (i32.const 0))
    (global.set $failure_expected_output_size (i32.const 0))
    (global.set $failure_actual_output_ptr (i32.const 0))
    (global.set $failure_actual_output_size (i32.const 0)))

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

        (if (i32.and (i32.ne (local.get $style) (i32.const 0)) (i32.ne (local.get $i) (i32.const 0)))
          (then (call $append_separator (local.get $in_ptr) (local.get $i))))

        (local.set $digit
          (i32.rem_u
            (i32.add
              (i32.add (local.get $seed) (i32.mul (local.get $i) (i32.const 7)))
              (local.get $prefix_len))
            (i32.const 10)))
        (call $append_digit (local.get $in_ptr) (local.get $expected_ptr) (local.get $digit))

        (if (i32.eqz (i32.and (i32.sub (local.get $total_len) (local.get $i)) (i32.const 1)))
          (then
            (local.set $sum (i32.add (local.get $sum) (call $luhn_double (local.get $digit)))))
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
    (call $append_digit (local.get $in_ptr) (local.get $expected_ptr) (local.get $check_digit))

    (if (i32.eq (local.get $style) (i32.const 2))
      (then (call $append_input (local.get $in_ptr) (i32.const 32)))))

  (func $output_equal
    (param $out_size i32)
    (param $expected_ptr i32)
    (param $expected_size i32)
    (result i32)
    (local $i i32)
    (local $out_ptr i32)

    (if (i32.ne (local.get $out_size) (local.get $expected_size))
      (then (return (i32.const 0))))

    (local.set $out_ptr (call $output_ptr))
    (block $mismatch
      (block $done
        (loop $loop
          (br_if $done (i32.ge_u (local.get $i) (local.get $expected_size)))
          (br_if $mismatch
            (i32.ne
              (i32.load8_u (i32.add (local.get $out_ptr) (local.get $i)))
              (i32.load8_u (i32.add (local.get $expected_ptr) (local.get $i)))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $loop)))
      (return (i32.const 1)))

    (i32.const 0))

  (func $check_current_case
    (param $in_ptr i32)
    (param $expected_ptr i32)
    (result i32)
    (local $out_size i32)

    (local.set $out_size (call $render (global.get $case_input_size)))
    (if (i32.eqz
          (call $output_equal
            (local.get $out_size)
            (local.get $expected_ptr)
            (global.get $case_expected_size)))
      (then
        (call $fail
          (local.get $in_ptr)
          (global.get $case_input_size)
          (local.get $expected_ptr)
          (global.get $case_expected_size)
          (local.get $out_size))
        (return (i32.const 0))))

    (i32.const 1))

  (func $check_trap (param $in_ptr i32) (param $input_size i32) (result i32)
    (if (i32.ne (call $render_must_trap (local.get $input_size)) (i32.const 1))
      (then
        (call $fail_input (local.get $in_ptr) (local.get $input_size))
        (return (i32.const 0))))

    (i32.const 1))

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

  (func (export "positive") (result i32)
    (local $in_ptr i32)
    (local $expected_ptr i32)
    (local $prefix_len i32)
    (local $seed i32)
    (local $style i32)
    (local $checks i32)

    (if (i32.lt_u (call $input_utf8_cap) (i32.const 512))
      (then
        (call $fail (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0))
        (return (i32.const -100))))

    (local.set $in_ptr (call $input_ptr))
    (local.set $expected_ptr (i32.add (local.get $in_ptr) (i32.const 256)))
    (local.set $prefix_len (i32.const 1))

    (block $done_lengths
      (loop $length_loop
        (br_if $done_lengths (i32.gt_u (local.get $prefix_len) (i32.const 32)))
        (local.set $seed (i32.const 0))

        (block $done_seeds
          (loop $seed_loop
            (br_if $done_seeds (i32.ge_u (local.get $seed) (i32.const 10)))
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
                (if (i32.eqz (call $check_current_case (local.get $in_ptr) (local.get $expected_ptr)))
                  (then (return (i32.sub (i32.const -1) (local.get $checks)))))
                (local.set $checks (i32.add (local.get $checks) (i32.const 1)))
                (local.set $style (i32.add (local.get $style) (i32.const 1)))
                (br $style_loop)))

            (local.set $seed (i32.add (local.get $seed) (i32.const 1)))
            (br $seed_loop)))

        (local.set $prefix_len (i32.add (local.get $prefix_len) (i32.const 1)))
        (br $length_loop)))

    (local.get $checks))

  (func (export "negative") (result i32)
    (local $in_ptr i32)
    (local $expected_ptr i32)
    (local $prefix_len i32)
    (local $seed i32)
    (local $checks i32)

    (if (i32.lt_u (call $input_utf8_cap) (i32.const 512))
      (then (return (i32.const -100))))

    (local.set $in_ptr (call $input_ptr))
    (local.set $expected_ptr (i32.add (local.get $in_ptr) (i32.const 256)))

    (if (i32.eqz (call $check_trap (local.get $in_ptr) (i32.const 0)))
      (then (return (i32.const -1))))
    (local.set $checks (i32.add (local.get $checks) (i32.const 1)))

    (global.set $case_input_size (i32.const 0))
    (call $append_input (local.get $in_ptr) (i32.const 32))
    (call $append_input (local.get $in_ptr) (i32.const 45))
    (call $append_input (local.get $in_ptr) (i32.const 32))
    (if (i32.eqz (call $check_trap (local.get $in_ptr) (global.get $case_input_size)))
      (then (return (i32.const -2))))
    (local.set $checks (i32.add (local.get $checks) (i32.const 1)))

    (global.set $case_input_size (i32.const 0))
    (call $append_input (local.get $in_ptr) (i32.const 52))
    (if (i32.eqz (call $check_trap (local.get $in_ptr) (global.get $case_input_size)))
      (then (return (i32.const -3))))
    (local.set $checks (i32.add (local.get $checks) (i32.const 1)))

    (local.set $prefix_len (i32.const 1))
    (block $done_lengths
      (loop $length_loop
        (br_if $done_lengths (i32.gt_u (local.get $prefix_len) (i32.const 32)))
        (local.set $seed (i32.const 0))

        (block $done_seeds
          (loop $seed_loop
            (br_if $done_seeds (i32.ge_u (local.get $seed) (i32.const 10)))

            (call $make_valid_case
              (local.get $in_ptr)
              (local.get $expected_ptr)
              (local.get $seed)
              (local.get $prefix_len)
              (i32.const 0))
            (call $flip_digit
              (local.get $in_ptr)
              (i32.sub (global.get $case_input_size) (i32.const 1)))
            (if (i32.eqz (call $check_trap (local.get $in_ptr) (global.get $case_input_size)))
              (then (return (i32.sub (i32.const -4) (local.get $checks)))))
            (local.set $checks (i32.add (local.get $checks) (i32.const 1)))

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
            (if (i32.eqz (call $check_trap (local.get $in_ptr) (global.get $case_input_size)))
              (then (return (i32.sub (i32.const -4) (local.get $checks)))))
            (local.set $checks (i32.add (local.get $checks) (i32.const 1)))

            (local.set $seed (i32.add (local.get $seed) (i32.const 1)))
            (br $seed_loop)))

        (local.set $prefix_len (i32.add (local.get $prefix_len) (i32.const 1)))
        (br $length_loop)))

    (local.get $checks))
)
