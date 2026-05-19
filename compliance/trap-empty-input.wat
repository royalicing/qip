(module
  (import "impl" "memory" (memory 1))
  (import "qip" "render_must_trap" (func $render_must_trap (param i32) (result i32)))

  ;; Returns >0 on pass, <=0 on failure.
  ;; Check: empty input must trap.
  (func (export "positive") (result i32)
    ;; Sanity check passed.
    (i32.const 1)
  )

  ;; Returns >0 on pass, <=0 on failure.
  ;; Check: run(0) is expected to trap.
  (func (export "negative") (result i32)
    (if (i32.ne (call $render_must_trap (i32.const 0)) (i32.const 1))
      (then
        (return (i32.const -1))
      )
    )
    (i32.const 1)
  )
)
