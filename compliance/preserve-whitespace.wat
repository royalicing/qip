(module
  (import "impl" "memory" (memory 1))
  (import "impl" "input_ptr" (func $input_ptr (result i32)))
  (import "impl" "input_utf8_cap" (func $input_utf8_cap (result i32)))
  (import "impl" "output_ptr" (func $output_ptr (result i32)))
  (import "impl" "render" (func $run (param i32) (result i32)))

  (data $case1_in "  leading and trailing  ")
  (data $case2_in "\09tabbed\09fields\09")
  (data $case3_in "line1\0d\0aline2\0aline3\0d")
  (data $case4_in " \09\0a\0d ")

  (global $failure_input_ptr (mut i32) (i32.const 0))
  (global $failure_input_size (mut i32) (i32.const 0))
  (global $failure_expected_output_ptr (mut i32) (i32.const 0))
  (global $failure_expected_output_size (mut i32) (i32.const 0))
  (global $failure_actual_output_ptr (mut i32) (i32.const 0))
  (global $failure_actual_output_size (mut i32) (i32.const 0))

  (func (export "failure_input_ptr") (result i32)
    (global.get $failure_input_ptr)
  )

  (func (export "failure_input_size") (result i32)
    (global.get $failure_input_size)
  )

  (func (export "failure_expected_output_ptr") (result i32)
    (global.get $failure_expected_output_ptr)
  )

  (func (export "failure_expected_output_size") (result i32)
    (global.get $failure_expected_output_size)
  )

  (func (export "failure_actual_output_ptr") (result i32)
    (global.get $failure_actual_output_ptr)
  )

  (func (export "failure_actual_output_size") (result i32)
    (global.get $failure_actual_output_size)
  )

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
    (global.set $failure_actual_output_size (local.get $actual_size))
  )

  (func $output_equal (param $out_size i32) (param $expected_ptr i32) (param $expected_size i32) (result i32)
    (local $i i32)
    (local $out_ptr i32)

    (if (i32.ne (local.get $out_size) (local.get $expected_size))
      (then
        (return (i32.const 0))
      )
    )

    (local.set $out_ptr (call $output_ptr))
    (local.set $i (i32.const 0))
    (block $mismatch
      (block $done
        (loop $loop
          (br_if $done (i32.ge_u (local.get $i) (local.get $expected_size)))
          (br_if $mismatch
            (i32.ne
              (i32.load8_u (i32.add (local.get $out_ptr) (local.get $i)))
              (i32.load8_u (i32.add (local.get $expected_ptr) (local.get $i)))
            )
          )
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $loop)
        )
      )
      (return (i32.const 1))
    )

    (i32.const 0)
  )

  ;; Returns >0 on pass, <=0 on failure.
  ;; Checks that whitespace-heavy input is preserved byte-for-byte.
  (func (export "positive") (result i32)
    (local $in_ptr i32)
    (local $expected_ptr i32)
    (local $out_size i32)

    ;; Reserve [in_ptr, in_ptr+127] for input and [in_ptr+128, ...] for expected.
    (if (i32.lt_u (call $input_utf8_cap) (i32.const 256))
      (then
        (call $fail (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0))
        (return (i32.const -100))
      )
    )

    (local.set $in_ptr (call $input_ptr))
    (local.set $expected_ptr (i32.add (local.get $in_ptr) (i32.const 128)))

    ;; Case 1: leading/trailing spaces.
    (memory.init $case1_in (local.get $in_ptr) (i32.const 0) (i32.const 24))
    (local.set $out_size (call $run (i32.const 24)))
    (memory.init $case1_in (local.get $expected_ptr) (i32.const 0) (i32.const 24))
    (if (i32.eqz (call $output_equal (local.get $out_size) (local.get $expected_ptr) (i32.const 24)))
      (then
        (call $fail (local.get $in_ptr) (i32.const 24) (local.get $expected_ptr) (i32.const 24) (local.get $out_size))
        (return (i32.const -1))
      )
    )

    ;; Case 2: tabs.
    (memory.init $case2_in (local.get $in_ptr) (i32.const 0) (i32.const 15))
    (local.set $out_size (call $run (i32.const 15)))
    (memory.init $case2_in (local.get $expected_ptr) (i32.const 0) (i32.const 15))
    (if (i32.eqz (call $output_equal (local.get $out_size) (local.get $expected_ptr) (i32.const 15)))
      (then
        (call $fail (local.get $in_ptr) (i32.const 15) (local.get $expected_ptr) (i32.const 15) (local.get $out_size))
        (return (i32.const -2))
      )
    )

    ;; Case 3: mixed line endings.
    (memory.init $case3_in (local.get $in_ptr) (i32.const 0) (i32.const 19))
    (local.set $out_size (call $run (i32.const 19)))
    (memory.init $case3_in (local.get $expected_ptr) (i32.const 0) (i32.const 19))
    (if (i32.eqz (call $output_equal (local.get $out_size) (local.get $expected_ptr) (i32.const 19)))
      (then
        (call $fail (local.get $in_ptr) (i32.const 19) (local.get $expected_ptr) (i32.const 19) (local.get $out_size))
        (return (i32.const -3))
      )
    )

    ;; Case 4: whitespace only.
    (memory.init $case4_in (local.get $in_ptr) (i32.const 0) (i32.const 5))
    (local.set $out_size (call $run (i32.const 5)))
    (memory.init $case4_in (local.get $expected_ptr) (i32.const 0) (i32.const 5))
    (if (i32.eqz (call $output_equal (local.get $out_size) (local.get $expected_ptr) (i32.const 5)))
      (then
        (call $fail (local.get $in_ptr) (i32.const 5) (local.get $expected_ptr) (i32.const 5) (local.get $out_size))
        (return (i32.const -4))
      )
    )

    ;; Case 5: empty input -> empty output.
    (local.set $out_size (call $run (i32.const 0)))
    (if (i32.ne (local.get $out_size) (i32.const 0))
      (then
        (call $fail (local.get $in_ptr) (i32.const 0) (local.get $expected_ptr) (i32.const 0) (local.get $out_size))
        (return (i32.const -5))
      )
    )

    ;; All 5 checks passed.
    (i32.const 5)
  )
)
