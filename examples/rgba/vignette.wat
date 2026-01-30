(module $VignetteRGBA
  (memory (export "memory") 1)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0))
  (global $input_bytes_cap (export "input_bytes_cap") i32 (i32.const 0x10000))

  (global $uniform_width (mut f32) (f32.const 0.0))
  (global $uniform_height (mut f32) (f32.const 0.0))

  (func (export "uniform_set_width_and_height") (param $width f32) (param $height f32)
    (global.set $uniform_width (local.get $width))
    (global.set $uniform_height (local.get $height))
  )

  ;; Amount in [0, 1]. 0 = none, 1 = full strength.
  (global $param_amount (mut f32) (f32.const 0.5))
  (func (export "param_set_amount") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 1.0)
        (f32.max (f32.const 0.0) (local.get $v))))
    (global.set $param_amount (local.get $clamped))
    (local.get $clamped)
  )

  ;; Midpoint in [0, 1]. 1.0 means no vignette.
  (global $param_midpoint (mut f32) (f32.const 0.75))
  (func (export "param_set_midpoint") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 0.999)
        (f32.max (f32.const 0.0) (local.get $v))))
    (global.set $param_midpoint (local.get $clamped))
    (local.get $clamped)
  )

  ;; Feather in [0, 1]. 0 = hard edge, 1 = very soft.
  (global $param_feather (mut f32) (f32.const 0.5))
  (func (export "param_set_feather") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 1.0)
        (f32.max (f32.const 0.0) (local.get $v))))
    (global.set $param_feather (local.get $clamped))
    (local.get $clamped)
  )

  (func (export "tile_rgba_f32_64x64") (param $x f32) (param $y f32)
    (local $row i32)
    (local $col i32)
    (local $row_ptr i32)
    (local $p i32)
    (local $w f32)
    (local $h f32)
    (local $inv_w f32)
    (local $inv_h f32)
    (local $aspect f32)
    (local $amount f32)
    (local $midpoint f32)
    (local $feather f32)
    (local $edge f32)
    (local $fx f32)
    (local $fy f32)
    (local $dx f32)
    (local $dy f32)
    (local $dist f32)
    (local $max_dist f32)
    (local $inv_max_dist f32)
    (local $t f32)
    (local $smooth f32)
    (local $factor f32)

    (local.set $w (global.get $uniform_width))
    (local.set $h (global.get $uniform_height))
    (if (i32.or
          (f32.le (local.get $w) (f32.const 0.0))
          (f32.le (local.get $h) (f32.const 0.0)))
      (then (return))
    )

    (local.set $inv_w (f32.div (f32.const 1.0) (local.get $w)))
    (local.set $inv_h (f32.div (f32.const 1.0) (local.get $h)))
    (local.set $aspect (f32.div (local.get $w) (local.get $h)))
    (local.set $max_dist
      (f32.sqrt
        (f32.add
          (f32.mul (local.get $aspect) (local.get $aspect))
          (f32.const 1.0))))
    (local.set $inv_max_dist (f32.div (f32.const 1.0) (local.get $max_dist)))
    (local.set $amount (global.get $param_amount))
    (local.set $midpoint (global.get $param_midpoint))
    (local.set $feather (global.get $param_feather))
    (local.set $edge
      (f32.add
        (local.get $midpoint)
        (f32.mul (local.get $feather) (f32.sub (f32.const 1.0) (local.get $midpoint)))))

    (local.set $row (i32.const 0))
    (loop $rows
      (local.set $fy
        (f32.mul
          (f32.add
            (f32.add (local.get $y) (f32.convert_i32_u (local.get $row)))
            (f32.const 0.5))
          (local.get $inv_h)))
      (local.set $dy
        (f32.mul
          (f32.sub (local.get $fy) (f32.const 0.5))
          (f32.const 2.0)))
      (local.set $row_ptr
        (i32.add
          (global.get $input_ptr)
          (i32.mul (local.get $row) (i32.const 1024))))

      (local.set $col (i32.const 0))
      (loop $cols
        (local.set $fx
          (f32.mul
            (f32.add
              (f32.add (local.get $x) (f32.convert_i32_u (local.get $col)))
              (f32.const 0.5))
            (local.get $inv_w)))
        (local.set $dx
          (f32.mul
            (f32.mul
              (f32.sub (local.get $fx) (f32.const 0.5))
              (f32.const 2.0))
            (local.get $aspect)))

        (local.set $dist
          (f32.mul
            (f32.sqrt
              (f32.add
                (f32.mul (local.get $dx) (local.get $dx))
                (f32.mul (local.get $dy) (local.get $dy))))
            (local.get $inv_max_dist)))
        (if (f32.le (local.get $edge) (local.get $midpoint))
          (then
            (local.set $t
              (if (result f32) (f32.ge (local.get $dist) (local.get $midpoint))
                (then (f32.const 1.0))
                (else (f32.const 0.0)))))
          (else
            (local.set $t
              (f32.div
                (f32.sub (local.get $dist) (local.get $midpoint))
                (f32.sub (local.get $edge) (local.get $midpoint))))
            (local.set $t
              (f32.min
                (f32.const 1.0)
                (f32.max (f32.const 0.0) (local.get $t))))))
        (local.set $smooth
          (f32.mul (local.get $t) (local.get $t)))
        (local.set $smooth
          (f32.mul
            (local.get $smooth)
            (f32.sub
              (f32.const 3.0)
              (f32.mul (f32.const 2.0) (local.get $t)))))
        (local.set $factor
          (f32.sub
            (f32.const 1.0)
            (f32.mul (local.get $amount) (local.get $smooth))))

        (local.set $p
          (i32.add
            (local.get $row_ptr)
            (i32.mul (local.get $col) (i32.const 16))))
        (f32.store (local.get $p)
          (f32.mul (f32.load (local.get $p)) (local.get $factor)))
        (f32.store (i32.add (local.get $p) (i32.const 4))
          (f32.mul (f32.load (i32.add (local.get $p) (i32.const 4))) (local.get $factor)))
        (f32.store (i32.add (local.get $p) (i32.const 8))
          (f32.mul (f32.load (i32.add (local.get $p) (i32.const 8))) (local.get $factor)))

        (local.set $col (i32.add (local.get $col) (i32.const 1)))
        (br_if $cols (i32.lt_u (local.get $col) (i32.const 64)))
      )

      (local.set $row (i32.add (local.get $row) (i32.const 1)))
      (br_if $rows (i32.lt_u (local.get $row) (i32.const 64)))
    )
  )
)
