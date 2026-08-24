(module
  (memory (export "memory") 1 1)

  (func (export "input_ptr") (result i32) i32.const 0)
  (func (export "input_bytes_cap") (result i32) i32.const 16)
  (func (export "output_bytes_cap") (result i32) i32.const 128)

  ;; Keep every Core 1.0 floating-point opcode in one validated fixture. The
  ;; render function below also stores results whose exact bits test edge cases.
  (func $exercise
    f32.const 1 f32.const 2 f32.eq drop
    f32.const 1 f32.const 2 f32.ne drop
    f32.const 1 f32.const 2 f32.lt drop
    f32.const 1 f32.const 2 f32.gt drop
    f32.const 1 f32.const 2 f32.le drop
    f32.const 1 f32.const 2 f32.ge drop
    f64.const 1 f64.const 2 f64.eq drop
    f64.const 1 f64.const 2 f64.ne drop
    f64.const 1 f64.const 2 f64.lt drop
    f64.const 1 f64.const 2 f64.gt drop
    f64.const 1 f64.const 2 f64.le drop
    f64.const 1 f64.const 2 f64.ge drop

    f32.const -1 f32.abs drop
    f32.const 1 f32.neg drop
    f32.const 1.25 f32.ceil drop
    f32.const 1.75 f32.floor drop
    f32.const -1.75 f32.trunc drop
    f32.const 2.5 f32.nearest drop
    f32.const 4 f32.sqrt drop
    f64.const -1 f64.abs drop
    f64.const 1 f64.neg drop
    f64.const 1.25 f64.ceil drop
    f64.const 1.75 f64.floor drop
    f64.const -1.75 f64.trunc drop
    f64.const 2.5 f64.nearest drop
    f64.const 4 f64.sqrt drop

    f32.const 6 f32.const 2 f32.add drop
    f32.const 6 f32.const 2 f32.sub drop
    f32.const 6 f32.const 2 f32.mul drop
    f32.const 6 f32.const 2 f32.div drop
    f32.const 6 f32.const 2 f32.min drop
    f32.const 6 f32.const 2 f32.max drop
    f32.const 6 f32.const -2 f32.copysign drop
    f64.const 6 f64.const 2 f64.add drop
    f64.const 6 f64.const 2 f64.sub drop
    f64.const 6 f64.const 2 f64.mul drop
    f64.const 6 f64.const 2 f64.div drop
    f64.const 6 f64.const 2 f64.min drop
    f64.const 6 f64.const 2 f64.max drop
    f64.const 6 f64.const -2 f64.copysign drop

    f32.const -3.75 i32.trunc_f32_s drop
    f32.const 3.75 i32.trunc_f32_u drop
    f64.const -3.75 i32.trunc_f64_s drop
    f64.const 3.75 i32.trunc_f64_u drop
    f32.const -3.75 i64.trunc_f32_s drop
    f32.const 3.75 i64.trunc_f32_u drop
    f64.const -3.75 i64.trunc_f64_s drop
    f64.const 3.75 i64.trunc_f64_u drop
    i32.const -3 f32.convert_i32_s drop
    i32.const 3 f32.convert_i32_u drop
    i64.const -3 f32.convert_i64_s drop
    i64.const 3 f32.convert_i64_u drop
    f64.const 1.5 f32.demote_f64 drop
    i32.const -3 f64.convert_i32_s drop
    i32.const 3 f64.convert_i32_u drop
    i64.const -3 f64.convert_i64_s drop
    i64.const 3 f64.convert_i64_u drop
    f32.const 1.5 f64.promote_f32 drop
    f32.const 1.5 i32.reinterpret_f32 drop
    f64.const 1.5 i64.reinterpret_f64 drop
    i32.const 1069547520 f32.reinterpret_i32 drop
    i64.const 4609434218613702656 f64.reinterpret_i64 drop)

  (func (export "render") (param i32) (result i64)
    call $exercise

    i32.const 64 f32.const 2.5 f32.nearest f32.store
    i32.const 68 f32.const -0.5 f32.nearest f32.store
    i32.const 72 f32.const 0 f32.const -0 f32.min f32.store
    i32.const 76 f32.const 0 f32.const -0 f32.max f32.store
    i32.const 80 f32.const -3 f32.abs f32.store
    i32.const 84 f32.const 1 f32.const -2 f32.copysign f32.store
    i32.const 88 f64.const -3.75 i32.trunc_f64_s i32.store
    i32.const 92 i32.const -7 f32.convert_i32_s f32.store

    i32.const 96 f64.const 2.5 f64.nearest f64.store
    i32.const 104 f64.const -0.5 f64.nearest f64.store
    i32.const 112 f64.const 0 f64.const -0 f64.min f64.store
    i32.const 120 f64.const 0 f64.const -0 f64.max f64.store
    i32.const 128 f64.const 1.5 f64.const 2.25 f64.add f64.store
    i32.const 136 i64.const -7 f64.convert_i64_s f64.store
    i32.const 144 f32.const 1.5 f64.promote_f32 f64.store

    i64.const 274877907032))
