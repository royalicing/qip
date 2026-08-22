(module
  (import "qip" "must_reject"
    (func $must_reject (param i64 i32 i32) (result i32)))

  (memory (export "memory") 1)

  (data (i32.const 0) "\80ABC")
  (data (i32.const 8) "A\c3\a9B")
  (data (i32.const 16) "ABC\ff")

  (func (export "comply") (result i32)
    (drop (call $must_reject (i64.const 0) (i32.const 0) (i32.const 4)))
    (drop (call $must_reject (i64.const 1) (i32.const 8) (i32.const 4)))
    (drop (call $must_reject (i64.const 2) (i32.const 16) (i32.const 4)))
    (i32.const 3))
)
