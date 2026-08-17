(module
  (import "qip" "must_render_exactly"
    (func $must_render_exactly (param i64 i32 i32 i32 i32) (result i32)))

  (memory (export "memory") 1)
  (data (i32.const 0) "hello")
  (data (i32.const 32) "ASCII 123 !?")
  (data (i32.const 64) "line1\0aline2\09end")

  (func $expect_same (param $ordinal i64) (param $ptr i32) (param $size i32)
    (drop
      (call $must_render_exactly
        (local.get $ordinal)
        (local.get $ptr)
        (local.get $size)
        (local.get $ptr)
        (local.get $size))))

  (func (export "comply") (result i32)
    (call $expect_same (i64.const 0) (i32.const 0) (i32.const 5))
    (call $expect_same (i64.const 1) (i32.const 32) (i32.const 12))
    (call $expect_same (i64.const 2) (i32.const 64) (i32.const 15))
    (call $expect_same (i64.const 3) (i32.const 0) (i32.const 0))
    (i32.const 4))
)
