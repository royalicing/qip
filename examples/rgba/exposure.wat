(module $ExposureRGBA
  (memory (export "memory") 1)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0))
  (global $input_bytes_cap (export "input_bytes_cap") i32 (i32.const 0x10000))

  ;; Exposure in [-2, 2]. Simulates camera exposure stops.
  (global $param_exposure (mut f32) (f32.const 0.0))
  (func (export "param_set_exposure") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 2.0)
        (f32.max (f32.const -2.0) (local.get $v))))
    (global.set $param_exposure (local.get $clamped))
    (local.get $clamped)
  )

  (func $pow2 (param $x f32) (result f32)
    ;; Approximate 2^x using exp2-like behavior
    ;; For small range [-2, 2], use simple approximation: 2^x ≈ 1 + x*ln(2) + (x*ln(2))^2/2
    (local $ln2 f32)
    (local $term f32)
    (local $result f32)
    
    (local.set $ln2 (f32.const 0.693147))
    (local.set $term (f32.mul (local.get $x) (local.get $ln2)))
    
    ;; Better approximation: use exp identity
    ;; For now, use multiplication for powers of 2
    ;; 2^x = 2 * 2 * ... (x times for positive, 1/2 for negative)
    
    ;; Simple case for common values
    (if (result f32) (f32.eq (local.get $x) (f32.const 0.0))
      (then (f32.const 1.0))
      (else
        (if (result f32) (f32.gt (local.get $x) (f32.const 0.0))
          (then
            ;; Positive exposure: multiply by 2^x
            ;; Approximate: 2^x for x in [0, 2]
            (f32.mul
              (f32.add (f32.const 1.0) (local.get $term))
              (f32.add (f32.const 1.0) (f32.mul (local.get $term) (f32.const 0.5)))))
          (else
            ;; Negative exposure: divide by 2^|x|
            (f32.div
              (f32.const 1.0)
              (f32.mul
                (f32.add (f32.const 1.0) (f32.mul (f32.neg (local.get $x)) (local.get $ln2)))
                (f32.add (f32.const 1.0) (f32.mul (f32.mul (f32.neg (local.get $x)) (local.get $ln2)) (f32.const 0.5)))))))))
  )

  (func $apply_exposure (param $v f32) (result f32)
    (local $exp f32)
    (local $multiplier f32)
    
    (local.set $exp (global.get $param_exposure))
    (local.set $multiplier (call $pow2 (local.get $exp)))
    
    (f32.min
      (f32.const 1.0)
      (f32.max
        (f32.const 0.0)
        (f32.mul (local.get $v) (local.get $multiplier))))
  )

  (func (export "tile_rgba_f32_64x64") (param $ptr i32)
    (local $p i32)
    (local $end i32)
    (local $v f32)

    (local.set $p (local.get $ptr))
    (local.set $end (i32.add (local.get $ptr) (i32.const 0x10000)))
    (loop $exposure
      (local.set $v (call $apply_exposure (f32.load (local.get $p))))
      (f32.store (local.get $p) (local.get $v))

      (local.set $v (call $apply_exposure (f32.load (i32.add (local.get $p) (i32.const 4)))))
      (f32.store (i32.add (local.get $p) (i32.const 4)) (local.get $v))

      (local.set $v (call $apply_exposure (f32.load (i32.add (local.get $p) (i32.const 8)))))
      (f32.store (i32.add (local.get $p) (i32.const 8)) (local.get $v))

      (local.set $p (i32.add (local.get $p) (i32.const 16)))
      (br_if $exposure (i32.lt_u (local.get $p) (local.get $end)))
    )
  )
)
