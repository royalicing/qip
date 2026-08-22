(module
  (import "qip" "must_render_exactly"
    (func $must_render_exactly (param i64 i32 i32 i32 i32) (result i32)))

  (memory (export "memory") 1)
  (data (i32.const 0) "# Hello *World*")
  (data (i32.const 32) "Hello World")
  (data (i32.const 64) "no heading")

  (func (export "comply") (result i32)
    (drop
      (call $must_render_exactly
        (i64.const 0)
        (i32.const 0) (i32.const 15)
        (i32.const 32) (i32.const 11)))
    (drop
      (call $must_render_exactly
        (i64.const 1)
        (i32.const 64) (i32.const 10)
        (i32.const 0) (i32.const 0)))
    (i32.const 2))
)
