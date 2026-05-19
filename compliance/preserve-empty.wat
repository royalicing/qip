(module
  (import "impl" "memory" (memory 1))
  (import "impl" "render" (func $run (param i32) (result i32)))

  ;; Returns >0 on pass, <=0 on failure.
  ;; Check: empty input must not trap and must return zero output size.
  (func (export "positive") (result i32)
    (if (i32.ne (call $run (i32.const 0)) (i32.const 0))
      (then
        (return (i32.const -1))
      )
    )

    ;; 1 check passed.
    (i32.const 1)
  )
)
