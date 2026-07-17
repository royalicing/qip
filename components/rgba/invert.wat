(module $InvertRGBA
  (memory (export "memory") 1 1)
  (global $input_ptr i32 (i32.const 0))
  (func (export "input_ptr") (result i32)
    (global.get $input_ptr))
  (global $input_bytes_cap i32 (i32.const 0x10000))
  (func (export "input_bytes_cap") (result i32)
    (global.get $input_bytes_cap))

  (func (export "tile_rgba32float_64x64") (param $x f32) (param $y f32)
    (local $p i32)
    (local $end i32)
    (local $v f32)

    (local.set $p (global.get $input_ptr))
    (local.set $end (i32.add (global.get $input_ptr) (i32.const 0x10000)))
    (loop $invert
      (local.set $v (f32.sub (f32.const 1.0) (f32.load (local.get $p))))
      (f32.store (local.get $p) (local.get $v))
      (local.set $v (f32.sub (f32.const 1.0) (f32.load (i32.add (local.get $p) (i32.const 4)))))
      (f32.store (i32.add (local.get $p) (i32.const 4)) (local.get $v))
      (local.set $v (f32.sub (f32.const 1.0) (f32.load (i32.add (local.get $p) (i32.const 8)))))
      (f32.store (i32.add (local.get $p) (i32.const 8)) (local.get $v))

      (local.set $p (i32.add (local.get $p) (i32.const 16)))
      (br_if $invert (i32.lt_u (local.get $p) (local.get $end)))
    )
  )
)
