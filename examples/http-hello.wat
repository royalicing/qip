(module $HttpHello
  ;; Memory must be exported with name "memory"
  ;; At least 5 pages needed: input path, output status, headers, body
  (memory (export "memory") 5)

  ;; Required globals for HTTP handling
  (global $input_path_ptr (export "input_path_ptr") i32 (i32.const 0x10000))
  (global $input_path_cap (export "input_path_cap") i32 (i32.const 0x1000))
  
  (global $output_status_ptr (export "output_status_ptr") i32 (i32.const 0x20000))
  (global $output_headers_ptr (export "output_headers_ptr") i32 (i32.const 0x21000))
  (global $output_headers_cap (export "output_headers_cap") i32 (i32.const 0x1000))
  (global $output_body_ptr (export "output_body_ptr") i32 (i32.const 0x30000))
  (global $output_body_cap (export "output_body_cap") i32 (i32.const 0x10000))

  ;; Required export: handle(path_size) -> (headers_size, body_size)
  ;; Reads path from input_path_ptr
  ;; Writes status to output_status_ptr (2 bytes, little-endian u16)
  ;; Writes headers to output_headers_ptr (UTF-8 text)
  ;; Writes body to output_body_ptr (UTF-8 text)
  ;; Returns headers_size and body_size
  (func $handle (export "handle") (param $path_size i32) (result i32 i32)
    (local $headers_size i32)
    (local $body_size i32)

    ;; Write HTTP status 200 (0x00C8 in little-endian)
    (i32.store16 (global.get $output_status_ptr) (i32.const 200))

    ;; Write headers: "content-type: text/plain\r\n"
    ;; We need to write the bytes in correct order
    ;; "content-" = bytes 0-7
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 0)) (i32.const 99))  ;; 'c'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 1)) (i32.const 111)) ;; 'o'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 2)) (i32.const 110)) ;; 'n'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 3)) (i32.const 116)) ;; 't'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 4)) (i32.const 101)) ;; 'e'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 5)) (i32.const 110)) ;; 'n'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 6)) (i32.const 116)) ;; 't'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 7)) (i32.const 45))  ;; '-'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 8)) (i32.const 116)) ;; 't'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 9)) (i32.const 121)) ;; 'y'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 10)) (i32.const 112)) ;; 'p'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 11)) (i32.const 101)) ;; 'e'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 12)) (i32.const 58))  ;; ':'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 13)) (i32.const 32))  ;; ' '
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 14)) (i32.const 116)) ;; 't'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 15)) (i32.const 101)) ;; 'e'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 16)) (i32.const 120)) ;; 'x'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 17)) (i32.const 116)) ;; 't'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 18)) (i32.const 47))  ;; '/'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 19)) (i32.const 112)) ;; 'p'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 20)) (i32.const 108)) ;; 'l'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 21)) (i32.const 97))  ;; 'a'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 22)) (i32.const 105)) ;; 'i'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 23)) (i32.const 110)) ;; 'n'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 24)) (i32.const 13))  ;; '\r'
    (i32.store8 (i32.add (global.get $output_headers_ptr) (i32.const 25)) (i32.const 10))  ;; '\n'
    
    (local.set $headers_size (i32.const 26))

    ;; Write body: "Hello from HTTP handler!"
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 0)) (i32.const 72))  ;; 'H'
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 1)) (i32.const 101)) ;; 'e'
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 2)) (i32.const 108)) ;; 'l'
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 3)) (i32.const 108)) ;; 'l'
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 4)) (i32.const 111)) ;; 'o'
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 5)) (i32.const 32))  ;; ' '
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 6)) (i32.const 102)) ;; 'f'
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 7)) (i32.const 114)) ;; 'r'
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 8)) (i32.const 111)) ;; 'o'
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 9)) (i32.const 109))  ;; 'm'
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 10)) (i32.const 32))  ;; ' '
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 11)) (i32.const 72))  ;; 'H'
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 12)) (i32.const 84))  ;; 'T'
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 13)) (i32.const 84))  ;; 'T'
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 14)) (i32.const 80))  ;; 'P'
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 15)) (i32.const 32))  ;; ' '
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 16)) (i32.const 104)) ;; 'h'
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 17)) (i32.const 97))  ;; 'a'
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 18)) (i32.const 110)) ;; 'n'
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 19)) (i32.const 100)) ;; 'd'
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 20)) (i32.const 108)) ;; 'l'
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 21)) (i32.const 101)) ;; 'e'
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 22)) (i32.const 114)) ;; 'r'
    (i32.store8 (i32.add (global.get $output_body_ptr) (i32.const 23)) (i32.const 33))  ;; '!'
    
    (local.set $body_size (i32.const 24))

    ;; Return headers_size and body_size
    (local.get $headers_size)
    (local.get $body_size)
  )
)
