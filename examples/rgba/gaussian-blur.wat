(module $GaussianBlurRGBA
  (memory (export "memory") 12)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0))
  (global $input_bytes_cap (export "input_bytes_cap") i32 (i32.const 0x60000))
  (global $scratch_ptr i32 (i32.const 0x60000))

  ;; Box-blur radius in pixels. 0 = no-op. (Multiple passes approximate Gaussian.)
  (global $uniform_radius (mut f32) (f32.const 2.0))
  (func (export "uniform_set_radius") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 12.0)
        (f32.max (f32.const 0.0) (local.get $v))))
    (global.set $uniform_radius (local.get $clamped))
    (local.get $clamped)
  )

  (func (export "calculate_halo_px") (result i32)
    (local $r i32)
    (local.set $r (i32.trunc_f32_s (global.get $uniform_radius)))
    (if (result i32) (i32.le_s (local.get $r) (i32.const 0))
      (then (i32.const 0))
      (else (i32.mul (local.get $r) (i32.const 3))))
  )

  (func $clamp_i32 (param $v i32) (param $min i32) (param $max i32) (result i32)
    (if (result i32) (i32.lt_s (local.get $v) (local.get $min))
      (then (local.get $min))
      (else
        (if (result i32) (i32.gt_s (local.get $v) (local.get $max))
          (then (local.get $max))
          (else (local.get $v)))))
  )

  (func $blur_horizontal
    (param $src_base i32)
    (param $dst_base i32)
    (param $radius i32)
    (param $span i32)
    (param $row_stride i32)
    (local $row i32)
    (local $col i32)
    (local $dx i32)
    (local $idx i32)
    (local $src_row i32)
    (local $dst_row i32)
    (local $p i32)
    (local $sum_r f32)
    (local $sum_g f32)
    (local $sum_b f32)
    (local $sum_a f32)
    (local $den_i i32)
    (local $inv f32)
    (local $max i32)

    (local.set $den_i
      (i32.add
        (i32.mul (local.get $radius) (i32.const 2))
        (i32.const 1)))
    (local.set $inv
      (f32.div (f32.const 1.0) (f32.convert_i32_s (local.get $den_i))))
    (local.set $max (i32.sub (local.get $span) (i32.const 1)))

    (local.set $row (i32.const 0))
    (loop $rows
      (local.set $src_row
        (i32.add (local.get $src_base)
          (i32.mul (local.get $row) (local.get $row_stride))))
      (local.set $dst_row
        (i32.add (local.get $dst_base)
          (i32.mul (local.get $row) (local.get $row_stride))))

      (local.set $col (i32.const 0))
      (loop $cols
        (local.set $sum_r (f32.const 0.0))
        (local.set $sum_g (f32.const 0.0))
        (local.set $sum_b (f32.const 0.0))
        (local.set $sum_a (f32.const 0.0))

        (local.set $dx (i32.sub (i32.const 0) (local.get $radius)))
        (loop $dx_loop
        (local.set $idx
          (call $clamp_i32
            (i32.add (local.get $col) (local.get $dx))
            (i32.const 0)
            (local.get $max)))
        (local.set $p
          (i32.add (local.get $src_row)
            (i32.mul (local.get $idx) (i32.const 16))))
          (local.set $sum_r
            (f32.add (local.get $sum_r) (f32.load (local.get $p))))
          (local.set $sum_g
            (f32.add (local.get $sum_g) (f32.load (i32.add (local.get $p) (i32.const 4)))))
          (local.set $sum_b
            (f32.add (local.get $sum_b) (f32.load (i32.add (local.get $p) (i32.const 8)))))
          (local.set $sum_a
            (f32.add (local.get $sum_a) (f32.load (i32.add (local.get $p) (i32.const 12)))))

          (local.set $dx (i32.add (local.get $dx) (i32.const 1)))
          (br_if $dx_loop
            (i32.le_s (local.get $dx) (local.get $radius)))
        )

        (local.set $p
          (i32.add (local.get $dst_row)
            (i32.mul (local.get $col) (i32.const 16))))
        (f32.store (local.get $p) (f32.mul (local.get $sum_r) (local.get $inv)))
        (f32.store (i32.add (local.get $p) (i32.const 4)) (f32.mul (local.get $sum_g) (local.get $inv)))
        (f32.store (i32.add (local.get $p) (i32.const 8)) (f32.mul (local.get $sum_b) (local.get $inv)))
        (f32.store (i32.add (local.get $p) (i32.const 12)) (f32.mul (local.get $sum_a) (local.get $inv)))

        (local.set $col (i32.add (local.get $col) (i32.const 1)))
        (br_if $cols (i32.lt_u (local.get $col) (local.get $span)))
      )

      (local.set $row (i32.add (local.get $row) (i32.const 1)))
      (br_if $rows (i32.lt_u (local.get $row) (local.get $span)))
    )
  )

  (func $blur_vertical
    (param $src_base i32)
    (param $dst_base i32)
    (param $radius i32)
    (param $span i32)
    (param $row_stride i32)
    (local $row i32)
    (local $col i32)
    (local $dy i32)
    (local $idx i32)
    (local $src_row i32)
    (local $dst_row i32)
    (local $p i32)
    (local $sum_r f32)
    (local $sum_g f32)
    (local $sum_b f32)
    (local $sum_a f32)
    (local $den_i i32)
    (local $inv f32)
    (local $max i32)

    (local.set $den_i
      (i32.add
        (i32.mul (local.get $radius) (i32.const 2))
        (i32.const 1)))
    (local.set $inv
      (f32.div (f32.const 1.0) (f32.convert_i32_s (local.get $den_i))))
    (local.set $max (i32.sub (local.get $span) (i32.const 1)))

    (local.set $row (i32.const 0))
    (loop $rows
      (local.set $dst_row
        (i32.add (local.get $dst_base)
          (i32.mul (local.get $row) (local.get $row_stride))))

      (local.set $col (i32.const 0))
      (loop $cols
        (local.set $sum_r (f32.const 0.0))
        (local.set $sum_g (f32.const 0.0))
        (local.set $sum_b (f32.const 0.0))
        (local.set $sum_a (f32.const 0.0))

        (local.set $dy (i32.sub (i32.const 0) (local.get $radius)))
        (loop $dy_loop
        (local.set $idx
          (call $clamp_i32
            (i32.add (local.get $row) (local.get $dy))
            (i32.const 0)
            (local.get $max)))
        (local.set $src_row
          (i32.add (local.get $src_base)
            (i32.mul (local.get $idx) (local.get $row_stride))))
        (local.set $p
          (i32.add (local.get $src_row)
            (i32.mul (local.get $col) (i32.const 16))))
          (local.set $sum_r
            (f32.add (local.get $sum_r) (f32.load (local.get $p))))
          (local.set $sum_g
            (f32.add (local.get $sum_g) (f32.load (i32.add (local.get $p) (i32.const 4)))))
          (local.set $sum_b
            (f32.add (local.get $sum_b) (f32.load (i32.add (local.get $p) (i32.const 8)))))
          (local.set $sum_a
            (f32.add (local.get $sum_a) (f32.load (i32.add (local.get $p) (i32.const 12)))))

          (local.set $dy (i32.add (local.get $dy) (i32.const 1)))
          (br_if $dy_loop
            (i32.le_s (local.get $dy) (local.get $radius)))
        )

        (local.set $p
          (i32.add (local.get $dst_row)
            (i32.mul (local.get $col) (i32.const 16))))
        (f32.store (local.get $p) (f32.mul (local.get $sum_r) (local.get $inv)))
        (f32.store (i32.add (local.get $p) (i32.const 4)) (f32.mul (local.get $sum_g) (local.get $inv)))
        (f32.store (i32.add (local.get $p) (i32.const 8)) (f32.mul (local.get $sum_b) (local.get $inv)))
        (f32.store (i32.add (local.get $p) (i32.const 12)) (f32.mul (local.get $sum_a) (local.get $inv)))

        (local.set $col (i32.add (local.get $col) (i32.const 1)))
        (br_if $cols (i32.lt_u (local.get $col) (local.get $span)))
      )

      (local.set $row (i32.add (local.get $row) (i32.const 1)))
      (br_if $rows (i32.lt_u (local.get $row) (local.get $span)))
    )
  )

  (func (export "tile_rgba_f32_64x64") (param $x f32) (param $y f32)
    (local $radius i32)
    (local $halo i32)
    (local $tile_span i32)
    (local $row_stride i32)

    (local.set $radius (i32.trunc_f32_s (global.get $uniform_radius)))
    (if (i32.le_s (local.get $radius) (i32.const 0))
      (then (return))
    )

    (local.set $halo (i32.mul (local.get $radius) (i32.const 3)))
    (local.set $tile_span
      (i32.add
        (i32.const 64)
        (i32.mul (local.get $halo) (i32.const 2))))
    (local.set $row_stride (i32.mul (local.get $tile_span) (i32.const 16)))

    (call $blur_horizontal
      (global.get $input_ptr)
      (global.get $scratch_ptr)
      (local.get $radius)
      (local.get $tile_span)
      (local.get $row_stride))
    (call $blur_vertical
      (global.get $scratch_ptr)
      (global.get $input_ptr)
      (local.get $radius)
      (local.get $tile_span)
      (local.get $row_stride))

    (call $blur_horizontal
      (global.get $input_ptr)
      (global.get $scratch_ptr)
      (local.get $radius)
      (local.get $tile_span)
      (local.get $row_stride))
    (call $blur_vertical
      (global.get $scratch_ptr)
      (global.get $input_ptr)
      (local.get $radius)
      (local.get $tile_span)
      (local.get $row_stride))

    (call $blur_horizontal
      (global.get $input_ptr)
      (global.get $scratch_ptr)
      (local.get $radius)
      (local.get $tile_span)
      (local.get $row_stride))
    (call $blur_vertical
      (global.get $scratch_ptr)
      (global.get $input_ptr)
      (local.get $radius)
      (local.get $tile_span)
      (local.get $row_stride))
  )
)
