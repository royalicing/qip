(module $RenderCloudsRGBA
  (memory (export "memory") 1)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0))
  (global $input_bytes_cap (export "input_bytes_cap") i32 (i32.const 0x10000))

  (global $uniform_scale (mut f32) (f32.const 96.0))
  (func (export "uniform_set_scale") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 512.0)
        (f32.max (f32.const 8.0) (local.get $v))))
    (global.set $uniform_scale (local.get $clamped))
    (local.get $clamped)
  )

  (global $uniform_persistence (mut f32) (f32.const 0.5))
  (func (export "uniform_set_persistence") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 0.95)
        (f32.max (f32.const 0.0) (local.get $v))))
    (global.set $uniform_persistence (local.get $clamped))
    (local.get $clamped)
  )

  (global $uniform_contrast (mut f32) (f32.const 1.2))
  (func (export "uniform_set_contrast") (param $v f32) (result f32)
    (local $clamped f32)
    (local.set $clamped
      (f32.min
        (f32.const 2.5)
        (f32.max (f32.const 0.1) (local.get $v))))
    (global.set $uniform_contrast (local.get $clamped))
    (local.get $clamped)
  )

  (global $uniform_octaves (mut i32) (i32.const 4))
  (func (export "uniform_set_octaves") (param $v f32) (result f32)
    (local $oct i32)
    (local.set $oct (i32.trunc_f32_s (local.get $v)))
    (if (i32.lt_s (local.get $oct) (i32.const 1))
      (then (local.set $oct (i32.const 1))))
    (if (i32.gt_s (local.get $oct) (i32.const 8))
      (then (local.set $oct (i32.const 8))))
    (global.set $uniform_octaves (local.get $oct))
    (f32.convert_i32_s (local.get $oct))
  )

  (global $uniform_seed (mut i32) (i32.const 0))
  (func (export "uniform_set_seed") (param $v f32) (result f32)
    (local $s i32)
    (local.set $s (i32.trunc_f32_s (local.get $v)))
    (global.set $uniform_seed (local.get $s))
    (f32.convert_i32_s (local.get $s))
  )

  (func $clamp (param $v f32) (result f32)
    (f32.min
      (f32.const 1.0)
      (f32.max (f32.const 0.0) (local.get $v)))
  )

  (func $fade (param $t f32) (result f32)
    (f32.mul
      (local.get $t)
      (f32.mul
        (local.get $t)
        (f32.sub (f32.const 3.0) (f32.mul (f32.const 2.0) (local.get $t)))))
  )

  (func $lerp (param $a f32) (param $b f32) (param $t f32) (result f32)
    (f32.add
      (local.get $a)
      (f32.mul (local.get $t) (f32.sub (local.get $b) (local.get $a))))
  )

  (func $hash01 (param $x i32) (param $y i32) (result f32)
    (local $h i32)
    (local.set $h
      (i32.add
        (i32.add
          (i32.mul (local.get $x) (i32.const 374761393))
          (i32.mul (local.get $y) (i32.const 668265263)))
        (i32.mul (global.get $uniform_seed) (i32.const 1442695041))))
    (local.set $h (i32.xor (local.get $h) (i32.shr_u (local.get $h) (i32.const 13))))
    (local.set $h (i32.mul (local.get $h) (i32.const 1274126177)))
    (local.set $h (i32.xor (local.get $h) (i32.shr_u (local.get $h) (i32.const 16))))
    (local.set $h (i32.and (local.get $h) (i32.const 2147483647)))
    (f32.div
      (f32.convert_i32_u (local.get $h))
      (f32.const 2147483647.0))
  )

  (func $value_noise (param $x f32) (param $y f32) (result f32)
    (local $xi i32)
    (local $yi i32)
    (local $xf f32)
    (local $yf f32)
    (local $u f32)
    (local $v f32)
    (local $v00 f32)
    (local $v10 f32)
    (local $v01 f32)
    (local $v11 f32)
    (local $x1 f32)
    (local $x2 f32)

    (local.set $xi (i32.trunc_f32_s (f32.floor (local.get $x))))
    (local.set $yi (i32.trunc_f32_s (f32.floor (local.get $y))))
    (local.set $xf (f32.sub (local.get $x) (f32.convert_i32_s (local.get $xi))))
    (local.set $yf (f32.sub (local.get $y) (f32.convert_i32_s (local.get $yi))))

    (local.set $v00 (call $hash01 (local.get $xi) (local.get $yi)))
    (local.set $v10 (call $hash01 (i32.add (local.get $xi) (i32.const 1)) (local.get $yi)))
    (local.set $v01 (call $hash01 (local.get $xi) (i32.add (local.get $yi) (i32.const 1))))
    (local.set $v11 (call $hash01 (i32.add (local.get $xi) (i32.const 1)) (i32.add (local.get $yi) (i32.const 1))))

    (local.set $u (call $fade (local.get $xf)))
    (local.set $v (call $fade (local.get $yf)))

    (local.set $x1 (call $lerp (local.get $v00) (local.get $v10) (local.get $u)))
    (local.set $x2 (call $lerp (local.get $v01) (local.get $v11) (local.get $u)))
    (call $lerp (local.get $x1) (local.get $x2) (local.get $v))
  )

  (func $fbm (param $x f32) (param $y f32) (result f32)
    (local $sum f32)
    (local $amp f32)
    (local $max f32)
    (local $freq f32)
    (local $i i32)
    (local $oct i32)

    (local.set $sum (f32.const 0.0))
    (local.set $amp (f32.const 1.0))
    (local.set $max (f32.const 0.0))
    (local.set $freq (f32.const 1.0))
    (local.set $oct (global.get $uniform_octaves))

    (local.set $i (i32.const 0))
    (loop $octaves
      (local.set $sum
        (f32.add
          (local.get $sum)
          (f32.mul
            (call $value_noise
              (f32.mul (local.get $x) (local.get $freq))
              (f32.mul (local.get $y) (local.get $freq)))
            (local.get $amp))))
      (local.set $max (f32.add (local.get $max) (local.get $amp)))
      (local.set $amp (f32.mul (local.get $amp) (global.get $uniform_persistence)))
      (local.set $freq (f32.mul (local.get $freq) (f32.const 2.0)))

      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $octaves (i32.lt_u (local.get $i) (local.get $oct)))
    )

    (if (result f32) (f32.gt (local.get $max) (f32.const 0.0))
      (then (f32.div (local.get $sum) (local.get $max)))
      (else (f32.const 0.0)))
  )

  (func (export "tile_rgba_f32_64x64") (param $x f32) (param $y f32)
    (local $row i32)
    (local $col i32)
    (local $row_ptr i32)
    (local $p i32)
    (local $fx f32)
    (local $fy f32)
    (local $inv_scale f32)
    (local $v f32)
    (local $contrast f32)
    (local $alpha f32)

    (local.set $inv_scale
      (f32.div (f32.const 1.0) (global.get $uniform_scale)))
    (local.set $contrast (global.get $uniform_contrast))

    (local.set $row (i32.const 0))
    (loop $rows
      (local.set $row_ptr
        (i32.add
          (global.get $input_ptr)
          (i32.mul (local.get $row) (i32.const 1024))))

      (local.set $col (i32.const 0))
      (loop $cols
        (local.set $p
          (i32.add
            (local.get $row_ptr)
            (i32.mul (local.get $col) (i32.const 16))))

        (local.set $fx
          (f32.mul
            (f32.add
              (local.get $x)
              (f32.convert_i32_u (local.get $col)))
            (local.get $inv_scale)))
        (local.set $fy
          (f32.mul
            (f32.add
              (local.get $y)
              (f32.convert_i32_u (local.get $row)))
            (local.get $inv_scale)))

        (local.set $v (call $fbm (local.get $fx) (local.get $fy)))
        (local.set $v
          (f32.add
            (f32.const 0.5)
            (f32.mul
              (f32.sub (local.get $v) (f32.const 0.5))
              (local.get $contrast))))
        (local.set $v (call $clamp (local.get $v)))

        (f32.store (local.get $p) (local.get $v))
        (f32.store (i32.add (local.get $p) (i32.const 4)) (local.get $v))
        (f32.store (i32.add (local.get $p) (i32.const 8)) (local.get $v))

        (local.set $alpha
          (f32.load (i32.add (local.get $p) (i32.const 12))))
        (f32.store (i32.add (local.get $p) (i32.const 12)) (local.get $alpha))

        (local.set $col (i32.add (local.get $col) (i32.const 1)))
        (br_if $cols (i32.lt_u (local.get $col) (i32.const 64)))
      )

      (local.set $row (i32.add (local.get $row) (i32.const 1)))
      (br_if $rows (i32.lt_u (local.get $row) (i32.const 64)))
    )
  )
)
