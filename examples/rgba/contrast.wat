(module $ContrastRGBA
  (memory (export "memory") 1)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0))
  (global $input_bytes_cap (export "input_bytes_cap") i32 (i32.const 0x10000))

  ;; Contrast in [-1, 1]. Positive increases contrast, negative reduces it.
  (global $uniform_contrast (mut f32) (f32.const 0.0))
  (func (export "uniform_set_contrast") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 0.999)
        (f32.max (f32.const -0.999) (local.get $v))))
    (global.set $uniform_contrast (local.get $clamped))
    (local.get $clamped)
  )

  (func $apply_contrast (param $v f32) (result f32)
    (local $c f32)
    (local $factor f32)
    (local.set $c (global.get $uniform_contrast))
    (local.set $factor
      (if (result f32) (f32.ge (local.get $c) (f32.const 0.0))
        (then
          (f32.div
            (f32.const 1.0)
            (f32.sub (f32.const 1.0) (local.get $c))))
        (else
          (f32.add (f32.const 1.0) (local.get $c)))))
    (f32.min
      (f32.const 1.0)
      (f32.max
        (f32.const 0.0)
        (f32.add
          (f32.mul (f32.sub (local.get $v) (f32.const 0.5)) (local.get $factor))
          (f32.const 0.5))))
  )

  (func (export "tile_rgba_f32_64x64") (param $x f32) (param $y f32)
    (local $p i32)
    (local $end i32)
    (local $v f32)

    (local.set $p (global.get $input_ptr))
    (local.set $end (i32.add (global.get $input_ptr) (i32.const 0x10000)))
    (loop $contrast
      (local.set $v (call $apply_contrast (f32.load (local.get $p))))
      (f32.store (local.get $p) (local.get $v))

      (local.set $v (call $apply_contrast (f32.load (i32.add (local.get $p) (i32.const 4)))))
      (f32.store (i32.add (local.get $p) (i32.const 4)) (local.get $v))

      (local.set $v (call $apply_contrast (f32.load (i32.add (local.get $p) (i32.const 8)))))
      (f32.store (i32.add (local.get $p) (i32.const 8)) (local.get $v))

      (local.set $p (i32.add (local.get $p) (i32.const 16)))
      (br_if $contrast (i32.lt_u (local.get $p) (local.get $end)))
    )
  )
)
