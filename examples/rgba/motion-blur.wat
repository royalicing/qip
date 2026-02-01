(module $MotionBlurRGBA
  (memory (export "memory") 8)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0))
  (global $input_bytes_cap (export "input_bytes_cap") i32 (i32.const 0x40000))
  (global $scratch_ptr i32 (i32.const 0x40000))

  ;; Radius in pixels. 0 = no-op.
  (global $uniform_radius (mut f32) (f32.const 8.0))
  (func (export "uniform_set_radius") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 32.0)
        (f32.max (f32.const 0.0) (local.get $v))))
    (global.set $uniform_radius (local.get $clamped))
    (local.get $clamped)
  )

  (global $uniform_sin (mut f32) (f32.const 0.0))
  (global $uniform_cos (mut f32) (f32.const 1.0))

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

  (func (export "uniform_set_angle") (param $v f32) (result f32)
    (local $rad f32)
    (local.set $rad (f32.mul (local.get $v) (f32.const 0.017453292)))
    (global.set $uniform_sin (call $sin_from_radians (local.get $rad)))
    (global.set $uniform_cos (call $cos_from_radians (local.get $rad)))
    (local.get $v)
  )

  (func (export "calculate_halo_px") (result i32)
    (local $r i32)
    (local.set $r (i32.trunc_f32_s (global.get $uniform_radius)))
    (if (result i32) (i32.le_s (local.get $r) (i32.const 0))
      (then (i32.const 0))
      (else (local.get $r)))
  )

  (func $clamp_i32 (param $v i32) (param $min i32) (param $max i32) (result i32)
    (if (result i32) (i32.lt_s (local.get $v) (local.get $min))
      (then (local.get $min))
      (else
        (if (result i32) (i32.gt_s (local.get $v) (local.get $max))
          (then (local.get $max))
          (else (local.get $v)))))
  )

  (func $clamp_f32 (param $v f32) (result f32)
    (f32.min
      (f32.const 1.0)
      (f32.max (f32.const 0.0) (local.get $v)))
  )

  (func (export "tile_rgba_f32_64x64") (param $x f32) (param $y f32)
    (local $radius i32)
    (local $halo i32)
    (local $tile_span i32)
    (local $row_stride i32)
    (local $total_bytes i32)
    (local $src i32)
    (local $dst i32)
    (local $end i32)
    (local $row i32)
    (local $col i32)
    (local $row_base i32)
    (local $i i32)
    (local $den_i i32)
    (local $inv f32)
    (local $dx f32)
    (local $dy f32)
    (local $row_f f32)
    (local $col_f f32)
    (local $sx f32)
    (local $sy f32)
    (local $sxi i32)
    (local $syi i32)
    (local $p_sample i32)
    (local $p_out i32)
    (local $sum_r f32)
    (local $sum_g f32)
    (local $sum_b f32)
    (local $sum_a f32)
    (local $v f32)

    (local.set $radius (i32.trunc_f32_s (global.get $uniform_radius)))
    (if (i32.le_s (local.get $radius) (i32.const 0))
      (then (return))
    )

    (local.set $halo (local.get $radius))
    (local.set $tile_span
      (i32.add
        (i32.const 64)
        (i32.mul (local.get $halo) (i32.const 2))))
    (local.set $row_stride (i32.mul (local.get $tile_span) (i32.const 16)))
    (local.set $total_bytes (i32.mul (local.get $row_stride) (local.get $tile_span)))

    (local.set $den_i
      (i32.add
        (i32.mul (local.get $radius) (i32.const 2))
        (i32.const 1)))
    (local.set $inv
      (f32.div (f32.const 1.0) (f32.convert_i32_s (local.get $den_i))))

    ;; Copy input to scratch.
    (local.set $src (global.get $input_ptr))
    (local.set $dst (global.get $scratch_ptr))
    (local.set $end (i32.add (global.get $input_ptr) (local.get $total_bytes)))
    (loop $copy
      (i32.store (local.get $dst) (i32.load (local.get $src)))
      (local.set $src (i32.add (local.get $src) (i32.const 4)))
      (local.set $dst (i32.add (local.get $dst) (i32.const 4)))
      (br_if $copy (i32.lt_u (local.get $src) (local.get $end)))
    )

    (local.set $row (i32.const 0))
    (loop $rows
      (local.set $row_base (i32.mul (local.get $row) (local.get $row_stride)))
      (local.set $row_f (f32.convert_i32_s (local.get $row)))
      (local.set $col (i32.const 0))
      (loop $cols
        (local.set $col_f (f32.convert_i32_s (local.get $col)))
        (local.set $sum_r (f32.const 0.0))
        (local.set $sum_g (f32.const 0.0))
        (local.set $sum_b (f32.const 0.0))
        (local.set $sum_a (f32.const 0.0))

        (local.set $i (i32.sub (i32.const 0) (local.get $radius)))
        (loop $samples
          (local.set $dx
            (f32.mul
              (f32.convert_i32_s (local.get $i))
              (global.get $uniform_cos)))
          (local.set $dy
            (f32.mul
              (f32.convert_i32_s (local.get $i))
              (global.get $uniform_sin)))

          (local.set $sx (f32.add (local.get $col_f) (local.get $dx)))
          (local.set $sy (f32.add (local.get $row_f) (local.get $dy)))

          (local.set $sxi
            (call $clamp_i32
              (i32.trunc_f32_s (f32.nearest (local.get $sx)))
              (i32.const 0)
              (i32.sub (local.get $tile_span) (i32.const 1))))
          (local.set $syi
            (call $clamp_i32
              (i32.trunc_f32_s (f32.nearest (local.get $sy)))
              (i32.const 0)
              (i32.sub (local.get $tile_span) (i32.const 1))))

          (local.set $p_sample
            (i32.add
              (global.get $scratch_ptr)
              (i32.add
                (i32.mul (local.get $syi) (local.get $row_stride))
                (i32.mul (local.get $sxi) (i32.const 16)))))

          (local.set $sum_r
            (f32.add (local.get $sum_r) (f32.load (local.get $p_sample))))
          (local.set $sum_g
            (f32.add (local.get $sum_g) (f32.load (i32.add (local.get $p_sample) (i32.const 4)))))
          (local.set $sum_b
            (f32.add (local.get $sum_b) (f32.load (i32.add (local.get $p_sample) (i32.const 8)))))
          (local.set $sum_a
            (f32.add (local.get $sum_a) (f32.load (i32.add (local.get $p_sample) (i32.const 12)))))

          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br_if $samples
            (i32.le_s (local.get $i) (local.get $radius)))
        )

        (local.set $p_out
          (i32.add
            (global.get $input_ptr)
            (i32.add (local.get $row_base) (i32.mul (local.get $col) (i32.const 16)))))

        (local.set $v (f32.mul (local.get $sum_r) (local.get $inv)))
        (f32.store (local.get $p_out) (call $clamp_f32 (local.get $v)))
        (local.set $v (f32.mul (local.get $sum_g) (local.get $inv)))
        (f32.store (i32.add (local.get $p_out) (i32.const 4)) (call $clamp_f32 (local.get $v)))
        (local.set $v (f32.mul (local.get $sum_b) (local.get $inv)))
        (f32.store (i32.add (local.get $p_out) (i32.const 8)) (call $clamp_f32 (local.get $v)))
        (local.set $v (f32.mul (local.get $sum_a) (local.get $inv)))
        (f32.store (i32.add (local.get $p_out) (i32.const 12)) (call $clamp_f32 (local.get $v)))

        (local.set $col (i32.add (local.get $col) (i32.const 1)))
        (br_if $cols (i32.lt_u (local.get $col) (local.get $tile_span)))
      )

      (local.set $row (i32.add (local.get $row) (i32.const 1)))
      (br_if $rows (i32.lt_u (local.get $row) (local.get $tile_span)))
    )
  )
)
