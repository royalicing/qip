.PHONY: examples recipes examples-wat-wasm examples-c-wasm examples-zig-wasm test

default: qip examples recipes

include ./examples/sqlite3/sqlite.mk

WASM_STACK_SIZE ?= 65536
WASM_STACK_FLAG := -Wl,-z,stack-size=$(WASM_STACK_SIZE)
ZIG_WASM_FLAGS := -target wasm32-freestanding -O ReleaseSmall -fno-entry -rdynamic

qip: main.go go.mod go.sum
	go fix ./...
	go fmt main.go
	go build -ldflags="-s -w" -trimpath

examples/%.wasm: examples/%.wat
	wat2wasm $< -o $@

examples/rgba/%.wasm: examples/rgba/%.wat
	wat2wasm $< -o $@

examples-wat-wasm: $(patsubst examples/%.wat,examples/%.wasm,$(wildcard examples/*.wat)) $(patsubst examples/rgba/%.wat,examples/rgba/%.wasm,$(wildcard examples/rgba/*.wat))

examples/sqlite-table-names.wasm: examples/sqlite-table-names.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--export=run -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_bytes_cap -Wl,--export=output_ptr -Wl,--export=output_utf8_cap -Oz -o $@

examples/text-to-bmp.wasm: examples/text-to-bmp.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--export=run -Wl,--export=uniform_set_leading -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_ptr -Wl,--export=output_bytes_cap -Oz -o $@

examples/bmp-double.wasm: examples/bmp-double.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--export=run -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_bytes_cap -Wl,--export=output_ptr -Wl,--export=output_bytes_cap -Oz -o $@

examples/bmp-double-simd.wasm: examples/bmp-double-simd.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) -mcpu=generic+simd128 -femit-bin=$@

examples/js-to-bmp.wasm: examples/js-to-bmp.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--export=run -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_ptr -Wl,--export=output_bytes_cap -Oz -o $@

ZIG_CACHE_DIR ?= /tmp/zig-cache
ZIG_GLOBAL_CACHE_DIR ?= /tmp/zig-global-cache
ZIG_ENV := ZIG_CACHE_DIR=$(ZIG_CACHE_DIR) ZIG_GLOBAL_CACHE_DIR=$(ZIG_GLOBAL_CACHE_DIR)

examples/c-to-bmp.wasm: examples/c-to-bmp.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--export=run -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_ptr -Wl,--export=output_bytes_cap -Oz -o $@

recipes/text/markdown/20-html-page-wrap.wasm: recipes/text/markdown/styles.css

examples/markdown-basic.wasm: recipes/text/markdown/10-markdown-basic.wasm
	cp $< $@

examples/html-page-wrap.wasm: recipes/text/markdown/20-html-page-wrap.wasm
	cp $< $@

examples/%.wasm: examples/%.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--export=run -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_ptr -Wl,--export=output_utf8_cap -Oz -o $@

examples-c-wasm: $(patsubst examples/%.c,examples/%.wasm,$(wildcard examples/*.c))

examples/%.wasm: examples/%.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) -femit-bin=$@

recipes/%.wasm: recipes/%.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) -femit-bin=$@

examples-zig-wasm: $(patsubst examples/%.zig,examples/%.wasm,$(wildcard examples/*.zig))
examples-zig-wasm: examples/markdown-basic.wasm
examples-zig-wasm: examples/html-page-wrap.wasm
examples-zig-wasm: recipes/text/markdown/10-markdown-basic.wasm
examples-zig-wasm: recipes/text/markdown/20-html-page-wrap.wasm

recipes: recipes/text/markdown/10-markdown-basic.wasm recipes/text/markdown/20-html-page-wrap.wasm

examples: examples-wat-wasm examples-c-wasm examples-zig-wasm

test: qip examples test-zig test-snapshot
	diff test/expected.txt test/latest.txt && echo "Snapshots pass."

test-snapshot: qip examples
	@mkdir -p test
	@rm -f test/latest.txt
	@printf "%s\n" "module: base64-encode.wasm" >> test/latest.txt
	@printf %s "hello" | ./qip run examples/base64-encode.wasm >> test/latest.txt
	@printf "%s\n" "module: base64-encode.wasm | base64-decode.wasm" >> test/latest.txt
	@printf %s "hello" | ./qip run examples/base64-encode.wasm examples/base64-decode.wasm >> test/latest.txt
	@printf "\n" >> test/latest.txt
	@printf "%s\n" "module: calendar.wasm" >> test/latest.txt
	@printf %s "2024-03" | ./qip run examples/calendar.wasm >> test/latest.txt
	@printf "\n" >> test/latest.txt
	@printf "%s\n" "module: bmp-to-ico.wasm | base64-encode.wasm" >> test/latest.txt
	@printf %s "424D3A0000000000000036000000280000000100000001000000010018000000000004000000000000000000000000000000000000000000FF00" | xxd -r -p | ./qip run examples/bmp-to-ico.wasm examples/base64-encode.wasm >> test/latest.txt
	@printf "\n" >> test/latest.txt
	@printf "%s\n" "module: crc.wasm" >> test/latest.txt
	@printf %s "abc" | ./qip run examples/crc.wasm >> test/latest.txt
	@printf "%s\n" "module: css-class-validator.wasm" >> test/latest.txt
	@printf %s "btn-primary" | ./qip run examples/css-class-validator.wasm >> test/latest.txt
	@printf "%s\n" "module: e164.wasm" >> test/latest.txt
	@printf %s "+14155552671" | ./qip run examples/e164.wasm >> test/latest.txt
	@printf "%s\n" "module: zlib-compress.wasm | base64-encode.wasm" >> test/latest.txt
	@printf %s "qip + wasm" | ./qip run examples/zlib-compress.wasm examples/base64-encode.wasm >> test/latest.txt
	@printf "%s\n" "module: zlib-compress.wasm | zlib-decompress.wasm" >> test/latest.txt
	@printf %s "qip + wasm" | ./qip run examples/zlib-compress.wasm examples/zlib-decompress.wasm >> test/latest.txt
	@printf "\n" >> test/latest.txt
	@printf "%s\n" "module: zlib-compress-fixed-huffman.wasm | base64-encode.wasm" >> test/latest.txt
	@printf %s "qip + wasm" | ./qip run examples/zlib-compress-fixed-huffman.wasm examples/base64-encode.wasm >> test/latest.txt
	@printf "%s\n" "module: zlib-compress-fixed-huffman.wasm | zlib-decompress.wasm" >> test/latest.txt
	@printf %s "qip + wasm" | ./qip run examples/zlib-compress-fixed-huffman.wasm examples/zlib-decompress.wasm >> test/latest.txt
	@printf "\n" >> test/latest.txt
	@printf "%s\n" "module: zlib-compress-dynamic-huffman.wasm | base64-encode.wasm" >> test/latest.txt
	@printf %s "qip + wasm" | ./qip run examples/zlib-compress-dynamic-huffman.wasm examples/base64-encode.wasm >> test/latest.txt
	@printf "%s\n" "module: zlib-compress-dynamic-huffman.wasm | zlib-decompress.wasm" >> test/latest.txt
	@printf %s "qip + wasm" | ./qip run examples/zlib-compress-dynamic-huffman.wasm examples/zlib-decompress.wasm >> test/latest.txt
	@printf "\n" >> test/latest.txt
	@printf "%s\n" "module: hello.wasm" >> test/latest.txt
	@printf %s "World" | ./qip run examples/hello.wasm >> test/latest.txt
	@printf "%s\n" "module: hello-c.wasm" >> test/latest.txt
	@printf %s "World" | ./qip run examples/hello-c.wasm >> test/latest.txt
	@printf "%s\n" "module: hello-zig.wasm" >> test/latest.txt
	@printf %s "World" | ./qip run examples/hello-zig.wasm >> test/latest.txt
	@printf "%s\n" "module: hex-to-rgb.wasm" >> test/latest.txt
	@printf %s "#ff8800" | ./qip run examples/hex-to-rgb.wasm >> test/latest.txt
	@printf "%s\n" "module: html-id-validator.wasm" >> test/latest.txt
	@printf %s "main-content" | ./qip run examples/html-id-validator.wasm >> test/latest.txt
	@printf "%s\n" "module: html-input-name-validator.wasm" >> test/latest.txt
	@printf %s "email" | ./qip run examples/html-input-name-validator.wasm >> test/latest.txt
	@printf "%s\n" "module: html-aria-extractor.wasm" >> test/latest.txt
	@printf %s "<a href=\"/a\">Go</a><button>Push</button><h2>Title</h2><input type=\"radio\" aria-label=\"Yes\"><div role=\"checkbox\" aria-label=\"Ok\"></div>" | ./qip run examples/html-aria-extractor.wasm >> test/latest.txt
	@printf "%s\n" "module: html-tag-validator.wasm" >> test/latest.txt
	@printf %s "div" | ./qip run examples/html-tag-validator.wasm >> test/latest.txt
	@printf "%s\n" "module: luhn.wasm" >> test/latest.txt
	@printf %s "49927398716" | ./qip run examples/luhn.wasm >> test/latest.txt
	@printf "%s\n" "module: markdown-basic.wasm" >> test/latest.txt
	@printf "%b" "# Title\nHello **World**\n" | ./qip run examples/markdown-basic.wasm >> test/latest.txt
	@printf "%s\n" "module: markdown-basic.wasm (table)" >> test/latest.txt
	@printf "%b" '| A | B |\n| --- | --- |\n| `x` | **y** |\n' | ./qip run examples/markdown-basic.wasm >> test/latest.txt
	@printf "%s\n" "module: markdown-basic.wasm | html-page-wrap.wasm" >> test/latest.txt
	@printf "%b" "# Title\nHello **World**\n" | ./qip run examples/markdown-basic.wasm examples/html-page-wrap.wasm >> test/latest.txt
	@printf "%s\n" "module: rgb-to-hex.wasm" >> test/latest.txt
	@printf %s "255,0,170" | ./qip run examples/rgb-to-hex.wasm >> test/latest.txt
	@printf "%s\n" "module: rgb-to-hex.wasm (rgb())" >> test/latest.txt
	@printf %s " rgb( 101, 79, 240 ) " | ./qip run examples/rgb-to-hex.wasm >> test/latest.txt
	@printf "%s\n" "module: tld-validator.wasm" >> test/latest.txt
	@printf %s "com" | ./qip run examples/tld-validator.wasm >> test/latest.txt
	@printf "%s\n" "module: trim.wasm" >> test/latest.txt
	@printf %s "  hi  " | ./qip run examples/trim.wasm >> test/latest.txt
	@printf "%s\n" "module: utf8-must-be-valid.wasm" >> test/latest.txt
	@printf %s "hello" | ./qip run examples/utf8-must-be-valid.wasm >> test/latest.txt
	@printf "%s\n" "module: wasm-to-js.wasm" >> test/latest.txt
	@cat examples/hello.wasm | ./qip run examples/wasm-to-js.wasm >> test/latest.txt

ZIG_TEST_FILES := $(wildcard examples/*.zig) recipes/text/markdown/10-markdown-basic.zig recipes/text/markdown/20-html-page-wrap.zig

test-zig: $(ZIG_TEST_FILES)
	@for f in $^; do \
		echo "zig test $$f"; \
		$(ZIG_ENV) zig test $$f; \
	done
