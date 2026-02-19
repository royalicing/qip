;; Infinite Loop Module
;; 
;; This module contains an intentional infinite loop designed to test qip's
;; quota and timeout handling capabilities. The run function will loop forever,
;; incrementing a counter indefinitely.
;;
;; Usage:
;;   echo "test" | qip run examples/infinite-loop.wasm
;;   
;; Expected behavior (with WithCloseOnContextDone enabled):
;;   - With qip run: Terminates after 100ms with "context deadline exceeded"
;;   - With qip bench --timeout-ms N: Terminates after N milliseconds
;;
;; This module is useful for:
;;   - Testing WebAssembly runtime timeout/quota mechanisms
;;   - Verifying context cancellation in qip
;;   - Benchmarking overhead of quota enforcement
;;   - Demonstrating proper resource limits in production use
;;
(module $InfiniteLoop
  ;; Memory must be exported with name "memory"
  ;; At least 3 pages needed: input at 0x10000, output at 0x20000
  (memory (export "memory") 3)

  ;; Required globals for qip integration
  (global $input_ptr (export "input_ptr") i32 (i32.const 0x10000))
  (global $input_utf8_cap (export "input_utf8_cap") i32 (i32.const 0x10000))
  (global $output_ptr (export "output_ptr") i32 (i32.const 0x20000))
  (global $output_utf8_cap (export "output_utf8_cap") i32 (i32.const 0x10000))

  ;; Required export: run(input_size) -> output_size
  ;; This function contains an infinite loop to test qip's quota/timeout handling
  (func $run (export "run") (param $input_size i32) (result i32)
    (local $counter i32)
    
    ;; Initialize counter
    (local.set $counter (i32.const 0))
    
    ;; Infinite loop: continuously increment counter
    (loop $infinite
      ;; Increment counter
      (local.set $counter (i32.add (local.get $counter) (i32.const 1)))
      
      ;; Branch back to loop (infinite)
      (br $infinite)
    )
    
    ;; This line will never be reached
    (i32.const 0)
  )
)
