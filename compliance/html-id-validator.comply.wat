(module
  (import "qip" "must_render_exactly"
    (func $must_render_exactly (param i64 i32 i32 i32 i32) (result i32)))
  (import "qip" "must_reject"
    (func $must_reject (param i64 i32 i32) (result i32)))

  (memory (export "memory") 1)

  (data (i32.const 0) "main-content")
  (data (i32.const 32) "main:content")
  (data (i32.const 64) "two words")
  (data (i32.const 80) "two\09words")
  (data (i32.const 96) "\0anewline")

  (func (export "comply") (result i32)
    (drop
      (call $must_render_exactly
        (i64.const 0) (i32.const 0) (i32.const 12) (i32.const 0) (i32.const 12)))
    (drop
      (call $must_render_exactly
        (i64.const 1) (i32.const 32) (i32.const 12) (i32.const 32) (i32.const 12)))

    (drop (call $must_reject (i64.const 2) (i32.const 0) (i32.const 0)))
    (drop (call $must_reject (i64.const 3) (i32.const 64) (i32.const 9)))
    (drop (call $must_reject (i64.const 4) (i32.const 80) (i32.const 9)))
    (drop (call $must_reject (i64.const 5) (i32.const 96) (i32.const 8)))
    (i32.const 6))
)
