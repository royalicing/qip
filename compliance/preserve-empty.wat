(module
  (import "qip" "must_render_exactly"
    (func $must_render_exactly (param i64 i32 i32 i32 i32) (result i32)))

  (memory (export "memory") 1)

  (func (export "comply") (result i32)
    (drop
      (call $must_render_exactly
        (i64.const 0)
        (i32.const 0)
        (i32.const 0)
        (i32.const 0)
        (i32.const 0)))
    (i32.const 1))
)
