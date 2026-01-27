(module $VignetteRGBA
  (memory (export "memory") 1)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0))
  (global $input_bytes_cap (export "input_bytes_cap") i32 (i32.const 0x10000))

  ;; Vignette strength in [0, 1]. 0 = no effect, 1 = strong darkening.
  (global $param_vignette (mut f32) (f32.const 0.5))
  (func (export "param_set_vignette") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 1.0)
        (f32.max (f32.const 0.0) (local.get $v))))
    (global.set $param_vignette (local.get $clamped))
    (local.get $clamped)
  )

  (func $apply_vignette (param $v f32) (param $x i32) (param $y i32) (result f32)
    (local $dx f32)
    (local $dy f32)
    (local $dist f32)
    (local $factor f32)
    (local $strength f32)
    
    ;; Calculate distance from center (32, 32) normalized to [0, 1]
    ;; Tile is 64x64, so center is at (32, 32)
    (local.set $dx (f32.sub (f32.convert_i32_u (local.get $x)) (f32.const 32.0)))
    (local.set $dy (f32.sub (f32.convert_i32_u (local.get $y)) (f32.const 32.0)))
    
    ;; Distance from center, normalized
    ;; Max distance from center to corner: sqrt(32^2 + 32^2) = 45.25
    (local.set $dist
      (f32.div
        (f32.sqrt
          (f32.add
            (f32.mul (local.get $dx) (local.get $dx))
            (f32.mul (local.get $dy) (local.get $dy))))
        (f32.const 45.25)))
    
    ;; Apply vignette: darker towards edges
    ;; factor = 1 - (dist^2 * strength)
    (local.set $strength (global.get $param_vignette))
    (local.set $factor
      (f32.sub
        (f32.const 1.0)
        (f32.mul
          (f32.mul (local.get $dist) (local.get $dist))
          (local.get $strength))))
    
    ;; Ensure factor is in [0, 1]
    (local.set $factor
      (f32.max (f32.const 0.0) (f32.min (f32.const 1.0) (local.get $factor))))
    
    ;; Apply to color value
    (f32.mul (local.get $v) (local.get $factor))
  )

  (func (export "tile_rgba_f32_64x64") (param $ptr i32)
    (local $p i32)
    (local $end i32)
    (local $x i32)
    (local $y i32)
    (local $v f32)

    (local.set $p (local.get $ptr))
    (local.set $end (i32.add (local.get $ptr) (i32.const 0x10000)))
    (local.set $y (i32.const 0))
    
    (loop $row
      (local.set $x (i32.const 0))
      (loop $col
        ;; Process RGB (skip alpha at +12)
        (local.set $v (call $apply_vignette (f32.load (local.get $p)) (local.get $x) (local.get $y)))
        (f32.store (local.get $p) (local.get $v))

        (local.set $v (call $apply_vignette (f32.load (i32.add (local.get $p) (i32.const 4))) (local.get $x) (local.get $y)))
        (f32.store (i32.add (local.get $p) (i32.const 4)) (local.get $v))

        (local.set $v (call $apply_vignette (f32.load (i32.add (local.get $p) (i32.const 8))) (local.get $x) (local.get $y)))
        (f32.store (i32.add (local.get $p) (i32.const 8)) (local.get $v))

        (local.set $p (i32.add (local.get $p) (i32.const 16)))
        (local.set $x (i32.add (local.get $x) (i32.const 1)))
        (br_if $col (i32.lt_u (local.get $x) (i32.const 64)))
      )
      (local.set $y (i32.add (local.get $y) (i32.const 1)))
      (br_if $row (i32.lt_u (local.get $y) (i32.const 64)))
    )
  )
)
