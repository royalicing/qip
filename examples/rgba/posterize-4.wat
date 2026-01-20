(module $Posterize4RGBA
  (memory (export "memory") 1)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0))
  (global $input_bytes_cap (export "input_bytes_cap") i32 (i32.const 0x10000))

  (func (export "tile_rgba_f32_64x64") (param $ptr i32)
    (local $p i32)
    (local $end i32)
    (local $v f32)

    (local.set $p (local.get $ptr))
    (local.set $end (i32.add (local.get $ptr) (i32.const 0x10000)))
    (loop $posterize
      (local.set $v
        (f32.div
          (f32.nearest (f32.mul (f32.load (local.get $p)) (f32.const 3.0)))
          (f32.const 3.0)))
      (f32.store (local.get $p) (local.get $v))

      (local.set $v
        (f32.div
          (f32.nearest (f32.mul (f32.load (i32.add (local.get $p) (i32.const 4))) (f32.const 3.0)))
          (f32.const 3.0)))
      (f32.store (i32.add (local.get $p) (i32.const 4)) (local.get $v))

      (local.set $v
        (f32.div
          (f32.nearest (f32.mul (f32.load (i32.add (local.get $p) (i32.const 8))) (f32.const 3.0)))
          (f32.const 3.0)))
      (f32.store (i32.add (local.get $p) (i32.const 8)) (local.get $v))

      (local.set $p (i32.add (local.get $p) (i32.const 16)))
      (br_if $posterize (i32.lt_u (local.get $p) (local.get $end)))
    )
  )
)
