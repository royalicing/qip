.PHONY: fuzz-zlib compliance modules recipes modules-wat-wasm modules-c-wasm modules-zig-wasm test test-go test-node test-deno test-comply site-static install score wasm-safety-report

default: qip compliance modules recipes

include ./fixtures/sqlite3/sqlite.mk

WASM_STACK_SIZE ?= 65536
WASM_STACK_FLAG := -Wl,-z,stack-size=$(WASM_STACK_SIZE)
ZIG_WASM_FLAGS := -target wasm32-freestanding -O ReleaseSmall -fno-entry -rdynamic
GO_FIX_PKGS := ./cmd/... ./internal/... ./tools/...
GO_FMT_PKGS := . ./cmd/... ./internal/... ./tools/...
GO_TEST_PKGS := . ./cmd/... ./internal/... ./tools/...
QIP_BIN ?= ./qip
QIP_GO_DEPS := main.go $(wildcard cmd/*.go) $(wildcard internal/*.go) $(wildcard internal/*/*.go) $(wildcard embedded/*.js)

qip: go.mod go.sum $(QIP_GO_DEPS)
	go fix $(GO_FIX_PKGS)
	go fmt $(GO_FMT_PKGS)
	go build -ldflags="-s -w" -trimpath

compliance/%.wasm: compliance/%.wat
	wat2wasm $< -o $@

compliance: $(patsubst compliance/%.wat,compliance/%.wasm,$(wildcard compliance/*.wat))

ZIG_CACHE_DIR ?= /tmp/zig-cache
ZIG_GLOBAL_CACHE_DIR ?= /tmp/zig-global-cache
ZIG_ENV := ZIG_CACHE_DIR=$(ZIG_CACHE_DIR) ZIG_GLOBAL_CACHE_DIR=$(ZIG_GLOBAL_CACHE_DIR)
ZIG_WASM_MAX_MEMORY ?= 67108864

MODULE_WAT_FILES := $(shell find modules -type f -name '*.wat')
MODULE_C_FILES := $(shell find modules -type f -name '*.c')
MODULE_ZIG_FILES := $(shell find modules \( -path 'modules/interactive/assets' -o -type d -name 'lib' \) -prune -o -type f -name '*.zig' -print)

MODULE_WAT_TARGETS := $(patsubst %.wat,%.wasm,$(MODULE_WAT_FILES))
MODULE_C_TARGETS := $(patsubst %.c,%.wasm,$(MODULE_C_FILES))
MODULE_ZIG_TARGETS := $(patsubst %.zig,%.wasm,$(MODULE_ZIG_FILES))

modules/%.wasm: modules/%.wat
	wat2wasm $< -o $@

SQLITE3_ZIG_MODULES := sqlite-first-table-dump sqlite-schema sqlite-table-dump sqlite-table-csv sqlite-row-lookup sqlite-table-count
$(foreach m,$(SQLITE3_ZIG_MODULES),modules/application/vnd.sqlite3/$(m).wasm): modules/application/vnd.sqlite3/lib/sqlite.zig

modules/application/vnd.sqlite3/sqlite-table-names.wasm: modules/application/vnd.sqlite3/sqlite-table-names.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--export=render -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_bytes_cap -Wl,--export=output_ptr -Wl,--export=output_utf8_cap -Oz -o $@

modules/utf8/text-to-bmp.wasm: modules/utf8/text-to-bmp.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--export=render -Wl,--export=uniform_set_leading -Wl,--export=uniform_set_cols -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_ptr -Wl,--export=output_bytes_cap -Oz -o $@

modules/utf8/text-to-og-image-font8x8.wasm: modules/utf8/text-to-og-image-font8x8.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--export=render -Wl,--export=uniform_set_text_color -Wl,--export=uniform_set_background_color -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_ptr -Wl,--export=output_bytes_cap -Oz -o $@

modules/image/bmp/bmp-double.wasm: modules/image/bmp/bmp-double.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--export=render -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_bytes_cap -Wl,--export=output_ptr -Wl,--export=output_bytes_cap -Oz -o $@

modules/image/bmp/bmp-double-simd.wasm: modules/image/bmp/bmp-double-simd.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) -mcpu=generic+simd128 -femit-bin=$@

modules/interactive/cover-flow.wasm: modules/interactive/cover-flow.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) -mcpu=generic+simd128 -femit-bin=$@

modules/application/wasm/wasm-safety-check.wasm: ZIG_WASM_MAX_MEMORY = 20971520
modules/application/wasm/wasm-safety-check.wasm: modules/application/wasm/wasm-safety-check.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

modules/application/wasm/wasm-score.wasm: ZIG_WASM_MAX_MEMORY = 14680064
modules/application/wasm/wasm-score.wasm: modules/application/wasm/wasm-score.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

modules/application/wasm/wasm-to-js.wasm: modules/application/wasm/wasm-to-js.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

modules/text/javascript/js-to-bmp.wasm: modules/text/javascript/js-to-bmp.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--export=render -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_ptr -Wl,--export=output_bytes_cap -Oz -o $@

modules/text/x-c/c-to-bmp.wasm: modules/text/x-c/c-to-bmp.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--export=render -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_ptr -Wl,--export=output_bytes_cap -Oz -o $@

recipes/text/markdown/80-html-page-wrap.wasm: recipes/text/markdown/styles.css recipes/text/markdown/header.html recipes/text/markdown/footer.html

modules/text/html/html-add-highlight-stylesheet-night-owl.wasm: modules/text/html/highlight-night-owl.css

recipes/text/markdown/29-add-highlight-stylesheet-night-owl.wasm: modules/text/html/html-add-highlight-stylesheet-night-owl.wasm
	cp $< $@

modules/text/markdown/markdown-basic.wasm: recipes/text/markdown/10-markdown-basic.wasm
	cp $< $@

modules/text/html/html-page-wrap.wasm: recipes/text/markdown/80-html-page-wrap.wasm
	cp $< $@

modules/application/warc/warc-check-broken-links.wasm: ZIG_WASM_MAX_MEMORY = 167772160
modules/application/warc/warc-to-static-tar-no-trailing-slash.wasm: ZIG_WASM_MAX_MEMORY = 335544320
modules/application/warc/warc-add-open-graph-image-meta.wasm: ZIG_WASM_MAX_MEMORY = 671088640
recipes/application/warc/15-add-html-data-path.wasm: ZIG_WASM_MAX_MEMORY = 671088640
modules/image/gif/gifsicle-optimize.wasm: ZIG_WASM_MAX_MEMORY = 167772160
modules/image/bmp/bmp-to-png.wasm: ZIG_WASM_MAX_MEMORY = 134217728
modules/image/png/png-to-bmp.wasm: ZIG_WASM_MAX_MEMORY = 134217728

modules/bytes/zlib-compress-dynamic-huffman-opt.wasm: modules/bytes/lib/deflate.zig
modules/image/bmp/bmp-to-png.wasm: modules/image/bmp/lib/deflate.zig
modules/bytes/zlib-decompress.wasm: modules/bytes/lib/inflate.zig modules/bytes/lib/deflate.zig
modules/image/png/png-to-bmp.wasm: modules/image/png/lib/inflate.zig modules/image/png/lib/deflate.zig

modules/%.wasm: modules/%.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--export=render -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_ptr -Wl,--export=output_utf8_cap -Oz -o $@

modules/%.wasm: modules/%.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

recipes/%.wasm: recipes/%.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

recipes/application/warc/10-add-open-graph-image-meta.wasm: modules/application/warc/warc-add-open-graph-image-meta.wasm
	@mkdir -p $(dir $@)
	ln -sf ../../../modules/application/warc/warc-add-open-graph-image-meta.wasm $@

modules-wat-wasm: $(MODULE_WAT_TARGETS)
modules-c-wasm: $(MODULE_C_TARGETS)
modules-zig-wasm: $(MODULE_ZIG_TARGETS)
modules-zig-wasm: modules/text/markdown/markdown-basic.wasm
modules-zig-wasm: modules/text/html/html-page-wrap.wasm
modules-zig-wasm: recipes/text/markdown/10-markdown-basic.wasm
modules-zig-wasm: recipes/text/markdown/80-html-page-wrap.wasm

recipes: $(patsubst recipes/text/markdown/%.zig,recipes/text/markdown/%.wasm,$(wildcard recipes/text/markdown/*.zig))
recipes: $(patsubst recipes/application/warc/%.zig,recipes/application/warc/%.wasm,$(wildcard recipes/application/warc/*.zig))
recipes: recipes/application/warc/10-add-open-graph-image-meta.wasm
recipes: recipes/text/markdown/29-add-highlight-stylesheet-night-owl.wasm

modules: modules-wat-wasm modules-c-wasm modules-zig-wasm

test: qip modules test-go test-node test-zig test-snapshot test-comply

test-node: qip modules
	node --check site/qip-runner.js
	node test/qip-runner-smoke.mjs
	node --test test/qip-play-debug-stats.mjs
	node --test test/html-id-validator.mjs
	node --test test/luhn.mjs
	node --test test/qip-wasm-safety-check.mjs
	node --test test/trace-with.mjs
	node --test test/qip-wasm-policy.mjs
	node --test test/sqlite-modules.mjs
	node --test test/bmp-png.mjs
	node --test test/wasm-trap-instance-continues.mjs

fuzz-zlib: modules/bytes/zlib-compress.wasm modules/bytes/zlib-compress-fixed-huffman.wasm modules/bytes/zlib-compress-dynamic-huffman.wasm modules/bytes/zlib-compress-dynamic-huffman-opt.wasm modules/bytes/zlib-decompress.wasm
	node tools/fuzz-zlib.mjs 20000

test-deno: qip modules
	deno check site/qip-runner.js
	deno run --allow-read test/qip-runner-smoke.mjs
	deno test --allow-read --allow-write --allow-run --allow-sys --allow-env test/qip-play-debug-stats.mjs test/html-id-validator.mjs test/luhn.mjs test/trace-with.mjs test/wasm-trap-instance-continues.mjs

test-comply: qip modules compliance
	$(QIP_BIN) comply modules/utf8/luhn.wasm --with compliance/luhn.comply.wasm

test-snapshot: qip modules
	@mkdir -p test
	@rm -f test/latest.txt
	@printf "%s\n" "module: base64-encode.wasm" >> test/latest.txt
	@printf %s "hello" | $(QIP_BIN) run modules/bytes/base64-encode.wasm >> test/latest.txt
	@printf "%s\n" "module: base64-encode.wasm | base64-decode.wasm" >> test/latest.txt
	@printf %s "hello" | $(QIP_BIN) run modules/bytes/base64-encode.wasm modules/utf8/base64-decode.wasm >> test/latest.txt
	@printf "\n" >> test/latest.txt
	@printf "%s\n" "module: bmp-to-ico.wasm | base64-encode.wasm" >> test/latest.txt
	@printf %s "424D3A0000000000000036000000280000000100000001000000010018000000000004000000000000000000000000000000000000000000FF00" | xxd -r -p | $(QIP_BIN) run modules/image/bmp/bmp-to-ico.wasm modules/bytes/base64-encode.wasm >> test/latest.txt
	@printf "\n" >> test/latest.txt
	@printf "%s\n" "module: crc32-hex.wasm" >> test/latest.txt
	@printf %s "abc" | $(QIP_BIN) run modules/bytes/crc32-hex.wasm >> test/latest.txt
	@printf "%s\n" "module: css-class-validator.wasm" >> test/latest.txt
	@printf %s "btn-primary" | $(QIP_BIN) run modules/text/css/css-class-validator.wasm >> test/latest.txt
	@printf "%s\n" "module: e164.wasm" >> test/latest.txt
	@printf %s "+14155552671" | $(QIP_BIN) run modules/utf8/e164.wasm >> test/latest.txt
	@printf "%s\n" "module: zlib-compress.wasm | base64-encode.wasm" >> test/latest.txt
	@printf %s "qip + wasm" | $(QIP_BIN) run modules/bytes/zlib-compress.wasm modules/bytes/base64-encode.wasm >> test/latest.txt
	@printf "%s\n" "module: zlib-compress.wasm | zlib-decompress.wasm" >> test/latest.txt
	@printf %s "qip + wasm" | $(QIP_BIN) run modules/bytes/zlib-compress.wasm modules/bytes/zlib-decompress.wasm >> test/latest.txt
	@printf "\n" >> test/latest.txt
	@printf "%s\n" "module: zlib-compress-fixed-huffman.wasm | base64-encode.wasm" >> test/latest.txt
	@printf %s "qip + wasm" | $(QIP_BIN) run modules/bytes/zlib-compress-fixed-huffman.wasm modules/bytes/base64-encode.wasm >> test/latest.txt
	@printf "%s\n" "module: zlib-compress-fixed-huffman.wasm | zlib-decompress.wasm" >> test/latest.txt
	@printf %s "qip + wasm" | $(QIP_BIN) run modules/bytes/zlib-compress-fixed-huffman.wasm modules/bytes/zlib-decompress.wasm >> test/latest.txt
	@printf "\n" >> test/latest.txt
	@printf "%s\n" "module: zlib-compress-dynamic-huffman.wasm | base64-encode.wasm" >> test/latest.txt
	@printf %s "qip + wasm" | $(QIP_BIN) run modules/bytes/zlib-compress-dynamic-huffman.wasm modules/bytes/base64-encode.wasm >> test/latest.txt
	@printf "%s\n" "module: zlib-compress-dynamic-huffman.wasm | zlib-decompress.wasm" >> test/latest.txt
	@printf %s "qip + wasm" | $(QIP_BIN) run modules/bytes/zlib-compress-dynamic-huffman.wasm modules/bytes/zlib-decompress.wasm >> test/latest.txt
	@printf "\n" >> test/latest.txt
	@printf "%s\n" "module: hello.wasm" >> test/latest.txt
	@printf %s "World" | $(QIP_BIN) run modules/utf8/hello.wasm >> test/latest.txt
	@printf "%s\n" "module: hello-c.wasm" >> test/latest.txt
	@printf %s "World" | $(QIP_BIN) run modules/utf8/hello-c.wasm >> test/latest.txt
	@printf "%s\n" "module: hello-zig.wasm" >> test/latest.txt
	@printf %s "World" | $(QIP_BIN) run modules/utf8/hello-zig.wasm >> test/latest.txt
	@printf "%s\n" "module: hex-to-rgb.wasm" >> test/latest.txt
	@printf %s "#ff8800" | $(QIP_BIN) run modules/utf8/hex-to-rgb.wasm >> test/latest.txt
	@printf "%s\n" "module: html-id-validator.wasm" >> test/latest.txt
	@printf %s "main-content" | $(QIP_BIN) run modules/text/html/html-id-validator.wasm >> test/latest.txt
	@printf "%s\n" "module: html-input-name-validator.wasm" >> test/latest.txt
	@printf %s "email" | $(QIP_BIN) run modules/text/html/html-input-name-validator.wasm >> test/latest.txt
	@printf "%s\n" "module: html-aria-extractor.wasm" >> test/latest.txt
	@printf %s "<a href=\"/a\">Go</a><button>Push</button><h2>Title</h2><input type=\"radio\" aria-label=\"Yes\"><div role=\"checkbox\" aria-label=\"Ok\"></div>" | $(QIP_BIN) run modules/text/html/html-aria-extractor.wasm >> test/latest.txt
	@printf "%s\n" "module: html-escape.wasm" >> test/latest.txt
	@printf "%s" "<textarea>Tom & \"QIP\"</textarea><input value='raw'>" | $(QIP_BIN) run modules/text/html/html-escape.wasm >> test/latest.txt
	@printf "%s\n" "module: html-wcag-contrast-aa.wasm" >> test/latest.txt
	@printf "%s" "<style>.ok{color:#111;background:#fff}</style><p class=ok>Readable</p>" | $(QIP_BIN) run modules/text/html/html-wcag-contrast-aa.wasm >> test/latest.txt
	@printf "%s\n" "module: html-tag-validator.wasm" >> test/latest.txt
	@printf %s "div" | $(QIP_BIN) run modules/text/html/html-tag-validator.wasm >> test/latest.txt
	@printf "%s\n" "module: luhn.wasm" >> test/latest.txt
	@printf %s "49927398716" | $(QIP_BIN) run modules/utf8/luhn.wasm >> test/latest.txt
	@printf "%s\n" "module: markdown-basic.wasm" >> test/latest.txt
	@printf "%b" "# Title\nHello **World**\n" | $(QIP_BIN) run modules/text/markdown/markdown-basic.wasm >> test/latest.txt
	@printf "%s\n" "module: markdown-basic.wasm (table)" >> test/latest.txt
	@printf "%b" '| A | B |\n| --- | --- |\n| `x` | **y** |\n' | $(QIP_BIN) run modules/text/markdown/markdown-basic.wasm >> test/latest.txt
	@printf "%s\n" "module: markdown-basic.wasm | html-page-wrap.wasm" >> test/latest.txt
	@printf "%b" "# Title\nHello **World**\n" | $(QIP_BIN) run modules/text/markdown/markdown-basic.wasm modules/text/html/html-page-wrap.wasm | perl -0pe 's#(<style\b[^>]*>).*?(</style>)#$$1$$2#gis' >> test/latest.txt
	@printf "%s\n" "module: rgb-to-hex.wasm" >> test/latest.txt
	@printf %s "255,0,170" | $(QIP_BIN) run modules/utf8/rgb-to-hex.wasm >> test/latest.txt
	@printf "%s\n" "module: rgb-to-hex.wasm (rgb())" >> test/latest.txt
	@printf %s " rgb( 101, 79, 240 ) " | $(QIP_BIN) run modules/utf8/rgb-to-hex.wasm >> test/latest.txt
	@printf "%s\n" "module: tld-validator.wasm" >> test/latest.txt
	@printf %s "com" | $(QIP_BIN) run modules/utf8/tld-validator.wasm >> test/latest.txt
	@printf "%s\n" "module: youtube-id-extractor.wasm" >> test/latest.txt
	@printf %s "https://youtu.be/dQw4w9WgXcQ https://www.youtube.com/embed/9bZkp7q19f0 https://www.youtube.com/watch?v=3JZ_D3ELwOQ" | $(QIP_BIN) run modules/utf8/youtube-id-extractor.wasm >> test/latest.txt
	@printf "%s\n" "module: trim.wasm" >> test/latest.txt
	@printf %s "  hi  " | $(QIP_BIN) run modules/utf8/trim.wasm >> test/latest.txt
	@printf "%s\n" "module: utf8-must-be-valid.wasm" >> test/latest.txt
	@printf %s "hello" | $(QIP_BIN) run modules/utf8/utf8-must-be-valid.wasm >> test/latest.txt
	@printf "%s\n" "module: wasm-to-js.wasm" >> test/latest.txt
	@cat modules/utf8/hello.wasm | $(QIP_BIN) run modules/application/wasm/wasm-to-js.wasm >> test/latest.txt
	diff test/expected.txt test/latest.txt && echo "Snapshots pass."

ZIG_TEST_FILES := $(MODULE_ZIG_FILES) $(wildcard recipes/text/markdown/*.zig)

test-zig: $(ZIG_TEST_FILES)
	@for f in $^; do \
		echo "zig test $$f"; \
		$(ZIG_ENV) zig test $$f; \
	done

test-go:
	go test $(GO_TEST_PKGS)

site/favicon.ico: qip-logo.svg
	$(QIP_BIN) run -i qip-logo.svg -- modules/image/svg+xml/svg-rasterize.wasm modules/image/bmp/bmp-double.wasm modules/image/bmp/bmp-double.wasm modules/image/bmp/bmp-to-ico.wasm > $@

OG_MD_SOURCES := $(shell find site docs -type f -name '*.md' | sort)
OG_IMAGE_MODULES := modules/text/markdown/extract-title-text.wasm modules/utf8/text-to-path-svg-dejavu-sans-mono-bold.wasm modules/image/svg+xml/svg-rasterize.wasm

OG_PNG_TARGETS := $(sort $(patsubst site/_og/%/index.png,site/_og/%.png,$(patsubst docs/%.md,site/_og/docs/%.png,$(patsubst site/%.md,site/_og/%.png,$(OG_MD_SOURCES)))))

site/_og: $(OG_PNG_TARGETS)

define OG_RENDER_PNG_RECIPE
	@mkdir -p $(dir $@)
	$(QIP_BIN) run -i "$<" -o "$@" -- modules/text/markdown/extract-title-text.wasm modules/utf8/text-to-path-svg-dejavu-sans-mono-bold.wasm '?width=1200&height=630&font_size=72' modules/image/svg+xml/svg-rasterize.wasm '?background_color_rgba=0xeecc33ff'
endef

site/_og/%.png: site/%.md $(OG_IMAGE_MODULES)
	$(OG_RENDER_PNG_RECIPE)

site/_og/%.png: site/%/index.md $(OG_IMAGE_MODULES)
	$(OG_RENDER_PNG_RECIPE)

site/_og/docs/%.png: docs/%.md $(OG_IMAGE_MODULES)
	$(OG_RENDER_PNG_RECIPE)

site/_og/docs/%.png: docs/%/index.md $(OG_IMAGE_MODULES)
	$(OG_RENDER_PNG_RECIPE)

site/_og/docs.png: docs/index.md $(OG_IMAGE_MODULES)
	$(OG_RENDER_PNG_RECIPE)

install:
	go install github.com/royalicing/qip@latest

score: qip
	@files="$$(find modules -type f -name '*.wasm' | LC_ALL=C sort)"; \
	if [ -z "$$files" ]; then \
		echo "No .wasm files found under modules/"; \
		exit 1; \
	fi; \
	$(QIP_BIN) score $$files

wasm-safety-report: qip modules
	@pass=0; \
	fail=0; \
	files="$$(find modules -type f -name '*.wasm' | LC_ALL=C sort)"; \
	if [ -z "$$files" ]; then \
		echo "No .wasm files found under modules/"; \
		exit 1; \
	fi; \
	for f in $$files; do \
		if $(QIP_BIN) run -i "$$f" -- modules/application/wasm/wasm-safety-check.wasm >/dev/null 2>&1; then \
			printf "PASS %s\n" "$$f"; \
			pass=$$((pass + 1)); \
		else \
			printf "FAIL %s\n" "$$f"; \
			fail=$$((fail + 1)); \
		fi; \
	done; \
	total=$$((pass + fail)); \
	printf "\npass=%d fail=%d total=%d\n" "$$pass" "$$fail" "$$total"

site-static: qip
	$(QIP_BIN) router warc ./site --view-source | $(QIP_BIN) run modules/application/warc/warc-check-broken-links.wasm modules/application/warc/warc-to-static-tar-no-trailing-slash.wasm > site-static.tar && mkdir -p site-static && tar -xvf site-static.tar -C site-static

site-static-with-og: site/_og recipes/application/warc/10-add-open-graph-image-meta.wasm site-static

site-checks:
	$(QIP_BIN) router get site / | $(QIP_BIN) run modules/text/html/html-wcag-contrast-aa.wasm

dev:
	$(QIP_BIN) dev ./site -p 4114 --view-source

defluff:
	find . -name '.DS_Store' -type f -delete
