(module $GammaRGBA
  (memory (export "memory") 1)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0))
  (global $input_bytes_cap (export "input_bytes_cap") i32 (i32.const 0x10000))

  ;; Gamma in [0.5, 2.5]. 1.0 = no change, <1 = lighter, >1 = darker.
  (global $param_gamma (mut f32) (f32.const 1.0))
  (func (export "param_set_gamma") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 2.5)
        (f32.max (f32.const 0.5) (local.get $v))))
    (global.set $param_gamma (local.get $clamped))
    (local.get $clamped)
  )

  ;; Apply gamma correction using piecewise linear interpolation
  ;; Note: WASM doesn't have native pow function, so we use approximation:
  ;; For gamma in [0.5, 1.0]: interpolate between sqrt(v) and v
  ;; For gamma in [1.0, 2.5]: interpolate between v and v^2
  ;; This provides reasonable gamma correction for the typical range
  (func $apply_gamma (param $v f32) (result f32)
    (local $g f32)
    (local $t f32)
    (local $v_sqrt f32)
    (local $v_sq f32)
    
    (local.set $g (global.get $param_gamma))
    
    ;; Handle special cases
    (if (result f32) (f32.le (local.get $v) (f32.const 0.0))
      (then (f32.const 0.0))
      (else
        (if (result f32) (f32.eq (local.get $g) (f32.const 1.0))
          (then (local.get $v))
          (else
            (if (result f32) (f32.lt (local.get $g) (f32.const 1.0))
              (then
                ;; For gamma in [0.5, 1.0]: interpolate sqrt(v) and v
                ;; t = (gamma - 0.5) / 0.5 maps [0.5, 1.0] to [0, 1]
                (local.set $t (f32.mul (f32.sub (local.get $g) (f32.const 0.5)) (f32.const 2.0)))
                (local.set $v_sqrt (f32.sqrt (local.get $v)))
                ;; result = (1-t)*sqrt(v) + t*v
                (f32.add
                  (f32.mul (f32.sub (f32.const 1.0) (local.get $t)) (local.get $v_sqrt))
                  (f32.mul (local.get $t) (local.get $v))))
              (else
                ;; For gamma in [1.0, 2.5]: interpolate v and v^2
                ;; t = (gamma - 1.0) / 1.5 maps [1.0, 2.5] to [0, 1]
                (local.set $t (f32.div (f32.sub (local.get $g) (f32.const 1.0)) (f32.const 1.5)))
                (local.set $v_sq (f32.mul (local.get $v) (local.get $v)))
                ;; result = (1-t)*v + t*v^2
                (f32.add
                  (f32.mul (f32.sub (f32.const 1.0) (local.get $t)) (local.get $v))
                  (f32.mul (local.get $t) (local.get $v_sq)))))))))
  )

  (func (export "tile_rgba_f32_64x64") (param $ptr i32)
    (local $p i32)
    (local $end i32)
    (local $v f32)

    (local.set $p (local.get $ptr))
    (local.set $end (i32.add (local.get $ptr) (i32.const 0x10000)))
    (loop $gamma
      (local.set $v (call $apply_gamma (f32.load (local.get $p))))
      (f32.store (local.get $p) (local.get $v))

      (local.set $v (call $apply_gamma (f32.load (i32.add (local.get $p) (i32.const 4)))))
      (f32.store (i32.add (local.get $p) (i32.const 4)) (local.get $v))

      (local.set $v (call $apply_gamma (f32.load (i32.add (local.get $p) (i32.const 8)))))
      (f32.store (i32.add (local.get $p) (i32.const 8)) (local.get $v))

      (local.set $p (i32.add (local.get $p) (i32.const 16)))
      (br_if $gamma (i32.lt_u (local.get $p) (local.get $end)))
    )
  )
)
