(module $Base64Decode
  (memory (export "memory") 3)
  (global $input_ptr (export "input_ptr") i32 (i32.const 0x10000))
  (global $input_utf8_cap (export "input_utf8_cap") i32 (i32.const 0x10000))
  (global $output_ptr (export "output_ptr") i32 (i32.const 0x20000))
  (global $output_bytes_cap (export "output_bytes_cap") i32 (i32.const 0x10000))

  ;; Decode base64 character to 6-bit value (returns -1 for invalid)
  (func $decode_base64_char (param $char i32) (result i32)
    ;; A-Z (65-90) -> 0-25
    (if (result i32) (i32.and
          (i32.ge_u (local.get $char) (i32.const 65))
          (i32.le_u (local.get $char) (i32.const 90)))
      (then
        (i32.sub (local.get $char) (i32.const 65))
      )
      (else
        ;; a-z (97-122) -> 26-51
        (if (result i32) (i32.and
              (i32.ge_u (local.get $char) (i32.const 97))
              (i32.le_u (local.get $char) (i32.const 122)))
          (then
            (i32.sub (local.get $char) (i32.const 71))
          )
          (else
            ;; 0-9 (48-57) -> 52-61
            (if (result i32) (i32.and
                  (i32.ge_u (local.get $char) (i32.const 48))
                  (i32.le_u (local.get $char) (i32.const 57)))
              (then
                (i32.add (local.get $char) (i32.const 4))
              )
              (else
                ;; + (43) -> 62
                (if (result i32) (i32.eq (local.get $char) (i32.const 43))
                  (then
                    (i32.const 62)
                  )
                  (else
                    ;; / (47) -> 63
                    (if (result i32) (i32.eq (local.get $char) (i32.const 47))
                      (then
                        (i32.const 63)
                      )
                      (else
                        ;; Invalid character
                        (i32.const -1)
                      )
                    )
                  )
                )
              )
            )
          )
        )
      )
    )
  )

  (func $run (export "run") (param $input_size i32) (result i32)
    (local $input_idx i32)
    (local $output_idx i32)
    (local $c1 i32)
    (local $c2 i32)
    (local $c3 i32)
    (local $c4 i32)
    (local $v1 i32)
    (local $v2 i32)
    (local $v3 i32)
    (local $v4 i32)
    (local $padding i32)

    ;; Return 0 if input is empty
    (if (i32.eq (local.get $input_size) (i32.const 0))
      (then (return (i32.const 0)))
    )

    ;; Process 4-character groups
    (block $break
      (loop $continue
        ;; Break if less than 4 characters remaining
        (br_if $break (i32.gt_u (i32.add (local.get $input_idx) (i32.const 4)) (local.get $input_size)))

        ;; Read 4 characters
        (local.set $c1 (i32.load8_u (i32.add (global.get $input_ptr) (local.get $input_idx))))
        (local.set $c2 (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $input_idx) (i32.const 1)))))
        (local.set $c3 (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $input_idx) (i32.const 2)))))
        (local.set $c4 (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $input_idx) (i32.const 3)))))

        ;; Check for padding
        (local.set $padding (i32.const 0))
        (if (i32.eq (local.get $c4) (i32.const 61))
          (then (local.set $padding (i32.add (local.get $padding) (i32.const 1))))
        )
        (if (i32.eq (local.get $c3) (i32.const 61))
          (then (local.set $padding (i32.add (local.get $padding) (i32.const 1))))
        )

        ;; Decode characters
        (local.set $v1 (call $decode_base64_char (local.get $c1)))
        (local.set $v2 (call $decode_base64_char (local.get $c2)))

        ;; First byte: 6 bits from v1 + top 2 bits from v2
        (i32.store8
          (i32.add (global.get $output_ptr) (local.get $output_idx))
          (i32.or
            (i32.shl (local.get $v1) (i32.const 2))
            (i32.shr_u (local.get $v2) (i32.const 4))))
        (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))

        ;; If padding >= 2, we're done with this group
        (if (i32.lt_u (local.get $padding) (i32.const 2))
          (then
            (local.set $v3 (call $decode_base64_char (local.get $c3)))

            ;; Second byte: bottom 4 bits from v2 + top 4 bits from v3
            (i32.store8
              (i32.add (global.get $output_ptr) (local.get $output_idx))
              (i32.or
                (i32.shl (i32.and (local.get $v2) (i32.const 15)) (i32.const 4))
                (i32.shr_u (local.get $v3) (i32.const 2))))
            (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))

            ;; If padding >= 1, we're done with this group
            (if (i32.eq (local.get $padding) (i32.const 0))
              (then
                (local.set $v4 (call $decode_base64_char (local.get $c4)))

                ;; Third byte: bottom 2 bits from v3 + 6 bits from v4
                (i32.store8
                  (i32.add (global.get $output_ptr) (local.get $output_idx))
                  (i32.or
                    (i32.shl (i32.and (local.get $v3) (i32.const 3)) (i32.const 6))
                    (local.get $v4)))
                (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))
              )
            )
          )
        )

        (local.set $input_idx (i32.add (local.get $input_idx) (i32.const 4)))
        (br $continue)
      )
    )

    ;; Return output size
    (local.get $output_idx)
  )
)
