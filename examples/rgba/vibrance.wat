(module $VibranceRGBA
  (memory (export "memory") 1)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0))
  (global $input_bytes_cap (export "input_bytes_cap") i32 (i32.const 0x10000))

  ;; Vibrance in [-1, 1]. Smart saturation that affects muted colors more.
  (global $param_vibrance (mut f32) (f32.const 0.0))
  (func (export "param_set_vibrance") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 1.0)
        (f32.max (f32.const -1.0) (local.get $v))))
    (global.set $param_vibrance (local.get $clamped))
    (local.get $clamped)
  )

  (func $max3 (param $a f32) (param $b f32) (param $c f32) (result f32)
    (f32.max (f32.max (local.get $a) (local.get $b)) (local.get $c))
  )

  (func $min3 (param $a f32) (param $b f32) (param $c f32) (result f32)
    (f32.min (f32.min (local.get $a) (local.get $b)) (local.get $c))
  )

  (func $apply_vibrance (param $v f32) (param $luma f32) (param $max_rgb f32) (param $avg f32) (result f32)
    (local $vib f32)
    (local $sat f32)
    (local $amt f32)

    (local.set $vib (global.get $param_vibrance))
    
    ;; Calculate current saturation (how different from gray)
    (local.set $sat 
      (f32.sub (local.get $max_rgb) 
        (f32.div
          (f32.add
            (f32.add (local.get $v) (local.get $luma))
            (local.get $avg))
          (f32.const 3.0))))
    
    ;; Vibrance affects less saturated colors more
    ;; Use inverse of saturation as a weight
    (local.set $amt
      (f32.mul
        (local.get $vib)
        (f32.sub (f32.const 1.0) (f32.min (f32.const 1.0) (local.get $sat)))))
    
    (local.set $amt (f32.add (f32.const 1.0) (local.get $amt)))

    (f32.min
      (f32.const 1.0)
      (f32.max
        (f32.const 0.0)
        (f32.add
          (local.get $luma)
          (f32.mul (f32.sub (local.get $v) (local.get $luma)) (local.get $amt)))))
  )

  (func (export "tile_rgba_f32_64x64") (param $ptr i32)
    (local $p i32)
    (local $end i32)
    (local $r f32)
    (local $g f32)
    (local $b f32)
    (local $luma f32)
    (local $max_rgb f32)
    (local $avg f32)

    (local.set $p (local.get $ptr))
    (local.set $end (i32.add (local.get $ptr) (i32.const 0x10000)))
    (loop $vibrance
      (local.set $r (f32.load (local.get $p)))
      (local.set $g (f32.load (i32.add (local.get $p) (i32.const 4))))
      (local.set $b (f32.load (i32.add (local.get $p) (i32.const 8))))
      
      ;; Calculate luma (perceived brightness)
      (local.set $luma
        (f32.add
          (f32.add
            (f32.mul (local.get $r) (f32.const 0.2126))
            (f32.mul (local.get $g) (f32.const 0.7152)))
          (f32.mul (local.get $b) (f32.const 0.0722))))

      ;; Calculate max RGB value for saturation detection
      (local.set $max_rgb (call $max3 (local.get $r) (local.get $g) (local.get $b)))
      
      ;; Calculate average
      (local.set $avg (f32.div (f32.add (f32.add (local.get $r) (local.get $g)) (local.get $b)) (f32.const 3.0)))

      (f32.store (local.get $p) (call $apply_vibrance (local.get $r) (local.get $luma) (local.get $max_rgb) (local.get $avg)))
      (f32.store (i32.add (local.get $p) (i32.const 4)) (call $apply_vibrance (local.get $g) (local.get $luma) (local.get $max_rgb) (local.get $avg)))
      (f32.store (i32.add (local.get $p) (i32.const 8)) (call $apply_vibrance (local.get $b) (local.get $luma) (local.get $max_rgb) (local.get $avg)))

      (local.set $p (i32.add (local.get $p) (i32.const 16)))
      (br_if $vibrance (i32.lt_u (local.get $p) (local.get $end)))
    )
  )
)
