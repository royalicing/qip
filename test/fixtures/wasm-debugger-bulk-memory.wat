(module
  (memory (export "memory") 1 1)

  (func (export "render") (param i32) (result i64)
    ;; The ranges overlap. Correct memory.copy behavior leaves "ababcdef".
    i32.const 18
    i32.const 16
    i32.const 6
    memory.copy

    ;; memory.fill truncates its value to one byte.
    i32.const 32
    i32.const 4660
    i32.const 4
    memory.fill

    ;; Successful output: pointer 32, size 4.
    i64.const 137438953476)

  (data (i32.const 16) "abcdef"))
