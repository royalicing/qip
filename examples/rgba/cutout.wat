(module $CutoutRGBA
  (memory (export "memory") 2)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0))
  (global $input_bytes_cap (export "input_bytes_cap") i32 (i32.const 0x20000))
  (global $scratch_ptr i32 (i32.const 0x10000))

  (global $uniform_levels (mut f32) (f32.const 4.0))
  (func (export "uniform_set_levels") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 16.0)
        (f32.max (f32.const 2.0) (local.get $v))))
    (global.set $uniform_levels (local.get $clamped))
    (local.get $clamped)
  )

  (global $uniform_edge_threshold (mut f32) (f32.const 0.25))
  (func (export "uniform_set_edge_threshold") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 0.99)
        (f32.max (f32.const 0.0) (local.get $v))))
    (global.set $uniform_edge_threshold (local.get $clamped))
    (local.get $clamped)
  )

  (global $uniform_edge_strength (mut f32) (f32.const 0.7))
  (func (export "uniform_set_edge_strength") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 1.0)
        (f32.max (f32.const 0.0) (local.get $v))))
    (global.set $uniform_edge_strength (local.get $clamped))
    (local.get $clamped)
  )

  (func $luma_at (param $row_ptr i32) (param $col_off i32) (result f32)
    (local $p i32)
    (local.set $p (i32.add (local.get $row_ptr) (local.get $col_off)))
    (f32.add
      (f32.add
        (f32.mul (f32.load (local.get $p)) (f32.const 0.299))
        (f32.mul (f32.load (i32.add (local.get $p) (i32.const 4))) (f32.const 0.587)))
      (f32.mul (f32.load (i32.add (local.get $p) (i32.const 8))) (f32.const 0.114)))
  )

  (func $edge_mask
    (param $row_above_ptr i32)
    (param $row_ptr i32)
    (param $row_below_ptr i32)
    (param $col_left_off i32)
    (param $col_off i32)
    (param $col_right_off i32)
    (result f32)
    (local $a00 f32)
    (local $a01 f32)
    (local $a02 f32)
    (local $a10 f32)
    (local $a12 f32)
    (local $a20 f32)
    (local $a21 f32)
    (local $a22 f32)
    (local $gx f32)
    (local $gy f32)
    (local $edge f32)
    (local $t f32)

    (local.set $a00 (call $luma_at (local.get $row_above_ptr) (local.get $col_left_off)))
    (local.set $a01 (call $luma_at (local.get $row_above_ptr) (local.get $col_off)))
    (local.set $a02 (call $luma_at (local.get $row_above_ptr) (local.get $col_right_off)))
    (local.set $a10 (call $luma_at (local.get $row_ptr) (local.get $col_left_off)))
    (local.set $a12 (call $luma_at (local.get $row_ptr) (local.get $col_right_off)))
    (local.set $a20 (call $luma_at (local.get $row_below_ptr) (local.get $col_left_off)))
    (local.set $a21 (call $luma_at (local.get $row_below_ptr) (local.get $col_off)))
    (local.set $a22 (call $luma_at (local.get $row_below_ptr) (local.get $col_right_off)))

    (local.set $gx
      (f32.sub
        (f32.add
          (f32.add (local.get $a02) (f32.mul (local.get $a12) (f32.const 2.0)))
          (local.get $a22))
        (f32.add
          (f32.add (local.get $a00) (f32.mul (local.get $a10) (f32.const 2.0)))
          (local.get $a20))))

    (local.set $gy
      (f32.sub
        (f32.add
          (f32.add (local.get $a20) (f32.mul (local.get $a21) (f32.const 2.0)))
          (local.get $a22))
        (f32.add
          (f32.add (local.get $a00) (f32.mul (local.get $a01) (f32.const 2.0)))
          (local.get $a02))))

    (local.set $edge
      (f32.mul
        (f32.add
          (f32.abs (local.get $gx))
          (f32.abs (local.get $gy)))
        (f32.const 0.125)))
    (local.set $edge
      (f32.min
        (f32.const 1.0)
        (f32.max (f32.const 0.0) (local.get $edge))))

    (local.set $t (global.get $uniform_edge_threshold))
    (if (result f32) (f32.le (local.get $edge) (local.get $t))
      (then (f32.const 0.0))
      (else
        (f32.min
          (f32.const 1.0)
          (f32.max
            (f32.const 0.0)
            (f32.div
              (f32.sub (local.get $edge) (local.get $t))
              (f32.sub (f32.const 1.0) (local.get $t)))))))
  )

  (func $quantize (param $v f32) (result f32)
    (local $levels f32)
    (local $steps f32)
    (local $q f32)
    (local.set $levels (global.get $uniform_levels))
    (local.set $steps (f32.sub (local.get $levels) (f32.const 1.0)))
    (local.set $q
      (f32.div
        (f32.nearest (f32.mul (local.get $v) (local.get $steps)))
        (local.get $steps)))
    (f32.min
      (f32.const 1.0)
      (f32.max (f32.const 0.0) (local.get $q)))
  )

  (func (export "tile_rgba_f32_64x64") (param $x f32) (param $y f32)
    (local $row i32)
    (local $row_above i32)
    (local $row_below i32)
    (local $row_above_ptr i32)
    (local $row_ptr i32)
    (local $row_below_ptr i32)
    (local $out_row_ptr i32)
    (local $col i32)
    (local $col_left i32)
    (local $col_right i32)
    (local $col_left_off i32)
    (local $col_off i32)
    (local $col_right_off i32)
    (local $out_ptr i32)
    (local $edge_mask f32)
    (local $strength f32)
    (local $darken f32)
    (local $r f32)
    (local $g f32)
    (local $b f32)
    (local $alpha f32)
    (local $src i32)
    (local $dst i32)
    (local $end i32)

    (local.set $strength (global.get $uniform_edge_strength))

    (local.set $row (i32.const 0))
    (loop $rows
      (local.set $row_above
        (if (result i32) (i32.eq (local.get $row) (i32.const 0))
          (then (i32.const 0))
          (else (i32.sub (local.get $row) (i32.const 1)))))
      (local.set $row_below
        (if (result i32) (i32.eq (local.get $row) (i32.const 63))
          (then (i32.const 63))
          (else (i32.add (local.get $row) (i32.const 1)))))

      (local.set $row_above_ptr
        (i32.add (global.get $input_ptr)
          (i32.mul (local.get $row_above) (i32.const 1024))))
      (local.set $row_ptr
        (i32.add (global.get $input_ptr)
          (i32.mul (local.get $row) (i32.const 1024))))
      (local.set $row_below_ptr
        (i32.add (global.get $input_ptr)
          (i32.mul (local.get $row_below) (i32.const 1024))))
      (local.set $out_row_ptr
        (i32.add (global.get $scratch_ptr)
          (i32.mul (local.get $row) (i32.const 1024))))

      (local.set $col (i32.const 0))
      (loop $cols
        (local.set $col_left
          (if (result i32) (i32.eq (local.get $col) (i32.const 0))
            (then (i32.const 0))
            (else (i32.sub (local.get $col) (i32.const 1)))))
        (local.set $col_right
          (if (result i32) (i32.eq (local.get $col) (i32.const 63))
            (then (i32.const 63))
            (else (i32.add (local.get $col) (i32.const 1)))))
        (local.set $col_left_off
          (i32.mul (local.get $col_left) (i32.const 16)))
        (local.set $col_off
          (i32.mul (local.get $col) (i32.const 16)))
        (local.set $col_right_off
          (i32.mul (local.get $col_right) (i32.const 16)))
        (local.set $out_ptr
          (i32.add (local.get $out_row_ptr) (local.get $col_off)))

        (local.set $edge_mask
          (call $edge_mask
            (local.get $row_above_ptr)
            (local.get $row_ptr)
            (local.get $row_below_ptr)
            (local.get $col_left_off)
            (local.get $col_off)
            (local.get $col_right_off)))
        (local.set $darken
          (f32.sub
            (f32.const 1.0)
            (f32.mul (local.get $strength) (local.get $edge_mask))))

        (local.set $r
          (call $quantize
            (f32.load (i32.add (local.get $row_ptr) (local.get $col_off)))))
        (local.set $g
          (call $quantize
            (f32.load (i32.add (local.get $row_ptr)
              (i32.add (local.get $col_off) (i32.const 4))))))
        (local.set $b
          (call $quantize
            (f32.load (i32.add (local.get $row_ptr)
              (i32.add (local.get $col_off) (i32.const 8))))))
        (local.set $alpha
          (f32.load (i32.add (local.get $row_ptr)
            (i32.add (local.get $col_off) (i32.const 12)))))

        (f32.store (local.get $out_ptr)
          (f32.mul (local.get $r) (local.get $darken)))
        (f32.store (i32.add (local.get $out_ptr) (i32.const 4))
          (f32.mul (local.get $g) (local.get $darken)))
        (f32.store (i32.add (local.get $out_ptr) (i32.const 8))
          (f32.mul (local.get $b) (local.get $darken)))
        (f32.store (i32.add (local.get $out_ptr) (i32.const 12))
          (local.get $alpha))

        (local.set $col (i32.add (local.get $col) (i32.const 1)))
        (br_if $cols (i32.lt_u (local.get $col) (i32.const 64)))
      )

      (local.set $row (i32.add (local.get $row) (i32.const 1)))
      (br_if $rows (i32.lt_u (local.get $row) (i32.const 64)))
    )

    (local.set $src (global.get $scratch_ptr))
    (local.set $dst (global.get $input_ptr))
    (local.set $end (i32.add (global.get $input_ptr) (i32.const 0x10000)))
    (loop $copy
      (i32.store (local.get $dst) (i32.load (local.get $src)))
      (local.set $src (i32.add (local.get $src) (i32.const 4)))
      (local.set $dst (i32.add (local.get $dst) (i32.const 4)))
      (br_if $copy (i32.lt_u (local.get $dst) (local.get $end)))
    )
  )
)
