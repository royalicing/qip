(module
  (import "impl" "memory" (memory 1))
  (import "impl" "input_ptr" (func $input_ptr (result i32)))
  (import "impl" "input_utf8_cap" (func $input_utf8_cap (result i32)))
  (import "impl" "output_ptr" (func $output_ptr (result i32)))
  (import "impl" "render" (func $run (param i32) (result i32)))

  (data $case1_in "+1 (415) 555-2671")
  (data $case1_out "+14155552671")

  (data $case2_in "  1212-555-0100  ")
  (data $case2_out "+12125550100")

  (data $case3_in "5552671")
  (data $case3_out "+5552671")

  (data $case5_in "abc")
  (data $case6_in "+")

  (data $case7_in "0044 20 7946 0958")
  (data $case7_out "+00442079460958")

  (data $case8_in "1-2-3")
  (data $case8_out "+123")

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
  ;; Negative status codes identify the failing scenario.
  (func (export "positive") (result i32)
    (local $in_ptr i32)
    (local $expected_ptr i32)
    (local $out_size i32)

    ;; We reserve a small scratch window inside impl input buffer:
    ;; [in_ptr, in_ptr+31] for input and [in_ptr+32, ...] for expected output.
    (if (i32.lt_u (call $input_utf8_cap) (i32.const 64))
      (then
        (call $fail (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0))
        (return (i32.const -100))
      )
    )

    (local.set $in_ptr (call $input_ptr))
    (local.set $expected_ptr (i32.add (local.get $in_ptr) (i32.const 32)))

    ;; Case 1: "+1 (415) 555-2671" -> "+14155552671"
    (memory.init $case1_in (local.get $in_ptr) (i32.const 0) (i32.const 17))
    (local.set $out_size (call $run (i32.const 17)))
    (memory.init $case1_out (local.get $expected_ptr) (i32.const 0) (i32.const 12))
    (if (i32.eqz (call $output_equal (local.get $out_size) (local.get $expected_ptr) (i32.const 12)))
      (then
        (call $fail (local.get $in_ptr) (i32.const 17) (local.get $expected_ptr) (i32.const 12) (local.get $out_size))
        (return (i32.const -1))
      )
    )

    ;; Case 2: "  1212-555-0100  " -> "+12125550100"
    (memory.init $case2_in (local.get $in_ptr) (i32.const 0) (i32.const 17))
    (local.set $out_size (call $run (i32.const 17)))
    (memory.init $case2_out (local.get $expected_ptr) (i32.const 0) (i32.const 12))
    (if (i32.eqz (call $output_equal (local.get $out_size) (local.get $expected_ptr) (i32.const 12)))
      (then
        (call $fail (local.get $in_ptr) (i32.const 17) (local.get $expected_ptr) (i32.const 12) (local.get $out_size))
        (return (i32.const -2))
      )
    )

    ;; Case 3: "5552671" -> "+5552671"
    (memory.init $case3_in (local.get $in_ptr) (i32.const 0) (i32.const 7))
    (local.set $out_size (call $run (i32.const 7)))
    (memory.init $case3_out (local.get $expected_ptr) (i32.const 0) (i32.const 8))
    (if (i32.eqz (call $output_equal (local.get $out_size) (local.get $expected_ptr) (i32.const 8)))
      (then
        (call $fail (local.get $in_ptr) (i32.const 7) (local.get $expected_ptr) (i32.const 8) (local.get $out_size))
        (return (i32.const -3))
      )
    )

    ;; Case 4: "" -> invalid (size 0)
    (local.set $out_size (call $run (i32.const 0)))
    (if (i32.ne (local.get $out_size) (i32.const 0))
      (then
        (call $fail (local.get $in_ptr) (i32.const 0) (local.get $expected_ptr) (i32.const 0) (local.get $out_size))
        (return (i32.const -4))
      )
    )

    ;; Case 5: "abc" -> invalid (size 0)
    (memory.init $case5_in (local.get $in_ptr) (i32.const 0) (i32.const 3))
    (local.set $out_size (call $run (i32.const 3)))
    (if (i32.ne (local.get $out_size) (i32.const 0))
      (then
        (call $fail (local.get $in_ptr) (i32.const 3) (local.get $expected_ptr) (i32.const 0) (local.get $out_size))
        (return (i32.const -5))
      )
    )

    ;; Case 6: "+" -> invalid (size 0)
    (memory.init $case6_in (local.get $in_ptr) (i32.const 0) (i32.const 1))
    (local.set $out_size (call $run (i32.const 1)))
    (if (i32.ne (local.get $out_size) (i32.const 0))
      (then
        (call $fail (local.get $in_ptr) (i32.const 1) (local.get $expected_ptr) (i32.const 0) (local.get $out_size))
        (return (i32.const -6))
      )
    )

    ;; Case 7: "0044 20 7946 0958" -> "+00442079460958"
    (memory.init $case7_in (local.get $in_ptr) (i32.const 0) (i32.const 17))
    (local.set $out_size (call $run (i32.const 17)))
    (memory.init $case7_out (local.get $expected_ptr) (i32.const 0) (i32.const 15))
    (if (i32.eqz (call $output_equal (local.get $out_size) (local.get $expected_ptr) (i32.const 15)))
      (then
        (call $fail (local.get $in_ptr) (i32.const 17) (local.get $expected_ptr) (i32.const 15) (local.get $out_size))
        (return (i32.const -7))
      )
    )

    ;; Case 8: "1-2-3" -> "+123"
    (memory.init $case8_in (local.get $in_ptr) (i32.const 0) (i32.const 5))
    (local.set $out_size (call $run (i32.const 5)))
    (memory.init $case8_out (local.get $expected_ptr) (i32.const 0) (i32.const 4))
    (if (i32.eqz (call $output_equal (local.get $out_size) (local.get $expected_ptr) (i32.const 4)))
      (then
        (call $fail (local.get $in_ptr) (i32.const 5) (local.get $expected_ptr) (i32.const 4) (local.get $out_size))
        (return (i32.const -8))
      )
    )
    ;; All checks passed; return the fixed number of passing checks.
    (i32.const 8)
  )
)
