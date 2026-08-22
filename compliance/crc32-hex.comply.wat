(module
  (import "qip" "must_render_exactly"
    (func $must_render_exactly (param i64 i32 i32 i32 i32) (result i32)))

  (memory (export "memory") 1)
  (data (i32.const 0) "abc")
  (data (i32.const 16) "352441c2")
  (data (i32.const 32) "00000000")

  (func (export "comply") (result i32)
    (drop
      (call $must_render_exactly
        (i64.const 0)
        (i32.const 0) (i32.const 3)
        (i32.const 16) (i32.const 8)))
    (drop
      (call $must_render_exactly
        (i64.const 1)
        (i32.const 0) (i32.const 0)
        (i32.const 32) (i32.const 8)))
    ;; Repeat the first case to detect retained render state.
    (drop
      (call $must_render_exactly
        (i64.const 2)
        (i32.const 0) (i32.const 3)
        (i32.const 16) (i32.const 8)))
    (i32.const 3))
)
