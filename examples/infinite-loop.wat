(module
  (memory (export "memory") 1)

  (func (export "input_ptr") (result i32)
    (i32.const 0)
  )
  (func (export "input_utf8_cap") (result i32)
    (i32.const 65536)
  )
  (func (export "output_ptr") (result i32)
    (i32.const 0)
  )
  (func (export "output_utf8_cap") (result i32)
    (i32.const 65536)
  )

  (func (export "run") (param i32) (result i32)
    (loop $forever
      br $forever
    )
    unreachable
  )
)
