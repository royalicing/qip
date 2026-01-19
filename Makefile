.PHONY: examples examples-wasm examples-c-wasm examples-zig-wasm

qip: main.go go.mod go.sum
	go fmt main.go
	go build -ldflags="-s -w" -trimpath

examples/%.wasm: examples/%.wat
	wat2wasm $< -o $@

examples-wat-wasm: $(patsubst examples/%.wat,examples/%.wasm,$(wildcard examples/*.wat))

examples/%.wasm: examples/%.c
	zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry -Wl,--export=run -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_ptr -Wl,--export=output_utf8_cap -O3 -o $@

examples-c-wasm: $(patsubst examples/%.c,examples/%.wasm,$(wildcard examples/*.c))

examples/%.wasm: examples/%.zig
	zig build-exe $< -target wasm32-freestanding -O ReleaseSmall -fno-entry --export=run --export=input_ptr --export=input_utf8_cap --export=output_ptr --export=output_utf8_cap -femit-bin=$@

examples-zig-wasm: $(patsubst examples/%.zig,examples/%.wasm,$(wildcard examples/*.zig))

examples: examples-wat-wasm examples-c-wasm examples-zig-wasm
