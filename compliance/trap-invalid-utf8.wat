(module
  (import "impl" "memory" (memory 1))
  (import "impl" "input_ptr" (func $input_ptr (result i32)))
  (import "impl" "input_utf8_cap" (func $input_utf8_cap (result i32)))
  (import "qip" "render_must_trap" (func $render_must_trap (param i32) (result i32)))

  ;; 1) Invalid continuation byte in 2-byte sequence.
  (data $case1_in "\c3\28")
  ;; 2) Lone continuation byte.
  (data $case2_in "\80")
  ;; 3) Overlong 2-byte start (C0).
  (data $case3_in "\c0\af")
  ;; 4) Truncated 3-byte sequence.
  (data $case4_in "\e2\82")
  ;; 5) Truncated 4-byte sequence.
  (data $case5_in "\f0\9f\92")
  ;; 6) Overlong 3-byte sequence (E0 second byte too low).
  (data $case6_in "\e0\80\80")
  ;; 7) UTF-16 surrogate range (ED A0..).
  (data $case7_in "\ed\a0\80")
  ;; 8) Beyond U+10FFFF (F4 second byte too high).
  (data $case8_in "\f4\90\80\80")
  ;; 9) Invalid leading byte > F4.
  (data $case9_in "\f5\80\80\80")
  ;; 10) Invalid leading byte FE.
  (data $case10_in "\fe")

  (global $failure_input_ptr (mut i32) (i32.const 0))
  (global $failure_input_size (mut i32) (i32.const 0))

  (func (export "failure_input_ptr") (result i32)
    (global.get $failure_input_ptr)
  )

  (func (export "failure_input_size") (result i32)
    (global.get $failure_input_size)
  )

  ;; Positive phase sanity check: module can accept at least 4 bytes of input.
  (func (export "positive") (result i32)
    (if (i32.lt_u (call $input_utf8_cap) (i32.const 4))
      (then
        (return (i32.const -100))
      )
    )
    (i32.const 1)
  )

  ;; Negative phase: write invalid UTF-8 and require impl.render to trap.
  (func (export "negative") (result i32)
    (local $in_ptr i32)
    (local $did_trap i32)

    (local.set $in_ptr (call $input_ptr))
    (global.set $failure_input_ptr (local.get $in_ptr))

    ;; Case 1
    (memory.init $case1_in (local.get $in_ptr) (i32.const 0) (i32.const 2))
    (global.set $failure_input_size (i32.const 2))
    (local.set $did_trap (call $render_must_trap (i32.const 2)))
    (if (i32.ne (local.get $did_trap) (i32.const 1))
      (then
        (return (i32.const -1))
      )
    )

    ;; Case 2
    (memory.init $case2_in (local.get $in_ptr) (i32.const 0) (i32.const 1))
    (global.set $failure_input_size (i32.const 1))
    (local.set $did_trap (call $render_must_trap (i32.const 1)))
    (if (i32.ne (local.get $did_trap) (i32.const 1))
      (then
        (return (i32.const -2))
      )
    )

    ;; Case 3
    (memory.init $case3_in (local.get $in_ptr) (i32.const 0) (i32.const 2))
    (global.set $failure_input_size (i32.const 2))
    (local.set $did_trap (call $render_must_trap (i32.const 2)))
    (if (i32.ne (local.get $did_trap) (i32.const 1))
      (then
        (return (i32.const -3))
      )
    )

    ;; Case 4
    (memory.init $case4_in (local.get $in_ptr) (i32.const 0) (i32.const 2))
    (global.set $failure_input_size (i32.const 2))
    (local.set $did_trap (call $render_must_trap (i32.const 2)))
    (if (i32.ne (local.get $did_trap) (i32.const 1))
      (then
        (return (i32.const -4))
      )
    )

    ;; Case 5
    (memory.init $case5_in (local.get $in_ptr) (i32.const 0) (i32.const 3))
    (global.set $failure_input_size (i32.const 3))
    (local.set $did_trap (call $render_must_trap (i32.const 3)))
    (if (i32.ne (local.get $did_trap) (i32.const 1))
      (then
        (return (i32.const -5))
      )
    )

    ;; Case 6
    (memory.init $case6_in (local.get $in_ptr) (i32.const 0) (i32.const 3))
    (global.set $failure_input_size (i32.const 3))
    (local.set $did_trap (call $render_must_trap (i32.const 3)))
    (if (i32.ne (local.get $did_trap) (i32.const 1))
      (then
        (return (i32.const -6))
      )
    )

    ;; Case 7
    (memory.init $case7_in (local.get $in_ptr) (i32.const 0) (i32.const 3))
    (global.set $failure_input_size (i32.const 3))
    (local.set $did_trap (call $render_must_trap (i32.const 3)))
    (if (i32.ne (local.get $did_trap) (i32.const 1))
      (then
        (return (i32.const -7))
      )
    )

    ;; Case 8
    (memory.init $case8_in (local.get $in_ptr) (i32.const 0) (i32.const 4))
    (global.set $failure_input_size (i32.const 4))
    (local.set $did_trap (call $render_must_trap (i32.const 4)))
    (if (i32.ne (local.get $did_trap) (i32.const 1))
      (then
        (return (i32.const -8))
      )
    )

    ;; Case 9
    (memory.init $case9_in (local.get $in_ptr) (i32.const 0) (i32.const 4))
    (global.set $failure_input_size (i32.const 4))
    (local.set $did_trap (call $render_must_trap (i32.const 4)))
    (if (i32.ne (local.get $did_trap) (i32.const 1))
      (then
        (return (i32.const -9))
      )
    )

    ;; Case 10
    (memory.init $case10_in (local.get $in_ptr) (i32.const 0) (i32.const 1))
    (global.set $failure_input_size (i32.const 1))
    (local.set $did_trap (call $render_must_trap (i32.const 1)))
    (if (i32.ne (local.get $did_trap) (i32.const 1))
      (then
        (return (i32.const -10))
      )
    )

    ;; All 10 invalid UTF-8 sequences trapped as expected.
    (i32.const 10)
  )
)
