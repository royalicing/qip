(module
  (import "qip" "must_trap"
    (func $must_trap (param i64 i32 i32) (result i32)))

  (memory (export "memory") 1)

  (func (export "comply") (result i32)
    (drop
      (call $must_trap
        (i64.const 0)
        (i32.const 0)
        (i32.const 0)))
    (i32.const 1))
)
