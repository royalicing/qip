(module $PosterizeRGBA
  (memory (export "memory") 1)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0))
  (global $input_bytes_cap (export "input_bytes_cap") i32 (i32.const 0x10000))

  (global $param_levels_count (mut i32) (i32.const 8))
  (func (export "param_set_levels_count") (param $v i32) (result i32)
    (if (i32.gt_u (local.get $v) (i32.const 255))
      (then (local.set $v (i32.const 255))))
    (global.set $param_levels_count (local.get $v))
    (local.get $v)
  )

  (func (export "tile_rgba_f32_64x64") (param $x f32) (param $y f32)
    (local $p i32)
    (local $end i32)
    (local $v f32)
    (local $denom f32)

    (local.set $p (global.get $input_ptr))
    (local.set $end (i32.add (global.get $input_ptr) (i32.const 0x10000)))
    (local.set $denom
      (f32.max
        (f32.const 1.0)
        (f32.sub (f32.convert_i32_u (global.get $param_levels_count)) (f32.const 1.0))))
    (loop $posterize
      (local.set $v
        (f32.div
          (f32.nearest (f32.mul (f32.load (local.get $p)) (local.get $denom)))
          (local.get $denom)))
      (f32.store (local.get $p) (local.get $v))

      (local.set $v
        (f32.div
          (f32.nearest (f32.mul (f32.load (i32.add (local.get $p) (i32.const 4))) (local.get $denom)))
          (local.get $denom)))
      (f32.store (i32.add (local.get $p) (i32.const 4)) (local.get $v))

      (local.set $v
        (f32.div
          (f32.nearest (f32.mul (f32.load (i32.add (local.get $p) (i32.const 8))) (local.get $denom)))
          (local.get $denom)))
      (f32.store (i32.add (local.get $p) (i32.const 8)) (local.get $v))

      (local.set $p (i32.add (local.get $p) (i32.const 16)))
      (br_if $posterize (i32.lt_u (local.get $p) (local.get $end)))
    )
  )
)
