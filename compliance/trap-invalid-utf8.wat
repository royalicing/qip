(module
  (import "qip" "must_trap"
    (func $must_trap (param i64 i32 i32) (result i32)))

  (memory (export "memory") 1)

  ;; Invalid continuation, lone continuation, overlong encodings, truncated
  ;; sequences, surrogate code points, out-of-range code points, and invalid
  ;; leading bytes.
  (data (i32.const 0) "\c3\28")
  (data (i32.const 8) "\80")
  (data (i32.const 16) "\c0\af")
  (data (i32.const 24) "\e2\82")
  (data (i32.const 32) "\f0\9f\92")
  (data (i32.const 40) "\e0\80\80")
  (data (i32.const 48) "\ed\a0\80")
  (data (i32.const 56) "\f4\90\80\80")
  (data (i32.const 64) "\f5\80\80\80")
  (data (i32.const 72) "\fe")

  (func $expect_trap (param $ordinal i64) (param $ptr i32) (param $size i32)
    (drop
      (call $must_trap
        (local.get $ordinal)
        (local.get $ptr)
        (local.get $size))))

  (func (export "comply") (result i32)
    (call $expect_trap (i64.const 0) (i32.const 0) (i32.const 2))
    (call $expect_trap (i64.const 1) (i32.const 8) (i32.const 1))
    (call $expect_trap (i64.const 2) (i32.const 16) (i32.const 2))
    (call $expect_trap (i64.const 3) (i32.const 24) (i32.const 2))
    (call $expect_trap (i64.const 4) (i32.const 32) (i32.const 3))
    (call $expect_trap (i64.const 5) (i32.const 40) (i32.const 3))
    (call $expect_trap (i64.const 6) (i32.const 48) (i32.const 3))
    (call $expect_trap (i64.const 7) (i32.const 56) (i32.const 4))
    (call $expect_trap (i64.const 8) (i32.const 64) (i32.const 4))
    (call $expect_trap (i64.const 9) (i32.const 72) (i32.const 1))
    (i32.const 10))
)
