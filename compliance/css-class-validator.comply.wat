(module
  (import "qip" "must_render_exactly"
    (func $must_render_exactly (param i64 i32 i32 i32 i32) (result i32)))
  (import "qip" "must_reject"
    (func $must_reject (param i64 i32 i32) (result i32)))

  (memory (export "memory") 1)

  (data (i32.const 0) "btn-primary")
  (data (i32.const 32) "  hover:text-red-500  ")
  (data (i32.const 64) "hover:text-red-500")
  (data (i32.const 96) "w-1/2")
  (data (i32.const 128) "   ")
  (data (i32.const 144) "two classes")
  (data (i32.const 160) "two\09classes")

  (func (export "comply") (result i32)
    (drop
      (call $must_render_exactly
        (i64.const 0) (i32.const 0) (i32.const 11) (i32.const 0) (i32.const 11)))
    (drop
      (call $must_render_exactly
        (i64.const 1) (i32.const 32) (i32.const 22) (i32.const 64) (i32.const 18)))
    (drop
      (call $must_render_exactly
        (i64.const 2) (i32.const 96) (i32.const 5) (i32.const 96) (i32.const 5)))

    (drop (call $must_reject (i64.const 3) (i32.const 0) (i32.const 0)))
    (drop (call $must_reject (i64.const 4) (i32.const 128) (i32.const 3)))
    (drop (call $must_reject (i64.const 5) (i32.const 144) (i32.const 11)))
    (drop (call $must_reject (i64.const 6) (i32.const 160) (i32.const 11)))
    (i32.const 7))
)
