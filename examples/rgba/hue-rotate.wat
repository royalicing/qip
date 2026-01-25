(module $HueRotateRGBA
  (memory (export "memory") 1)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0))
  (global $input_bytes_cap (export "input_bytes_cap") i32 (i32.const 0x10000))

  ;; Hue rotation in degrees. Any value is accepted; it's wrapped to [-180, 180].
  (global $param_hue_degrees (mut f32) (f32.const 0.0))
  (func (export "param_set_hue_degrees") (param $v f32) (result f32)
    (global.set $param_hue_degrees (local.get $v))
    (local.get $v)
  )

  (func $wrap_radians (param $v f32) (result f32)
    (local $k f32)
    (local $x f32)
    (local.set $x (local.get $v))
    (local.set $k
      (f32.floor (f32.div (local.get $x) (f32.const 6.2831855))))
    (local.set $x
      (f32.sub (local.get $x) (f32.mul (local.get $k) (f32.const 6.2831855))))
    (if (f32.gt (local.get $x) (f32.const 3.1415927))
      (then (local.set $x (f32.sub (local.get $x) (f32.const 6.2831855)))))
    (local.get $x)
  )

  (func $clamp (param $v f32) (result f32)
    (f32.min
      (f32.const 1.0)
      (f32.max (f32.const 0.0) (local.get $v)))
  )

  (func (export "tile_rgba_f32_64x64") (param $ptr i32)
    (local $p i32)
    (local $end i32)
    (local $r f32)
    (local $g f32)
    (local $b f32)
    (local $angle f32)
    (local $x f32)
    (local $x2 f32)
    (local $x3 f32)
    (local $x4 f32)
    (local $x5 f32)
    (local $cos_sign f32)
    (local $sin f32)
    (local $cos f32)
    (local $a00 f32)
    (local $a01 f32)
    (local $a02 f32)
    (local $a10 f32)
    (local $a11 f32)
    (local $a12 f32)
    (local $a20 f32)
    (local $a21 f32)
    (local $a22 f32)
    (local $nr f32)
    (local $ng f32)
    (local $nb f32)

    (local.set $p (local.get $ptr))
    (local.set $end (i32.add (local.get $ptr) (i32.const 0x10000)))
    (local.set $angle
      (call $wrap_radians
        (f32.mul (global.get $param_hue_degrees) (f32.const 0.017453292))))

    (local.set $x (local.get $angle))
    (local.set $cos_sign (f32.const 1.0))
    (if (f32.gt (local.get $x) (f32.const 1.5707964))
      (then
        (local.set $x (f32.sub (f32.const 3.1415927) (local.get $x)))
        (local.set $cos_sign (f32.const -1.0))
      )
    )
    (if (f32.lt (local.get $x) (f32.const -1.5707964))
      (then
        (local.set $x (f32.sub (f32.const -3.1415927) (local.get $x)))
        (local.set $cos_sign (f32.const -1.0))
      )
    )

    (local.set $x2 (f32.mul (local.get $x) (local.get $x)))
    (local.set $x3 (f32.mul (local.get $x2) (local.get $x)))
    (local.set $x4 (f32.mul (local.get $x2) (local.get $x2)))
    (local.set $x5 (f32.mul (local.get $x4) (local.get $x)))

    (local.set $sin
      (f32.add
        (local.get $x)
        (f32.add
          (f32.mul (local.get $x3) (f32.const -0.16666667))
          (f32.mul (local.get $x5) (f32.const 0.008333334)))))
    (local.set $cos
      (f32.add
        (f32.const 1.0)
        (f32.add
          (f32.mul (local.get $x2) (f32.const -0.5))
          (f32.mul (local.get $x4) (f32.const 0.041666668)))))
    (local.set $cos (f32.mul (local.get $cos) (local.get $cos_sign)))

    (local.set $a00
      (f32.add
        (f32.add (f32.const 0.213) (f32.mul (local.get $cos) (f32.const 0.787)))
        (f32.mul (local.get $sin) (f32.const -0.213))))
    (local.set $a01
      (f32.add
        (f32.sub (f32.const 0.715) (f32.mul (local.get $cos) (f32.const 0.715)))
        (f32.mul (local.get $sin) (f32.const -0.715))))
    (local.set $a02
      (f32.add
        (f32.sub (f32.const 0.072) (f32.mul (local.get $cos) (f32.const 0.072)))
        (f32.mul (local.get $sin) (f32.const 0.928))))

    (local.set $a10
      (f32.add
        (f32.sub (f32.const 0.213) (f32.mul (local.get $cos) (f32.const 0.213)))
        (f32.mul (local.get $sin) (f32.const 0.143))))
    (local.set $a11
      (f32.add
        (f32.add (f32.const 0.715) (f32.mul (local.get $cos) (f32.const 0.285)))
        (f32.mul (local.get $sin) (f32.const 0.140))))
    (local.set $a12
      (f32.add
        (f32.sub (f32.const 0.072) (f32.mul (local.get $cos) (f32.const 0.072)))
        (f32.mul (local.get $sin) (f32.const -0.283))))

    (local.set $a20
      (f32.add
        (f32.sub (f32.const 0.213) (f32.mul (local.get $cos) (f32.const 0.213)))
        (f32.mul (local.get $sin) (f32.const -0.787))))
    (local.set $a21
      (f32.add
        (f32.sub (f32.const 0.715) (f32.mul (local.get $cos) (f32.const 0.715)))
        (f32.mul (local.get $sin) (f32.const 0.715))))
    (local.set $a22
      (f32.add
        (f32.add (f32.const 0.072) (f32.mul (local.get $cos) (f32.const 0.928)))
        (f32.mul (local.get $sin) (f32.const 0.072))))

    (loop $hue
      (local.set $r (f32.load (local.get $p)))
      (local.set $g (f32.load (i32.add (local.get $p) (i32.const 4))))
      (local.set $b (f32.load (i32.add (local.get $p) (i32.const 8))))

      ;; SVG/CSS hue rotation matrix with Rec. 709 luma coefficients.
      (local.set $nr
        (f32.add
          (f32.add
            (f32.mul (local.get $r) (local.get $a00))
            (f32.mul (local.get $g) (local.get $a01)))
          (f32.mul (local.get $b) (local.get $a02))))

      (local.set $ng
        (f32.add
          (f32.add
            (f32.mul (local.get $r) (local.get $a10))
            (f32.mul (local.get $g) (local.get $a11)))
          (f32.mul (local.get $b) (local.get $a12))))

      (local.set $nb
        (f32.add
          (f32.add
            (f32.mul (local.get $r) (local.get $a20))
            (f32.mul (local.get $g) (local.get $a21)))
          (f32.mul (local.get $b) (local.get $a22))))

      (f32.store (local.get $p) (call $clamp (local.get $nr)))
      (f32.store (i32.add (local.get $p) (i32.const 4)) (call $clamp (local.get $ng)))
      (f32.store (i32.add (local.get $p) (i32.const 8)) (call $clamp (local.get $nb)))

      (local.set $p (i32.add (local.get $p) (i32.const 16)))
      (br_if $hue (i32.lt_u (local.get $p) (local.get $end)))
    )
  )
)
