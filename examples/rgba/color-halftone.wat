(module $ColorHalftoneRGBA
  (memory (export "memory") 1)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0))
  (global $input_bytes_cap (export "input_bytes_cap") i32 (i32.const 0x10000))

  ;; Max dot radius in pixels.
  (global $uniform_max_radius (mut f32) (f32.const 6.0))
  (func (export "uniform_set_max_radius") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 24.0)
        (f32.max (f32.const 1.0) (local.get $v))))
    (global.set $uniform_max_radius (local.get $clamped))
    (local.get $clamped)
  )

  (global $uniform_sin_c (mut f32) (f32.const 0.0))
  (global $uniform_cos_c (mut f32) (f32.const 1.0))
  (global $uniform_sin_m (mut f32) (f32.const 0.0))
  (global $uniform_cos_m (mut f32) (f32.const 1.0))
  (global $uniform_sin_y (mut f32) (f32.const 0.0))
  (global $uniform_cos_y (mut f32) (f32.const 1.0))
  (global $uniform_sin_k (mut f32) (f32.const 0.0))
  (global $uniform_cos_k (mut f32) (f32.const 1.0))

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

  (func $sin_from_radians (param $v f32) (result f32)
    (local $x1 f32)
    (local $x2 f32)
    (local $x3 f32)
    (local $x4 f32)
    (local $x5 f32)
    (local.set $x1 (call $wrap_radians (local.get $v)))
    (if (f32.gt (local.get $x1) (f32.const 1.5707964))
      (then (local.set $x1 (f32.sub (f32.const 3.1415927) (local.get $x1)))))
    (if (f32.lt (local.get $x1) (f32.const -1.5707964))
      (then (local.set $x1 (f32.sub (f32.const -3.1415927) (local.get $x1)))))

    (local.set $x2 (f32.mul (local.get $x1) (local.get $x1)))
    (local.set $x3 (f32.mul (local.get $x2) (local.get $x1)))
    (local.set $x4 (f32.mul (local.get $x2) (local.get $x2)))
    (local.set $x5 (f32.mul (local.get $x4) (local.get $x1)))

    (f32.add
      (local.get $x1)
      (f32.add
        (f32.mul (local.get $x3) (f32.const -0.16666667))
        (f32.mul (local.get $x5) (f32.const 0.008333334))))
  )

  (func $cos_from_radians (param $v f32) (result f32)
    (local $x1 f32)
    (local $x2 f32)
    (local $x4 f32)
    (local $cos_sign f32)
    (local.set $x1 (call $wrap_radians (local.get $v)))
    (local.set $cos_sign (f32.const 1.0))
    (if (f32.gt (local.get $x1) (f32.const 1.5707964))
      (then
        (local.set $x1 (f32.sub (f32.const 3.1415927) (local.get $x1)))
        (local.set $cos_sign (f32.const -1.0))
      )
    )
    (if (f32.lt (local.get $x1) (f32.const -1.5707964))
      (then
        (local.set $x1 (f32.sub (f32.const -3.1415927) (local.get $x1)))
        (local.set $cos_sign (f32.const -1.0))
      )
    )

    (local.set $x2 (f32.mul (local.get $x1) (local.get $x1)))
    (local.set $x4 (f32.mul (local.get $x2) (local.get $x2)))

    (f32.mul
      (f32.add
        (f32.const 1.0)
        (f32.add
          (f32.mul (local.get $x2) (f32.const -0.5))
          (f32.mul (local.get $x4) (f32.const 0.041666668))))
      (local.get $cos_sign))
  )

  (func $set_angle (param $deg f32) (result f32)
    (local $rad f32)
    (local.set $rad (f32.mul (local.get $deg) (f32.const 0.017453292)))
    (local.get $rad)
  )

  (func (export "uniform_set_angle_c") (param $v f32) (result f32)
    (local $rad f32)
    (local.set $rad (call $set_angle (local.get $v)))
    (global.set $uniform_sin_c (call $sin_from_radians (local.get $rad)))
    (global.set $uniform_cos_c (call $cos_from_radians (local.get $rad)))
    (local.get $v)
  )

  (func (export "uniform_set_angle_m") (param $v f32) (result f32)
    (local $rad f32)
    (local.set $rad (call $set_angle (local.get $v)))
    (global.set $uniform_sin_m (call $sin_from_radians (local.get $rad)))
    (global.set $uniform_cos_m (call $cos_from_radians (local.get $rad)))
    (local.get $v)
  )

  (func (export "uniform_set_angle_y") (param $v f32) (result f32)
    (local $rad f32)
    (local.set $rad (call $set_angle (local.get $v)))
    (global.set $uniform_sin_y (call $sin_from_radians (local.get $rad)))
    (global.set $uniform_cos_y (call $cos_from_radians (local.get $rad)))
    (local.get $v)
  )

  (func (export "uniform_set_angle_k") (param $v f32) (result f32)
    (local $rad f32)
    (local.set $rad (call $set_angle (local.get $v)))
    (global.set $uniform_sin_k (call $sin_from_radians (local.get $rad)))
    (global.set $uniform_cos_k (call $cos_from_radians (local.get $rad)))
    (local.get $v)
  )

  (func $dot_mask
    (param $fx f32)
    (param $fy f32)
    (param $sin f32)
    (param $cos f32)
    (param $value f32)
    (param $cell f32)
    (result f32)
    (local $u f32)
    (local $v f32)
    (local $cell_inv f32)
    (local $cx f32)
    (local $cy f32)
    (local $dx f32)
    (local $dy f32)
    (local $dist2 f32)
    (local $r f32)
    (local $r2 f32)

    (if (f32.le (local.get $value) (f32.const 0.0))
      (then (return (f32.const 0.0))))

    (local.set $u
      (f32.sub
        (f32.mul (local.get $fx) (local.get $cos))
        (f32.mul (local.get $fy) (local.get $sin))))
    (local.set $v
      (f32.add
        (f32.mul (local.get $fx) (local.get $sin))
        (f32.mul (local.get $fy) (local.get $cos))))

    (local.set $cell_inv (f32.div (f32.const 1.0) (local.get $cell)))
    (local.set $cx
      (f32.mul
        (f32.add
          (f32.floor (f32.mul (local.get $u) (local.get $cell_inv)))
          (f32.const 0.5))
        (local.get $cell)))
    (local.set $cy
      (f32.mul
        (f32.add
          (f32.floor (f32.mul (local.get $v) (local.get $cell_inv)))
          (f32.const 0.5))
        (local.get $cell)))

    (local.set $dx (f32.sub (local.get $u) (local.get $cx)))
    (local.set $dy (f32.sub (local.get $v) (local.get $cy)))
    (local.set $dist2
      (f32.add
        (f32.mul (local.get $dx) (local.get $dx))
        (f32.mul (local.get $dy) (local.get $dy))))
    (local.set $r
      (f32.mul
        (f32.mul (local.get $cell) (f32.const 0.5))
        (local.get $value)))
    (local.set $r2 (f32.mul (local.get $r) (local.get $r)))

    (if (result f32) (f32.le (local.get $dist2) (local.get $r2))
      (then (f32.const 1.0))
      (else (f32.const 0.0))
    )
  )

  (func (export "tile_rgba_f32_64x64") (param $x f32) (param $y f32)
    (local $row i32)
    (local $col i32)
    (local $row_ptr i32)
    (local $p i32)
    (local $fx f32)
    (local $fy f32)
    (local $cell f32)
    (local $r f32)
    (local $g f32)
    (local $b f32)
    (local $a f32)
    (local $c f32)
    (local $m f32)
    (local $yval f32)
    (local $k f32)
    (local $den f32)
    (local $mask_c f32)
    (local $mask_m f32)
    (local $mask_y f32)
    (local $mask_k f32)
    (local $out_r f32)
    (local $out_g f32)
    (local $out_b f32)

    (local.set $cell
      (f32.mul (global.get $uniform_max_radius) (f32.const 2.0)))

    (local.set $row (i32.const 0))
    (loop $rows
      (local.set $fy
        (f32.add
          (f32.add (local.get $y) (f32.convert_i32_u (local.get $row)))
          (f32.const 0.5)))
      (local.set $row_ptr
        (i32.add
          (global.get $input_ptr)
          (i32.mul (local.get $row) (i32.const 1024))))

      (local.set $col (i32.const 0))
      (loop $cols
        (local.set $fx
          (f32.add
            (f32.add (local.get $x) (f32.convert_i32_u (local.get $col)))
            (f32.const 0.5)))
        (local.set $p
          (i32.add
            (local.get $row_ptr)
            (i32.mul (local.get $col) (i32.const 16))))

        (local.set $r (f32.load (local.get $p)))
        (local.set $g (f32.load (i32.add (local.get $p) (i32.const 4))))
        (local.set $b (f32.load (i32.add (local.get $p) (i32.const 8))))
        (local.set $a (f32.load (i32.add (local.get $p) (i32.const 12))))

        (local.set $c (f32.sub (f32.const 1.0) (local.get $r)))
        (local.set $m (f32.sub (f32.const 1.0) (local.get $g)))
        (local.set $yval (f32.sub (f32.const 1.0) (local.get $b)))
        (local.set $k
          (f32.min
            (local.get $c)
            (f32.min (local.get $m) (local.get $yval))))
        (local.set $den (f32.sub (f32.const 1.0) (local.get $k)))

        (if (f32.gt (local.get $den) (f32.const 0.00001))
          (then
            (local.set $c
              (f32.div (f32.sub (local.get $c) (local.get $k)) (local.get $den)))
            (local.set $m
              (f32.div (f32.sub (local.get $m) (local.get $k)) (local.get $den)))
            (local.set $yval
              (f32.div (f32.sub (local.get $yval) (local.get $k)) (local.get $den)))
          )
          (else
            (local.set $c (f32.const 0.0))
            (local.set $m (f32.const 0.0))
            (local.set $yval (f32.const 0.0))
          )
        )

        (local.set $mask_c
          (call $dot_mask
            (local.get $fx)
            (local.get $fy)
            (global.get $uniform_sin_c)
            (global.get $uniform_cos_c)
            (local.get $c)
            (local.get $cell)))
        (local.set $mask_m
          (call $dot_mask
            (local.get $fx)
            (local.get $fy)
            (global.get $uniform_sin_m)
            (global.get $uniform_cos_m)
            (local.get $m)
            (local.get $cell)))
        (local.set $mask_y
          (call $dot_mask
            (local.get $fx)
            (local.get $fy)
            (global.get $uniform_sin_y)
            (global.get $uniform_cos_y)
            (local.get $yval)
            (local.get $cell)))
        (local.set $mask_k
          (call $dot_mask
            (local.get $fx)
            (local.get $fy)
            (global.get $uniform_sin_k)
            (global.get $uniform_cos_k)
            (local.get $k)
            (local.get $cell)))

        (local.set $out_r
          (f32.sub
            (f32.const 1.0)
            (f32.min (f32.const 1.0) (f32.add (local.get $mask_c) (local.get $mask_k)))))
        (local.set $out_g
          (f32.sub
            (f32.const 1.0)
            (f32.min (f32.const 1.0) (f32.add (local.get $mask_m) (local.get $mask_k)))))
        (local.set $out_b
          (f32.sub
            (f32.const 1.0)
            (f32.min (f32.const 1.0) (f32.add (local.get $mask_y) (local.get $mask_k)))))

        (f32.store (local.get $p) (local.get $out_r))
        (f32.store (i32.add (local.get $p) (i32.const 4)) (local.get $out_g))
        (f32.store (i32.add (local.get $p) (i32.const 8)) (local.get $out_b))
        (f32.store (i32.add (local.get $p) (i32.const 12)) (local.get $a))

        (local.set $col (i32.add (local.get $col) (i32.const 1)))
        (br_if $cols (i32.lt_u (local.get $col) (i32.const 64)))
      )

      (local.set $row (i32.add (local.get $row) (i32.const 1)))
      (br_if $rows (i32.lt_u (local.get $row) (i32.const 64)))
    )
  )
)
