(module
  (import "qip" "must_render_exactly"
    (func $must_render_exactly (param i64 i32 i32 i32 i32) (result i32)))
  (import "qip" "must_reject"
    (func $must_reject (param i64 i32 i32) (result i32)))

  (memory (export "memory") 1)

  (data (i32.const 0) "full name")
  (data (i32.const 32) "items[0].email")
  (data (i32.const 64) "a\00b")

  (func (export "comply") (result i32)
    (drop
      (call $must_render_exactly
        (i64.const 0) (i32.const 0) (i32.const 9) (i32.const 0) (i32.const 9)))
    (drop
      (call $must_render_exactly
        (i64.const 1) (i32.const 32) (i32.const 14) (i32.const 32) (i32.const 14)))
    (drop (call $must_reject (i64.const 2) (i32.const 0) (i32.const 0)))
    (drop (call $must_reject (i64.const 3) (i32.const 64) (i32.const 3)))
    (i32.const 4))
)
