(module
  (import "qip" "must_render_exactly"
    (func $must_render_exactly (param i64 i32 i32 i32 i32) (result i32)))
  (import "qip" "must_reject"
    (func $must_reject (param i64 i32 i32) (result i32)))

  (memory (export "memory") 1)

  (data (i32.const 0) "div")
  (data (i32.const 16) "DIV")
  (data (i32.const 32) "x-widget")
  (data (i32.const 48) "builtin")
  (data (i32.const 64) "custom")
  (data (i32.const 80) "frobnicate")
  (data (i32.const 96) "annotation-xml")
  (data (i32.const 112) "X-widget")
  (data (i32.const 128) "x_widget")
  (data (i32.const 144) " x-widget ")

  (func (export "comply") (result i32)
    (drop
      (call $must_render_exactly
        (i64.const 0) (i32.const 0) (i32.const 3) (i32.const 48) (i32.const 7)))
    (drop
      (call $must_render_exactly
        (i64.const 1) (i32.const 16) (i32.const 3) (i32.const 48) (i32.const 7)))
    (drop
      (call $must_render_exactly
        (i64.const 2) (i32.const 32) (i32.const 8) (i32.const 64) (i32.const 6)))

    (drop (call $must_reject (i64.const 3) (i32.const 0) (i32.const 0)))
    (drop (call $must_reject (i64.const 4) (i32.const 80) (i32.const 10)))
    (drop (call $must_reject (i64.const 5) (i32.const 96) (i32.const 14)))
    (drop (call $must_reject (i64.const 6) (i32.const 112) (i32.const 8)))
    (drop (call $must_reject (i64.const 7) (i32.const 128) (i32.const 8)))
    (drop (call $must_reject (i64.const 8) (i32.const 144) (i32.const 10)))
    (i32.const 9))
)
