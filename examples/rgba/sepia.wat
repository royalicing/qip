(module $SepiaRGBA
  (memory (export "memory") 1)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0))
  (global $input_bytes_cap (export "input_bytes_cap") i32 (i32.const 0x10000))

  ;; Sepia intensity in [0, 1]. 0 = no effect, 1 = full sepia.
  (global $param_sepia (mut f32) (f32.const 1.0))
  (func (export "param_set_sepia") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 1.0)
        (f32.max (f32.const 0.0) (local.get $v))))
    (global.set $param_sepia (local.get $clamped))
    (local.get $clamped)
  )

  (func $apply_sepia (param $r f32) (param $g f32) (param $b f32) (param $channel i32) (result f32)
    (local $sepia_r f32)
    (local $sepia_g f32)
    (local $sepia_b f32)
    (local $result f32)
    (local $intensity f32)

    ;; Standard sepia matrix coefficients
    ;; R = 0.393*r + 0.769*g + 0.189*b
    ;; G = 0.349*r + 0.686*g + 0.168*b
    ;; B = 0.272*r + 0.534*g + 0.131*b
    
    (local.set $sepia_r
      (f32.add
        (f32.add
          (f32.mul (local.get $r) (f32.const 0.393))
          (f32.mul (local.get $g) (f32.const 0.769)))
        (f32.mul (local.get $b) (f32.const 0.189))))
    
    (local.set $sepia_g
      (f32.add
        (f32.add
          (f32.mul (local.get $r) (f32.const 0.349))
          (f32.mul (local.get $g) (f32.const 0.686)))
        (f32.mul (local.get $b) (f32.const 0.168))))
    
    (local.set $sepia_b
      (f32.add
        (f32.add
          (f32.mul (local.get $r) (f32.const 0.272))
          (f32.mul (local.get $g) (f32.const 0.534)))
        (f32.mul (local.get $b) (f32.const 0.131))))

    ;; Select the appropriate channel
    (local.set $result
      (if (result f32) (i32.eq (local.get $channel) (i32.const 0))
        (then (local.get $sepia_r))
        (else
          (if (result f32) (i32.eq (local.get $channel) (i32.const 1))
            (then (local.get $sepia_g))
            (else (local.get $sepia_b))))))

    ;; Get intensity parameter
    (local.set $intensity (global.get $param_sepia))

    ;; Blend original with sepia based on intensity
    (local.set $result
      (f32.add
        (f32.mul
          (if (result f32) (i32.eq (local.get $channel) (i32.const 0))
            (then (local.get $r))
            (else
              (if (result f32) (i32.eq (local.get $channel) (i32.const 1))
                (then (local.get $g))
                (else (local.get $b)))))
          (f32.sub (f32.const 1.0) (local.get $intensity)))
        (f32.mul (local.get $result) (local.get $intensity))))

    ;; Clamp to [0, 1]
    (f32.min
      (f32.const 1.0)
      (f32.max (f32.const 0.0) (local.get $result)))
  )

  (func (export "tile_rgba_f32_64x64") (param $ptr i32)
    (local $p i32)
    (local $end i32)
    (local $r f32)
    (local $g f32)
    (local $b f32)

    (local.set $p (local.get $ptr))
    (local.set $end (i32.add (local.get $ptr) (i32.const 0x10000)))
    (loop $sepia
      (local.set $r (f32.load (local.get $p)))
      (local.set $g (f32.load (i32.add (local.get $p) (i32.const 4))))
      (local.set $b (f32.load (i32.add (local.get $p) (i32.const 8))))

      (f32.store (local.get $p) (call $apply_sepia (local.get $r) (local.get $g) (local.get $b) (i32.const 0)))
      (f32.store (i32.add (local.get $p) (i32.const 4)) (call $apply_sepia (local.get $r) (local.get $g) (local.get $b) (i32.const 1)))
      (f32.store (i32.add (local.get $p) (i32.const 8)) (call $apply_sepia (local.get $r) (local.get $g) (local.get $b) (i32.const 2)))

      (local.set $p (i32.add (local.get $p) (i32.const 16)))
      (br_if $sepia (i32.lt_u (local.get $p) (local.get $end)))
    )
  )
)
