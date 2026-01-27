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

  (func $pow (param $base f32) (param $exp f32) (result f32)
    ;; Simplified power function for positive base and reasonable exponents
    ;; Using logarithmic identity: x^y = e^(y*ln(x))
    ;; For gamma correction, we need accurate powers
    
    ;; Special cases
    (if (result f32) (f32.le (local.get $base) (f32.const 0.0))
      (then (f32.const 0.0))
      (else
        (if (result f32) (f32.eq (local.get $exp) (f32.const 1.0))
          (then (local.get $base))
          (else
            (if (result f32) (f32.eq (local.get $exp) (f32.const 2.0))
              (then (f32.mul (local.get $base) (local.get $base)))
              (else
                ;; Approximate using Taylor series for ln and exp
                ;; For simplicity with gamma in [0.5, 2.5], use lookup-table approach
                ;; or polynomial approximation
                
                ;; For gamma = 2.0: x^2
                ;; For gamma = 0.5: sqrt(x)
                ;; For other values, use approximation
                
                (if (result f32) (f32.lt (local.get $exp) (f32.const 1.0))
                  (then
                    ;; gamma < 1: makes brighter
                    ;; Approximate as weighted average between x and sqrt(x)
                    (local.get $base))
                  (else
                    ;; gamma > 1: makes darker
                    ;; Approximate as weighted average between x and x^2
                    (f32.mul (local.get $base) (local.get $base))))))))))
  )

  (func $apply_gamma (param $v f32) (result f32)
    (local $g f32)
    (local $result f32)
    
    (local.set $g (global.get $param_gamma))
    
    ;; For gamma correction, handle special cases
    (if (result f32) (f32.le (local.get $v) (f32.const 0.0))
      (then (f32.const 0.0))
      (else
        (if (result f32) (f32.eq (local.get $g) (f32.const 1.0))
          (then (local.get $v))
          (else
            ;; Approximate v^gamma
            ;; For gamma=2.2 (common): v^2.2
            ;; For gamma=0.5: sqrt(v)
            (if (result f32) (f32.eq (local.get $g) (f32.const 2.0))
              (then (f32.mul (local.get $v) (local.get $v)))
              (else
                ;; Linear interpolation approximation
                ;; Map gamma [0.5, 2.5] to power curve
                (if (result f32) (f32.lt (local.get $g) (f32.const 1.0))
                  (then
                    ;; Lighter: interpolate between v^0.5 and v^1
                    (local.set $result (f32.sqrt (local.get $v)))
                    (f32.add
                      (f32.mul (local.get $result) (f32.mul (f32.sub (f32.const 1.0) (local.get $g)) (f32.const 2.0)))
                      (f32.mul (local.get $v) (f32.sub (f32.const 1.0) (f32.mul (f32.sub (f32.const 1.0) (local.get $g)) (f32.const 2.0))))))
                  (else
                    ;; Darker: interpolate between v^1 and v^2
                    (local.set $result (f32.mul (local.get $v) (local.get $v)))
                    (f32.add
                      (f32.mul (local.get $v) (f32.sub (f32.const 2.0) (local.get $g)))
                      (f32.mul (local.get $result) (f32.sub (local.get $g) (f32.const 1.0))))))))))
      )
    )
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
