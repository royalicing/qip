(module
  (import "qip" "render_must_trap"
    (func $render_must_trap (param i64 i32 i32) (result i32)))

  (memory (export "memory") 1)

  (func (export "comply") (result i32)
    (drop
      (call $render_must_trap
        (i64.const 0)
        (i32.const 0)
        (i32.const 0)))
    (i32.const 1))
)
