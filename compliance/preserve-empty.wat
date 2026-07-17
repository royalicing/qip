(module
  (import "qip" "render_must_equal"
    (func $render_must_equal (param i64 i32 i32 i32 i32) (result i32)))

  (memory (export "memory") 1)

  (func (export "comply") (result i32)
    (drop
      (call $render_must_equal
        (i64.const 0)
        (i32.const 0)
        (i32.const 0)
        (i32.const 0)
        (i32.const 0)))
    (i32.const 1))
)
