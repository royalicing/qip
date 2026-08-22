(module
  (import "qip" "must_render_exactly"
    (func $must_render_exactly (param i64 i32 i32 i32 i32) (result i32)))

  (memory (export "memory") 1)

  (func (export "comply") (result i32)
    ;; 4,096 zero bytes encode as 5,462 'A' bytes followed by "==".
    ;; This exercises many loop iterations and padding without prescribing an
    ;; implementation's maximum capacity.
    (memory.fill (i32.const 4096) (i32.const 65) (i32.const 5462))
    (i32.store8 (i32.const 9558) (i32.const 61))
    (i32.store8 (i32.const 9559) (i32.const 61))
    (drop
      (call $must_render_exactly
        (i64.const 0)
        (i32.const 0) (i32.const 4096)
        (i32.const 4096) (i32.const 5464)))
    (i32.const 1))
)
