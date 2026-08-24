(module
  (type $unary (func (param i32) (result i32)))
  (type $nullary (func (result i32)))
  (memory (export "memory") 1 1)
  (table 3 3 funcref)
  (elem (i32.const 0) $identity)
  (data (i32.const 1024) "ok")

  (func $identity (type $unary) (param $value i32) (result i32)
    local.get $value)

  (func (export "input_ptr") (result i32) i32.const 0)
  (func (export "input_bytes_cap") (result i32) i32.const 1)
  (func (export "output_bytes_cap") (result i32) i32.const 2)

  (func (export "render") (param $size i32) (result i64)
    i32.const 0
    i32.load8_u

    i32.const 100
    i32.eq
    if
      i32.const 1
      i32.const 0
      i32.div_s
      drop
    end

    i32.const 0
    i32.load8_u
    i32.const 99
    i32.eq
    if
      f32.const nan
      i32.trunc_f32_s
      drop
    end

    i32.const 0
    i32.load8_u
    i32.const 110
    i32.eq
    if
      i32.const 7
      i32.const 1
      call_indirect (type $unary)
      drop
    end

    i32.const 0
    i32.load8_u
    i32.const 111
    i32.eq
    if
      i32.const 7
      i32.const 3
      call_indirect (type $unary)
      drop
    end

    i32.const 0
    i32.load8_u
    i32.const 116
    i32.eq
    if
      i32.const 0
      call_indirect (type $nullary)
      drop
    end

    i32.const 7
    i32.const 0
    call_indirect (type $unary)
    drop
    i64.const 4398046511106))
