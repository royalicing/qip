(module
  (type (;0;) (func (param i32)))
  (func (;0;) (type 0) (param i32)
    (local i32 i32 f32 f32)
    local.get 0
    local.set 1
    local.get 0
    i32.const 65536
    i32.add
    local.set 2
    f32.const 0x1p+0 (;=1;)
    global.get 0
    f32.const 0x1p+0 (;=1;)
    f32.sub
    f32.max
    local.set 4
    loop  ;; label = @1
      local.get 1
      f32.load
      local.get 4
      f32.mul
      f32.nearest
      local.get 4
      f32.div
      local.set 3
      local.get 1
      local.get 3
      f32.store
      local.get 1
      i32.const 4
      i32.add
      f32.load
      local.get 4
      f32.mul
      f32.nearest
      local.get 4
      f32.div
      local.set 3
      local.get 1
      i32.const 4
      i32.add
      local.get 3
      f32.store
      local.get 1
      i32.const 8
      i32.add
      f32.load
      local.get 4
      f32.mul
      f32.nearest
      local.get 4
      f32.div
      local.set 3
      local.get 1
      i32.const 8
      i32.add
      local.get 3
      f32.store
      local.get 1
      i32.const 16
      i32.add
      local.set 1
      local.get 1
      local.get 2
      i32.lt_u
      br_if 0 (;@1;)
    end)
  (memory (;0;) 1 1)
  (global (;0;) f32 (f32.const 0x1p+3 (;=8;)))
  (global $input_ptr (;1;) i32 (i32.const 0))
  (global $input_bytes_cap (;2;) i32 (i32.const 65536))
  (func (export "input_ptr") (result i32)
    (global.get $input_ptr))
  (func (export "input_bytes_cap") (result i32)
    (global.get $input_bytes_cap))
  (export "memory" (memory 0))
  (export "param_radius" (global 0))
  (export "tile_rgba32float_64x64" (func 0)))
