(module $Base64Decode
  (memory (export "memory") 3 3)
  (global $input_ptr i32 (i32.const 0x10000))
  (global $input_utf8_cap i32 (i32.const 0x10000))
  (global $output_ptr i32 (i32.const 0x20000))
  (global $output_bytes_cap i32 (i32.const 0x10000))
  (global $pending_commit_result (mut i64) (i64.const 1))

  (func (export "input_ptr") (result i32)
    (global.get $input_ptr))
  (func (export "input_utf8_cap") (result i32)
    (global.get $input_utf8_cap))
  (func (export "output_ptr") (result i32)
    (global.get $output_ptr))
  (func (export "output_bytes_cap") (result i32)
    (global.get $output_bytes_cap))

  ;; Decode one RFC 4648 Base64 character. Padding is validated by render.
  (func $decode_base64_char (param $char i32) (result i32)
    (if (result i32)
      (i32.and
        (i32.ge_u (local.get $char) (i32.const 65))
        (i32.le_u (local.get $char) (i32.const 90)))
      (then (i32.sub (local.get $char) (i32.const 65)))
      (else
        (if (result i32)
          (i32.and
            (i32.ge_u (local.get $char) (i32.const 97))
            (i32.le_u (local.get $char) (i32.const 122)))
          (then (i32.sub (local.get $char) (i32.const 71)))
          (else
            (if (result i32)
              (i32.and
                (i32.ge_u (local.get $char) (i32.const 48))
                (i32.le_u (local.get $char) (i32.const 57)))
              (then (i32.add (local.get $char) (i32.const 4)))
              (else
                (if (result i32) (i32.eq (local.get $char) (i32.const 43))
                  (then (i32.const 62))
                  (else
                    (if (result i32) (i32.eq (local.get $char) (i32.const 47))
                      (then (i32.const 63))
                      (else (i32.const -1))))))))))))

  ;; Reject invalid input and include its first known byte offset.
  (func $reject (param $offset i32) (result i32)
    (global.set $pending_commit_result
      (i64.add
        (i64.const -4611686018427387904)
        (i64.extend_i32_u (local.get $offset))))
    (i32.const 0))

  (func (export "render") (param $input_size i32) (result i32)
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

    ;; A second render before commit is a host call-order violation.
    (if (i64.ne (global.get $pending_commit_result) (i64.const 1))
      (then unreachable))
    (if (i32.gt_u (local.get $input_size) (global.get $input_utf8_cap))
      (then unreachable))

    (global.set $pending_commit_result (i64.const -4611686018427387904))

    (block $finish
      ;; This strict profile accepts complete four-byte groups. The final
      ;; group uses '=' padding when the decoded byte count requires it.
      (if (i32.and (local.get $input_size) (i32.const 3))
        (then
          (local.set $output_idx (call $reject (local.get $input_size)))
          (br $finish)))

    (block $done
      (loop $groups
        (br_if $done (i32.ge_u (local.get $input_idx) (local.get $input_size)))

        (local.set $c1
          (i32.load8_u (i32.add (global.get $input_ptr) (local.get $input_idx))))
        (local.set $c2
          (i32.load8_u
            (i32.add (global.get $input_ptr)
              (i32.add (local.get $input_idx) (i32.const 1)))))
        (local.set $c3
          (i32.load8_u
            (i32.add (global.get $input_ptr)
              (i32.add (local.get $input_idx) (i32.const 2)))))
        (local.set $c4
          (i32.load8_u
            (i32.add (global.get $input_ptr)
              (i32.add (local.get $input_idx) (i32.const 3)))))

        (local.set $v1 (call $decode_base64_char (local.get $c1)))
        (if (i32.lt_s (local.get $v1) (i32.const 0))
          (then
            (local.set $output_idx (call $reject (local.get $input_idx)))
            (br $finish)))
        (local.set $v2 (call $decode_base64_char (local.get $c2)))
        (if (i32.lt_s (local.get $v2) (i32.const 0))
          (then
            (local.set $output_idx
              (call $reject (i32.add (local.get $input_idx) (i32.const 1))))
            (br $finish)))

        (local.set $padding (i32.const 0))
        (if (i32.eq (local.get $c3) (i32.const 61))
          (then
            (local.set $padding (i32.const 2))
            (if (i32.ne (local.get $c4) (i32.const 61))
              (then
                (local.set $output_idx
                  (call $reject (i32.add (local.get $input_idx) (i32.const 2))))
                (br $finish)))
            (if
              (i32.ne
                (i32.add (local.get $input_idx) (i32.const 4))
                (local.get $input_size))
              (then
                (local.set $output_idx
                  (call $reject (i32.add (local.get $input_idx) (i32.const 2))))
                (br $finish)))
            (if (i32.and (local.get $v2) (i32.const 15))
              (then
                (local.set $output_idx
                  (call $reject (i32.add (local.get $input_idx) (i32.const 1))))
                (br $finish))))
          (else
            (local.set $v3 (call $decode_base64_char (local.get $c3)))
            (if (i32.lt_s (local.get $v3) (i32.const 0))
              (then
                (local.set $output_idx
                  (call $reject (i32.add (local.get $input_idx) (i32.const 2))))
                (br $finish)))
            (if (i32.eq (local.get $c4) (i32.const 61))
              (then
                (local.set $padding (i32.const 1))
                (if
                  (i32.ne
                    (i32.add (local.get $input_idx) (i32.const 4))
                    (local.get $input_size))
                  (then
                    (local.set $output_idx
                      (call $reject (i32.add (local.get $input_idx) (i32.const 3))))
                    (br $finish)))
                (if (i32.and (local.get $v3) (i32.const 3))
                  (then
                    (local.set $output_idx
                      (call $reject (i32.add (local.get $input_idx) (i32.const 2))))
                    (br $finish))))
              (else
                (local.set $v4 (call $decode_base64_char (local.get $c4)))
                (if (i32.lt_s (local.get $v4) (i32.const 0))
                  (then
                    (local.set $output_idx
                      (call $reject
                        (i32.add (local.get $input_idx) (i32.const 3))))
                    (br $finish)))))))

        (i32.store8
          (i32.add (global.get $output_ptr) (local.get $output_idx))
          (i32.or
            (i32.shl (local.get $v1) (i32.const 2))
            (i32.shr_u (local.get $v2) (i32.const 4))))
        (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))

        (if (i32.lt_u (local.get $padding) (i32.const 2))
          (then
            (i32.store8
              (i32.add (global.get $output_ptr) (local.get $output_idx))
              (i32.or
                (i32.shl (i32.and (local.get $v2) (i32.const 15)) (i32.const 4))
                (i32.shr_u (local.get $v3) (i32.const 2))))
            (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))))

        (if (i32.eqz (local.get $padding))
          (then
            (i32.store8
              (i32.add (global.get $output_ptr) (local.get $output_idx))
              (i32.or
                (i32.shl (i32.and (local.get $v3) (i32.const 3)) (i32.const 6))
                (local.get $v4)))
            (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))))

        (local.set $input_idx (i32.add (local.get $input_idx) (i32.const 4)))
        (br $groups)))

      (global.set $pending_commit_result (i64.const 0)))

    (if (i32.gt_u (local.get $output_idx) (global.get $output_bytes_cap))
      (then unreachable))
    (local.get $output_idx))

  ;; commit never traps. It closes both accepted and rejected transactions.
  (func (export "commit") (result i64)
    (local $result i64)
    (local.set $result (global.get $pending_commit_result))
    (if (i64.eq (local.get $result) (i64.const 1))
      (then (local.set $result (i64.const -4611686018427387904))))
    (global.set $pending_commit_result (i64.const 1))
    (local.get $result))
)
