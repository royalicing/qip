(module $TintRGBA
  (memory (export "memory") 1)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0))
  (global $input_bytes_cap (export "input_bytes_cap") i32 (i32.const 0x10000))

  ;; Tint in [-1, 1]. -1 adds magenta, +1 adds green.
  (global $param_tint (mut f32) (f32.const 0.0))
  (func (export "param_set_tint") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 1.0)
        (f32.max (f32.const -1.0) (local.get $v))))
    (global.set $param_tint (local.get $clamped))
    (local.get $clamped)
  )

  (func $clamp (param $v f32) (result f32)
    (f32.min
      (f32.const 1.0)
      (f32.max (f32.const 0.0) (local.get $v)))
  )

  (func (export "tile_rgba_f32_64x64") (param $x f32) (param $y f32)
    (local $p i32)
    (local $end i32)
    (local $t f32)
    (local $r_scale f32)
    (local $g_scale f32)
    (local $b_scale f32)
    (local $v f32)

    (local.set $p (global.get $input_ptr))
    (local.set $end (i32.add (global.get $input_ptr) (i32.const 0x10000)))
    (local.set $t (global.get $param_tint))
    (local.set $r_scale (f32.sub (f32.const 1.0) (f32.mul (local.get $t) (f32.const 0.05))))
    (local.set $g_scale (f32.add (f32.const 1.0) (f32.mul (local.get $t) (f32.const 0.10))))
    (local.set $b_scale (f32.sub (f32.const 1.0) (f32.mul (local.get $t) (f32.const 0.05))))
    (loop $tint
      (local.set $v (f32.mul (f32.load (local.get $p)) (local.get $r_scale)))
      (f32.store (local.get $p) (call $clamp (local.get $v)))

      (local.set $v (f32.mul (f32.load (i32.add (local.get $p) (i32.const 4))) (local.get $g_scale)))
      (f32.store (i32.add (local.get $p) (i32.const 4)) (call $clamp (local.get $v)))

      (local.set $v (f32.mul (f32.load (i32.add (local.get $p) (i32.const 8))) (local.get $b_scale)))
      (f32.store (i32.add (local.get $p) (i32.const 8)) (call $clamp (local.get $v)))

      (local.set $p (i32.add (local.get $p) (i32.const 16)))
      (br_if $tint (i32.lt_u (local.get $p) (local.get $end)))
    )
  )
)
