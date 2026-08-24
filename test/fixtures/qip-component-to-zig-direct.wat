(module
  (memory (export "memory") 1 1)

  (func (export "input_ptr") (result i32)
    i32.const 0)
  (func (export "input_bytes_cap") (result i32)
    i32.const 16)
  (func (export "output_bytes_cap") (result i32)
    i32.const 16)

  (func $identity (param i32) (result i32)
    local.get 0)

  (func (export "render") (param i32) (result i64)
    i32.const 32
    i32.const 0
    local.get 0
    memory.copy
    i32.const 34
    i32.const 32
    i32.const 4
    memory.copy
    i64.const 137438953472
    local.get 0
    call $identity
    i64.extend_i32_u
    i64.or))
