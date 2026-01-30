(module $BlackWhiteRGBA
  (memory (export "memory") 1)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0))
  (global $input_bytes_cap (export "input_bytes_cap") i32 (i32.const 0x10000))

  (func (export "tile_rgba_f32_64x64") (param $x f32) (param $y f32)
    (local $p i32)
    (local $end i32)
    (local $luma f32)

    (local.set $p (global.get $input_ptr))
    (local.set $end (i32.add (global.get $input_ptr) (i32.const 0x10000)))
    (loop $bw
      (local.set $luma
        (f32.add
          (f32.add
            (f32.mul (f32.load (local.get $p)) (f32.const 0.299))
            (f32.mul (f32.load (i32.add (local.get $p) (i32.const 4))) (f32.const 0.587)))
          (f32.mul (f32.load (i32.add (local.get $p) (i32.const 8))) (f32.const 0.114))))
      (f32.store (local.get $p) (local.get $luma))
      (f32.store (i32.add (local.get $p) (i32.const 4)) (local.get $luma))
      (f32.store (i32.add (local.get $p) (i32.const 8)) (local.get $luma))

      (local.set $p (i32.add (local.get $p) (i32.const 16)))
      (br_if $bw (i32.lt_u (local.get $p) (local.get $end)))
    )
  )
)
