(module
  (import "qip" "must_render_exactly"
    (func $must_render_exactly (param i64 i32 i32 i32 i32) (result i32)))

  (memory (export "memory") 1)

  (data (i32.const 0) "+1 (415) 555-2671")
  (data (i32.const 32) "+14155552671")
  (data (i32.const 64) "  1212-555-0100  ")
  (data (i32.const 96) "+12125550100")
  (data (i32.const 128) "5552671")
  (data (i32.const 160) "+5552671")
  (data (i32.const 192) "abc")
  (data (i32.const 224) "+")
  (data (i32.const 256) "0044 20 7946 0958")
  (data (i32.const 288) "+00442079460958")
  (data (i32.const 320) "1-2-3")
  (data (i32.const 352) "+123")

  (func $expect
    (param $ordinal i64)
    (param $input_ptr i32)
    (param $input_size i32)
    (param $expected_ptr i32)
    (param $expected_size i32)
    (drop
      (call $must_render_exactly
        (local.get $ordinal)
        (local.get $input_ptr)
        (local.get $input_size)
        (local.get $expected_ptr)
        (local.get $expected_size))))

  (func (export "comply") (result i32)
    (call $expect (i64.const 0) (i32.const 0) (i32.const 17) (i32.const 32) (i32.const 12))
    (call $expect (i64.const 1) (i32.const 64) (i32.const 17) (i32.const 96) (i32.const 12))
    (call $expect (i64.const 2) (i32.const 128) (i32.const 7) (i32.const 160) (i32.const 8))
    (call $expect (i64.const 3) (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0))
    (call $expect (i64.const 4) (i32.const 192) (i32.const 3) (i32.const 0) (i32.const 0))
    (call $expect (i64.const 5) (i32.const 224) (i32.const 1) (i32.const 0) (i32.const 0))
    (call $expect (i64.const 6) (i32.const 256) (i32.const 17) (i32.const 288) (i32.const 15))
    (call $expect (i64.const 7) (i32.const 320) (i32.const 5) (i32.const 352) (i32.const 4))
    (i32.const 8))
)
