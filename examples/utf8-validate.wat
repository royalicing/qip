(module $UTF8Validate
  (memory (export "memory") 3)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0x10000))
  (global $input_bytes_cap (export "input_bytes_cap") i32 (i32.const 0x10000))

  ;; Check if byte is a valid continuation byte (10xxxxxx)
  (func $is_continuation (param $byte i32) (result i32)
    (i32.eq
      (i32.and (local.get $byte) (i32.const 0xC0))
      (i32.const 0x80))
  )

  ;; Returns: 1 if valid UTF-8, 0 if invalid
  (func $run (export "run") (param $input_size i32) (result i32)
    (local $i i32)
    (local $byte i32)
    (local $byte2 i32)
    (local $byte3 i32)
    (local $byte4 i32)
    (local $codepoint i32)

    ;; Empty input is valid
    (if (i32.eq (local.get $input_size) (i32.const 0))
      (then (return (i32.const 1)))
    )

    (loop $continue
      (local.set $byte (i32.load8_u (i32.add (global.get $input_ptr) (local.get $i))))

      ;; 1-byte sequence: 0xxxxxxx (0x00-0x7F)
      (if (i32.le_u (local.get $byte) (i32.const 0x7F))
        (then
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br_if $continue (i32.lt_u (local.get $i) (local.get $input_size)))
          (return (i32.const 1))
        )
      )

      ;; 2-byte sequence: 110xxxxx 10xxxxxx (0xC2-0xDF)
      (if (i32.and
            (i32.ge_u (local.get $byte) (i32.const 0xC2))
            (i32.le_u (local.get $byte) (i32.const 0xDF)))
        (then
          ;; Need at least 1 more byte
          (if (i32.ge_u (i32.add (local.get $i) (i32.const 1)) (local.get $input_size))
            (then (return (i32.const 0)))
          )
          (local.set $byte2 (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $i) (i32.const 1)))))
          (if (i32.eqz (call $is_continuation (local.get $byte2)))
            (then (return (i32.const 0)))
          )
          (local.set $i (i32.add (local.get $i) (i32.const 2)))
          (br_if $continue (i32.lt_u (local.get $i) (local.get $input_size)))
          (return (i32.const 1))
        )
      )

      ;; 3-byte sequence: 1110xxxx 10xxxxxx 10xxxxxx (0xE0-0xEF)
      (if (i32.and
            (i32.ge_u (local.get $byte) (i32.const 0xE0))
            (i32.le_u (local.get $byte) (i32.const 0xEF)))
        (then
          ;; Need at least 2 more bytes
          (if (i32.ge_u (i32.add (local.get $i) (i32.const 2)) (local.get $input_size))
            (then (return (i32.const 0)))
          )
          (local.set $byte2 (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $i) (i32.const 1)))))
          (local.set $byte3 (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $i) (i32.const 2)))))

          ;; Check continuation bytes
          (if (i32.eqz (call $is_continuation (local.get $byte2)))
            (then (return (i32.const 0)))
          )
          (if (i32.eqz (call $is_continuation (local.get $byte3)))
            (then (return (i32.const 0)))
          )

          ;; Check for overlong encoding and surrogates
          ;; 0xE0 must be followed by 0xA0-0xBF (not 0x80-0x9F, which would be overlong)
          (if (i32.eq (local.get $byte) (i32.const 0xE0))
            (then
              (if (i32.lt_u (local.get $byte2) (i32.const 0xA0))
                (then (return (i32.const 0)))
              )
            )
          )

          ;; 0xED must be followed by 0x80-0x9F (not 0xA0-0xBF, which would encode surrogates U+D800-U+DFFF)
          (if (i32.eq (local.get $byte) (i32.const 0xED))
            (then
              (if (i32.ge_u (local.get $byte2) (i32.const 0xA0))
                (then (return (i32.const 0)))
              )
            )
          )

          (local.set $i (i32.add (local.get $i) (i32.const 3)))
          (br_if $continue (i32.lt_u (local.get $i) (local.get $input_size)))
          (return (i32.const 1))
        )
      )

      ;; 4-byte sequence: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx (0xF0-0xF4)
      (if (i32.and
            (i32.ge_u (local.get $byte) (i32.const 0xF0))
            (i32.le_u (local.get $byte) (i32.const 0xF4)))
        (then
          ;; Need at least 3 more bytes
          (if (i32.ge_u (i32.add (local.get $i) (i32.const 3)) (local.get $input_size))
            (then (return (i32.const 0)))
          )
          (local.set $byte2 (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $i) (i32.const 1)))))
          (local.set $byte3 (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $i) (i32.const 2)))))
          (local.set $byte4 (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $i) (i32.const 3)))))

          ;; Check continuation bytes
          (if (i32.eqz (call $is_continuation (local.get $byte2)))
            (then (return (i32.const 0)))
          )
          (if (i32.eqz (call $is_continuation (local.get $byte3)))
            (then (return (i32.const 0)))
          )
          (if (i32.eqz (call $is_continuation (local.get $byte4)))
            (then (return (i32.const 0)))
          )

          ;; Check for overlong encoding
          ;; 0xF0 must be followed by 0x90-0xBF (not 0x80-0x8F, which would be overlong)
          (if (i32.eq (local.get $byte) (i32.const 0xF0))
            (then
              (if (i32.lt_u (local.get $byte2) (i32.const 0x90))
                (then (return (i32.const 0)))
              )
            )
          )

          ;; 0xF4 must be followed by 0x80-0x8F (not 0x90-0xBF, which would exceed U+10FFFF)
          (if (i32.eq (local.get $byte) (i32.const 0xF4))
            (then
              (if (i32.ge_u (local.get $byte2) (i32.const 0x90))
                (then (return (i32.const 0)))
              )
            )
          )

          (local.set $i (i32.add (local.get $i) (i32.const 4)))
          (br_if $continue (i32.lt_u (local.get $i) (local.get $input_size)))
          (return (i32.const 1))
        )
      )

      ;; Invalid start byte (0x80-0xBF, 0xC0-0xC1, 0xF5-0xFF)
      (return (i32.const 0))
    )

    ;; All bytes processed successfully
    (i32.const 1)
  )
)
