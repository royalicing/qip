(module
  (import "qip" "must_render_exactly"
    (func $must_render_exactly (param i64 i32 i32 i32 i32) (result i32)))
  (import "qip" "must_reject"
    (func $must_reject (param i64 i32 i32) (result i32)))

  (memory (export "memory") 1)

  (data (i32.const 0) "TQ==")
  (data (i32.const 8) "TWE=")
  (data (i32.const 16) "TWFu")
  (data (i32.const 32) "A")
  (data (i32.const 40) "!!!!")
  (data (i32.const 48) "A===")
  (data (i32.const 56) "TQ=A")
  (data (i32.const 64) "TQ==AAAA")
  (data (i32.const 80) "TR==")
  (data (i32.const 88) "TWF=")

  (data (i32.const 128) "M")
  (data (i32.const 136) "Ma")
  (data (i32.const 144) "Man")

  (func (export "comply") (result i32)
    ;; Empty input is valid empty output.
    (drop
      (call $must_render_exactly
        (i64.const 0) (i32.const 0) (i32.const 0) (i32.const 128) (i32.const 0)))
    (drop
      (call $must_render_exactly
        (i64.const 1) (i32.const 0) (i32.const 4) (i32.const 128) (i32.const 1)))
    (drop
      (call $must_render_exactly
        (i64.const 2) (i32.const 8) (i32.const 4) (i32.const 136) (i32.const 2)))
    (drop
      (call $must_render_exactly
        (i64.const 3) (i32.const 16) (i32.const 4) (i32.const 144) (i32.const 3)))

    ;; Reject incomplete quartets, invalid alphabet bytes, misplaced padding,
    ;; padding before the final quartet, and non-zero unused pad bits.
    (drop (call $must_reject (i64.const 4) (i32.const 32) (i32.const 1)))
    (drop (call $must_reject (i64.const 5) (i32.const 40) (i32.const 4)))
    (drop (call $must_reject (i64.const 6) (i32.const 48) (i32.const 4)))
    (drop (call $must_reject (i64.const 7) (i32.const 56) (i32.const 4)))
    (drop (call $must_reject (i64.const 8) (i32.const 64) (i32.const 8)))
    (drop (call $must_reject (i64.const 9) (i32.const 80) (i32.const 4)))
    (drop (call $must_reject (i64.const 10) (i32.const 88) (i32.const 4)))
    (i32.const 11))
)
