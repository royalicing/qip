.PHONY: examples examples-wat-wasm examples-c-wasm examples-zig-wasm test

qip: main.go go.mod go.sum
	go fmt main.go
	go build -ldflags="-s -w" -trimpath

examples/%.wasm: examples/%.wat
	wat2wasm $< -o $@

examples/rgba/%.wasm: examples/rgba/%.wat
	wat2wasm $< -o $@

examples-wat-wasm: $(patsubst examples/%.wat,examples/%.wasm,$(wildcard examples/*.wat)) $(patsubst examples/rgba/%.wat,examples/rgba/%.wasm,$(wildcard examples/rgba/*.wat))

examples/%.wasm: examples/%.c
	zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry -Wl,--export=run -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_ptr -Wl,--export=output_utf8_cap -O3 -o $@

examples-c-wasm: $(patsubst examples/%.c,examples/%.wasm,$(wildcard examples/*.c))

examples/%.wasm: examples/%.zig
	zig build-exe $< -target wasm32-freestanding -O ReleaseSmall -fno-entry --export=run --export=input_ptr --export=input_utf8_cap --export=output_ptr --export=output_utf8_cap -femit-bin=$@

examples-zig-wasm: $(patsubst examples/%.zig,examples/%.wasm,$(wildcard examples/*.zig))

examples: examples-wat-wasm examples-c-wasm examples-zig-wasm

test: qip examples
	@mkdir -p test
	@rm -f test/latest.txt
	@printf %s "hello" | ./qip run examples/base64-encode.wasm >> test/latest.txt
	@printf %s "abc" | ./qip run examples/crc.wasm >> test/latest.txt
	@printf %s "btn-primary" | ./qip run examples/css-class-validator.wasm >> test/latest.txt
	@printf %s "+14155552671" | ./qip run examples/e164.wasm >> test/latest.txt
	@printf %s "World" | ./qip run examples/hello.wasm >> test/latest.txt
	@printf %s "World" | ./qip run examples/hello-c.wasm >> test/latest.txt
	@printf %s "World" | ./qip run examples/hello-zig.wasm >> test/latest.txt
	@printf %s "#ff8800" | ./qip run examples/hex-to-rgb.wasm >> test/latest.txt
	@printf %s "main-content" | ./qip run examples/html-id-validator.wasm >> test/latest.txt
	@printf %s "email" | ./qip run examples/html-input-name-validator.wasm >> test/latest.txt
	@printf %s "div" | ./qip run examples/html-tag-validator.wasm >> test/latest.txt
	@printf %s "49927398716" | ./qip run examples/luhn.wasm >> test/latest.txt
	@printf %s "255,0,170" | ./qip run examples/rgb-to-hex.wasm >> test/latest.txt
	@printf %s "com" | ./qip run examples/tld-validator.wasm >> test/latest.txt
	@printf %s "  hi  " | ./qip run examples/trim.wasm >> test/latest.txt
	@printf %s "hello" | ./qip run examples/utf8-validate.wasm >> test/latest.txt
	@cat examples/hello.wasm | ./qip run examples/wasm-to-js.wasm >> test/latest.txt
	diff test/expected.txt test/latest.txt
	cp test/latest.txt test/expected.txt
