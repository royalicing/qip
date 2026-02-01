(module $UnsharpMaskRGBA
  (memory (export "memory") 12)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0))
  (global $input_bytes_cap (export "input_bytes_cap") i32 (i32.const 0x40000))
  (global $scratch_orig_ptr i32 (i32.const 0x40000))
  (global $scratch_blur_ptr i32 (i32.const 0x80000))

  ;; Radius in pixels for the underlying blur. 0 = no-op.
  (global $uniform_radius (mut f32) (f32.const 2.0))
  (func (export "uniform_set_radius") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 10.0)
        (f32.max (f32.const 0.0) (local.get $v))))
    (global.set $uniform_radius (local.get $clamped))
    (local.get $clamped)
  )

  ;; Amount in [0, 2].
  (global $uniform_amount (mut f32) (f32.const 0.6))
  (func (export "uniform_set_amount") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 2.0)
        (f32.max (f32.const 0.0) (local.get $v))))
    (global.set $uniform_amount (local.get $clamped))
    (local.get $clamped)
  )

  ;; Threshold in [0, 1].
  (global $uniform_threshold (mut f32) (f32.const 0.02))
  (func (export "uniform_set_threshold") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 1.0)
        (f32.max (f32.const 0.0) (local.get $v))))
    (global.set $uniform_threshold (local.get $clamped))
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

  (func $clamp_f32 (param $v f32) (result f32)
    (f32.min
      (f32.const 1.0)
      (f32.max (f32.const 0.0) (local.get $v)))
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
    (local $total_bytes i32)
    (local $src i32)
    (local $dst i32)
    (local $end i32)
    (local $row i32)
    (local $col i32)
    (local $row_base i32)
    (local $p_orig i32)
    (local $p_blur i32)
    (local $p_out i32)
    (local $orig f32)
    (local $blur f32)
    (local $diff f32)
    (local $val f32)
    (local $amount f32)
    (local $threshold f32)

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
    (local.set $total_bytes (i32.mul (local.get $row_stride) (local.get $tile_span)))

    ;; Copy input to scratch original.
    (local.set $src (global.get $input_ptr))
    (local.set $dst (global.get $scratch_orig_ptr))
    (local.set $end (i32.add (global.get $input_ptr) (local.get $total_bytes)))
    (loop $copy
      (i32.store (local.get $dst) (i32.load (local.get $src)))
      (local.set $src (i32.add (local.get $src) (i32.const 4)))
      (local.set $dst (i32.add (local.get $dst) (i32.const 4)))
      (br_if $copy (i32.lt_u (local.get $src) (local.get $end)))
    )

    ;; Blur into input using scratch_blur as ping-pong.
    (call $blur_horizontal
      (global.get $input_ptr)
      (global.get $scratch_blur_ptr)
      (local.get $radius)
      (local.get $tile_span)
      (local.get $row_stride))
    (call $blur_vertical
      (global.get $scratch_blur_ptr)
      (global.get $input_ptr)
      (local.get $radius)
      (local.get $tile_span)
      (local.get $row_stride))

    (call $blur_horizontal
      (global.get $input_ptr)
      (global.get $scratch_blur_ptr)
      (local.get $radius)
      (local.get $tile_span)
      (local.get $row_stride))
    (call $blur_vertical
      (global.get $scratch_blur_ptr)
      (global.get $input_ptr)
      (local.get $radius)
      (local.get $tile_span)
      (local.get $row_stride))

    (call $blur_horizontal
      (global.get $input_ptr)
      (global.get $scratch_blur_ptr)
      (local.get $radius)
      (local.get $tile_span)
      (local.get $row_stride))
    (call $blur_vertical
      (global.get $scratch_blur_ptr)
      (global.get $input_ptr)
      (local.get $radius)
      (local.get $tile_span)
      (local.get $row_stride))

    (local.set $amount (global.get $uniform_amount))
    (local.set $threshold (global.get $uniform_threshold))

    (local.set $row (i32.const 0))
    (loop $rows
      (local.set $row_base (i32.mul (local.get $row) (local.get $row_stride)))
      (local.set $col (i32.const 0))
      (loop $cols
        (local.set $p_orig
          (i32.add
            (global.get $scratch_orig_ptr)
            (i32.add (local.get $row_base) (i32.mul (local.get $col) (i32.const 16)))))
        (local.set $p_blur
          (i32.add
            (global.get $input_ptr)
            (i32.add (local.get $row_base) (i32.mul (local.get $col) (i32.const 16)))))
        (local.set $p_out (local.get $p_blur))

        (local.set $orig (f32.load (local.get $p_orig)))
        (local.set $blur (f32.load (local.get $p_blur)))
        (local.set $diff (f32.sub (local.get $orig) (local.get $blur)))
        (if (f32.lt (f32.abs (local.get $diff)) (local.get $threshold))
          (then (local.set $val (local.get $orig)))
          (else (local.set $val (f32.add (local.get $orig) (f32.mul (local.get $diff) (local.get $amount))))))
        (f32.store (local.get $p_out) (call $clamp_f32 (local.get $val)))

        (local.set $orig (f32.load (i32.add (local.get $p_orig) (i32.const 4))))
        (local.set $blur (f32.load (i32.add (local.get $p_blur) (i32.const 4))))
        (local.set $diff (f32.sub (local.get $orig) (local.get $blur)))
        (if (f32.lt (f32.abs (local.get $diff)) (local.get $threshold))
          (then (local.set $val (local.get $orig)))
          (else (local.set $val (f32.add (local.get $orig) (f32.mul (local.get $diff) (local.get $amount))))))
        (f32.store (i32.add (local.get $p_out) (i32.const 4)) (call $clamp_f32 (local.get $val)))

        (local.set $orig (f32.load (i32.add (local.get $p_orig) (i32.const 8))))
        (local.set $blur (f32.load (i32.add (local.get $p_blur) (i32.const 8))))
        (local.set $diff (f32.sub (local.get $orig) (local.get $blur)))
        (if (f32.lt (f32.abs (local.get $diff)) (local.get $threshold))
          (then (local.set $val (local.get $orig)))
          (else (local.set $val (f32.add (local.get $orig) (f32.mul (local.get $diff) (local.get $amount))))))
        (f32.store (i32.add (local.get $p_out) (i32.const 8)) (call $clamp_f32 (local.get $val)))

        (f32.store (i32.add (local.get $p_out) (i32.const 12))
          (f32.load (i32.add (local.get $p_orig) (i32.const 12))))

        (local.set $col (i32.add (local.get $col) (i32.const 1)))
        (br_if $cols (i32.lt_u (local.get $col) (local.get $tile_span)))
      )

      (local.set $row (i32.add (local.get $row) (i32.const 1)))
      (br_if $rows (i32.lt_u (local.get $row) (local.get $tile_span)))
    )
  )
)
