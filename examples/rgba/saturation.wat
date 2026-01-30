(module $SaturationRGBA
  (memory (export "memory") 1)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0))
  (global $input_bytes_cap (export "input_bytes_cap") i32 (i32.const 0x10000))

  ;; Saturation in [-1, 1]. -1 = grayscale, 0 = unchanged, +1 = 2x saturation.
  (global $param_saturation (mut f32) (f32.const 0.0))
  (func (export "param_set_saturation") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 1.0)
        (f32.max (f32.const -1.0) (local.get $v))))
    (global.set $param_saturation (local.get $clamped))
    (local.get $clamped)
  )

  (func $apply_saturation (param $v f32) (param $luma f32) (result f32)
    (local $f f32)
    (local.set $f (f32.add (f32.const 1.0) (global.get $param_saturation)))
    (f32.min
      (f32.const 1.0)
      (f32.max
        (f32.const 0.0)
        (f32.add
          (local.get $luma)
          (f32.mul (f32.sub (local.get $v) (local.get $luma)) (local.get $f)))))
  )

  (func (export "tile_rgba_f32_64x64") (param $x f32) (param $y f32)
    (local $p i32)
    (local $end i32)
    (local $r f32)
    (local $g f32)
    (local $b f32)
    (local $luma f32)

    (local.set $p (global.get $input_ptr))
    (local.set $end (i32.add (global.get $input_ptr) (i32.const 0x10000)))
    (loop $saturation
      (local.set $r (f32.load (local.get $p)))
      (local.set $g (f32.load (i32.add (local.get $p) (i32.const 4))))
      (local.set $b (f32.load (i32.add (local.get $p) (i32.const 8))))
      (local.set $luma
        (f32.add
          (f32.add
            (f32.mul (local.get $r) (f32.const 0.2126))
            (f32.mul (local.get $g) (f32.const 0.7152)))
          (f32.mul (local.get $b) (f32.const 0.0722))))

      (f32.store (local.get $p) (call $apply_saturation (local.get $r) (local.get $luma)))
      (f32.store (i32.add (local.get $p) (i32.const 4)) (call $apply_saturation (local.get $g) (local.get $luma)))
      (f32.store (i32.add (local.get $p) (i32.const 8)) (call $apply_saturation (local.get $b) (local.get $luma)))

      (local.set $p (i32.add (local.get $p) (i32.const 16)))
      (br_if $saturation (i32.lt_u (local.get $p) (local.get $end)))
    )
  )
)
