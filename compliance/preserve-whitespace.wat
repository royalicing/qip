(module
  (import "qip" "render_must_equal"
    (func $render_must_equal (param i64 i32 i32 i32 i32) (result i32)))

  (memory (export "memory") 1)
  (data (i32.const 0) "  leading and trailing  ")
  (data (i32.const 32) "\09tabbed\09fields\09")
  (data (i32.const 64) "line1\0d\0aline2\0aline3\0d")
  (data (i32.const 96) " \09\0a\0d ")

  (func $expect_same (param $ordinal i64) (param $ptr i32) (param $size i32)
    (drop
      (call $render_must_equal
        (local.get $ordinal)
        (local.get $ptr)
        (local.get $size)
        (local.get $ptr)
        (local.get $size))))

  (func (export "comply") (result i32)
    (call $expect_same (i64.const 0) (i32.const 0) (i32.const 24))
    (call $expect_same (i64.const 1) (i32.const 32) (i32.const 15))
    (call $expect_same (i64.const 2) (i32.const 64) (i32.const 19))
    (call $expect_same (i64.const 3) (i32.const 96) (i32.const 5))
    (call $expect_same (i64.const 4) (i32.const 0) (i32.const 0))
    (i32.const 5))
)
