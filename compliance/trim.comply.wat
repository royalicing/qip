(module
  (import "qip" "must_render_exactly"
    (func $must_render_exactly (param i64 i32 i32 i32 i32) (result i32)))

  (memory (export "memory") 1)
  (data (i32.const 0) "  hi \09")
  (data (i32.const 16) "hi")
  (data (i32.const 32) " \09\0a\0d")

  (func (export "comply") (result i32)
    (drop
      (call $must_render_exactly
        (i64.const 0)
        (i32.const 0) (i32.const 6)
        (i32.const 16) (i32.const 2)))
    (drop
      (call $must_render_exactly
        (i64.const 1)
        (i32.const 32) (i32.const 4)
        (i32.const 0) (i32.const 0)))
    (i32.const 2))
)
