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
QIP_GO_DEPS := $(filter-out %_test.go,$(wildcard *.go)) $(wildcard cmd/*.go) $(wildcard internal/*.go) $(wildcard internal/*/*.go)

qip: go.mod go.sum $(QIP_GO_DEPS)
	go fix $(GO_FIX_PKGS)
	go fmt $(GO_FMT_PKGS)
	go build -ldflags="-s -w" -trimpath

compliance/%.wasm: compliance/%.wat
	wat2wasm $< -o $@

compliance/unicode-17-lowercase.comply.wasm: compliance/unicode-17-lowercase.comply.zig compliance/unicode-17-lowercase-tables.zig compliance/unicode-17-lowercase-fixtures.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/unicode-17-uppercase.comply.wasm: compliance/unicode-17-uppercase.comply.zig compliance/unicode-17-uppercase-tables.zig compliance/unicode-17-uppercase-fixtures.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/currency-format-usd-en-us.comply.wasm: compliance/currency-format-usd-en-us.comply.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/currency-format-en-us.comply.wasm: compliance/currency-format-en-us.comply.zig compliance/currency-format-en-us-table.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/currency-format-en-in.comply.wasm: compliance/currency-format-en-in.comply.zig compliance/currency-format-en-in-table.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/currency-format-es-es.comply.wasm: compliance/currency-format-es-es.comply.zig compliance/currency-format-es-es-table.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/currency-format-de-de.comply.wasm: compliance/currency-format-de-de.comply.zig compliance/currency-format-de-de-table.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/currency-format-ar-eg.comply.wasm: compliance/currency-format-ar-eg.comply.zig compliance/currency-format-ar-eg-table.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/currency-format-fr-fr.comply.wasm: compliance/currency-format-fr-fr.comply.zig compliance/currency-format-fr-fr-table.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/currency-format-pt-br.comply.wasm: compliance/currency-format-pt-br.comply.zig compliance/currency-format-pt-br-table.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/currency-format-ja-jp.comply.wasm: compliance/currency-format-ja-jp.comply.zig compliance/currency-format-ja-jp-table.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/currency-format-zh-cn.comply.wasm: compliance/currency-format-zh-cn.comply.zig compliance/currency-format-zh-cn-table.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

modules/utf8/currency-format-en-us.wasm: ZIG_WASM_FLAGS += --stack 1024 --global-base=0
modules/utf8/currency-format-en-us.wasm: modules/utf8/lib/currency-format-en-us-table.zig
modules/utf8/currency-format-en-in.wasm: ZIG_WASM_FLAGS += --stack 1024 --global-base=0
modules/utf8/currency-format-en-in.wasm: modules/utf8/lib/currency-format-en-in-table.zig
modules/utf8/currency-format-es-es.wasm: ZIG_WASM_FLAGS += --stack 1024 --global-base=0
modules/utf8/currency-format-es-es.wasm: modules/utf8/lib/currency-format-es-es-table.zig
modules/utf8/currency-format-de-de.wasm: ZIG_WASM_FLAGS += --stack 1024 --global-base=0
modules/utf8/currency-format-de-de.wasm: modules/utf8/lib/currency-format-de-de-table.zig
modules/utf8/currency-format-ar-eg.wasm: ZIG_WASM_FLAGS += --stack 1024 --global-base=0
modules/utf8/currency-format-ar-eg.wasm: modules/utf8/lib/currency-format-ar-eg-table.zig
modules/utf8/currency-format-fr-fr.wasm: ZIG_WASM_FLAGS += --stack 1024 --global-base=0
modules/utf8/currency-format-fr-fr.wasm: modules/utf8/lib/currency-format-fr-fr-table.zig
modules/utf8/currency-format-pt-br.wasm: ZIG_WASM_FLAGS += --stack 1024 --global-base=0
modules/utf8/currency-format-pt-br.wasm: modules/utf8/lib/currency-format-pt-br-table.zig
modules/utf8/currency-format-ja-jp.wasm: ZIG_WASM_FLAGS += --stack 1024 --global-base=0
modules/utf8/currency-format-ja-jp.wasm: modules/utf8/lib/currency-format-ja-jp-table.zig
modules/utf8/currency-format-zh-cn.wasm: ZIG_WASM_FLAGS += --stack 1024 --global-base=0
modules/utf8/currency-format-zh-cn.wasm: modules/utf8/lib/currency-format-zh-cn-table.zig
modules/image/svg+xml/svg-to-data-uri.wasm: ZIG_WASM_FLAGS += --stack 1024 --global-base=0
modules/text/uri-list/data-uri-to-css-url.wasm: ZIG_WASM_FLAGS += --stack 1024 --global-base=0

modules/text/html/highlight-syntax-highlight-css.wasm: modules/text/html/lib/syntax-highlight-css.zig
modules/text/html/highlight-syntax-highlight-tsx.wasm: modules/text/html/lib/syntax-highlight-javascript.zig
modules/text/html/highlight-syntax-highlight-html.wasm: modules/text/html/lib/syntax-highlight-css.zig modules/text/html/lib/syntax-highlight-javascript.zig

compliance/iso-4217-alpha-to-numeric.comply.wasm: compliance/iso-4217-alpha-to-numeric.comply.zig compliance/iso-4217-alpha-numeric-table.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/svg-to-data-uri.comply.wasm: compliance/svg-to-data-uri.comply.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/data-uri-to-css-url.comply.wasm: compliance/data-uri-to-css-url.comply.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance/mermaid-to-unicode-html.comply.wasm: compliance/mermaid-to-unicode-html.comply.zig compliance/mermaid-to-unicode-html.fixtures.txt
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

SYNTAX_HIGHLIGHT_COMPLY_TARGETS := compliance/syntax-highlight-javascript.comply.wasm compliance/syntax-highlight-html.comply.wasm compliance/syntax-highlight-css.comply.wasm compliance/syntax-highlight-python.comply.wasm compliance/syntax-highlight-java.comply.wasm compliance/syntax-highlight-csharp.comply.wasm

compliance/syntax-highlight-%.comply.wasm: compliance/syntax-highlight-%.comply.zig compliance/syntax-highlight-%.fixtures.txt compliance/lib/syntax-highlight-comply.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

COMMONMARK_COMPLY_TARGETS := compliance/commonmark-spec-0.31.2.wasm compliance/commonmark-0.31.2-gfm.wasm

compliance/commonmark-spec-0.31.2.wasm: compliance/commonmark-spec-0.31.2.zig compliance/commonmark-spec-0.31.2.txt
compliance/commonmark-0.31.2-gfm.wasm: compliance/commonmark-0.31.2-gfm.zig compliance/gfm-commonmark-spec-0.31.2.txt compliance/gfm-extensions-0.29.txt compliance/gfm-spec-0.29.txt

$(COMMONMARK_COMPLY_TARGETS):
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

compliance: $(patsubst compliance/%.wat,compliance/%.wasm,$(wildcard compliance/*.wat))
compliance: compliance/unicode-17-lowercase.comply.wasm
compliance: compliance/unicode-17-uppercase.comply.wasm
compliance: compliance/currency-format-usd-en-us.comply.wasm
compliance: compliance/currency-format-en-us.comply.wasm
compliance: compliance/currency-format-en-in.comply.wasm
compliance: compliance/currency-format-es-es.comply.wasm
compliance: compliance/currency-format-de-de.comply.wasm
compliance: compliance/currency-format-ar-eg.comply.wasm
compliance: compliance/currency-format-fr-fr.comply.wasm
compliance: compliance/currency-format-pt-br.comply.wasm
compliance: compliance/currency-format-ja-jp.comply.wasm
compliance: compliance/currency-format-zh-cn.comply.wasm
compliance: compliance/iso-4217-alpha-to-numeric.comply.wasm
compliance: compliance/svg-to-data-uri.comply.wasm
compliance: compliance/data-uri-to-css-url.comply.wasm
compliance: compliance/mermaid-to-unicode-html.comply.wasm
compliance: $(SYNTAX_HIGHLIGHT_COMPLY_TARGETS)
compliance: $(COMMONMARK_COMPLY_TARGETS)

ZIG_CACHE_DIR ?= /tmp/zig-cache
ZIG_GLOBAL_CACHE_DIR ?= /tmp/zig-global-cache
ZIG_ENV := ZIG_CACHE_DIR=$(ZIG_CACHE_DIR) ZIG_GLOBAL_CACHE_DIR=$(ZIG_GLOBAL_CACHE_DIR)
ZIG_WASM_MAX_MEMORY ?= 67108864

HOST_OS ?= $(shell uname -s)
ifeq ($(HOST_OS),Darwin)
ZIG_TEST_SYSROOT ?= $(firstword $(wildcard /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX15.4.sdk))
ifneq ($(ZIG_TEST_SYSROOT),)
ZIG_TEST_FLAGS ?= --sysroot $(ZIG_TEST_SYSROOT)
endif
endif
ZIG_TEST_FLAGS ?=

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
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--export=render -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_bytes_cap -Wl,--export=output_ptr -Wl,--export=output_utf8_cap -Oz -o $@

modules/utf8/text-to-bmp.wasm: modules/utf8/text-to-bmp.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--export=render -Wl,--export=uniform_set_leading -Wl,--export=uniform_set_cols -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_ptr -Wl,--export=output_bytes_cap -Oz -o $@

modules/utf8/text-to-og-image-font8x8.wasm: modules/utf8/text-to-og-image-font8x8.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--export=render -Wl,--export=uniform_set_text_color -Wl,--export=uniform_set_background_color -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_ptr -Wl,--export=output_bytes_cap -Oz -o $@

modules/image/bmp/bmp-double.wasm: modules/image/bmp/bmp-double.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--export=render -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_bytes_cap -Wl,--export=output_ptr -Wl,--export=output_bytes_cap -Oz -o $@

modules/image/bmp/bmp-double-simd.wasm: modules/image/bmp/bmp-double-simd.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -mcpu=generic+simd128 -femit-bin=$@

modules/interactive/cover-flow.wasm: modules/interactive/cover-flow.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -mcpu=generic+simd128 -femit-bin=$@

modules/application/wasm/wasm-strict-profile.wasm: ZIG_WASM_MAX_MEMORY = 20971520
modules/application/wasm/wasm-strict-profile.wasm: modules/application/wasm/wasm-strict-profile.zig modules/application/wasm/lib/wasm-reader.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

modules/application/wasm/wasm-bounded-loops.wasm: ZIG_WASM_MAX_MEMORY = 25165824
modules/application/wasm/wasm-bounded-loops.wasm: modules/application/wasm/wasm-bounded-loops.zig modules/application/wasm/lib/wasm-reader.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

modules/application/wasm/wasm-score.wasm: ZIG_WASM_MAX_MEMORY = 14680064
modules/application/wasm/wasm-score.wasm: modules/application/wasm/wasm-score.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

modules/application/wasm/wasm-to-js.wasm: modules/application/wasm/wasm-to-js.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

modules/text/javascript/js-to-bmp.wasm: modules/text/javascript/js-to-bmp.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--export=render -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_ptr -Wl,--export=output_bytes_cap -Oz -o $@

modules/text/x-c/c-to-bmp.wasm: modules/text/x-c/c-to-bmp.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--export=render -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_ptr -Wl,--export=output_bytes_cap -Oz -o $@

recipes/text/markdown/80-html-page-wrap.wasm: recipes/text/markdown/styles.css recipes/text/markdown/header.html recipes/text/markdown/footer.html

modules/text/html/html-add-highlight-stylesheet-night-owl.wasm: modules/text/html/highlight-night-owl.css

recipes/text/markdown/29-add-highlight-stylesheet-night-owl.wasm: modules/text/html/html-add-highlight-stylesheet-night-owl.wasm
	cp $< $@

recipes/text/markdown/28-highlight-syntax-highlight-css.wasm: modules/text/html/highlight-syntax-highlight-css.wasm
	cp $< $@

recipes/text/markdown/23-highlight-syntax-highlight-tsx.wasm: modules/text/html/highlight-syntax-highlight-tsx.wasm
	cp $< $@

modules/text/markdown/markdown-basic.wasm: recipes/text/markdown/10-markdown-basic.wasm
	cp $< $@

modules/text/html/html-page-wrap.wasm: recipes/text/markdown/80-html-page-wrap.wasm
	cp $< $@

modules/application/warc/warc-check-broken-links.wasm: ZIG_WASM_MAX_MEMORY = 167772160
modules/application/warc/warc-extract-broken-links.wasm: ZIG_WASM_MAX_MEMORY = 335544320
modules/application/warc/warc-check-broken-module-imports.wasm: ZIG_WASM_MAX_MEMORY = 167772160
modules/application/warc/warc-to-static-tar-no-trailing-slash.wasm: ZIG_WASM_MAX_MEMORY = 335544320
modules/application/warc/warc-add-open-graph-image-meta.wasm: ZIG_WASM_MAX_MEMORY = 671088640
modules/application/warc/warc-add-custom-element-scripts.wasm: ZIG_WASM_MAX_MEMORY = 671088640
recipes/application/warc/15-add-html-data-path.wasm: ZIG_WASM_MAX_MEMORY = 671088640
recipes/application/warc/25-add-content-size.wasm: ZIG_WASM_MAX_MEMORY = 671088640
modules/image/gif/gifsicle-optimize.wasm: ZIG_WASM_MAX_MEMORY = 167772160
modules/image/bmp/bmp-to-png.wasm: ZIG_WASM_MAX_MEMORY = 134217728
modules/image/png/png-to-bmp.wasm: ZIG_WASM_MAX_MEMORY = 134217728

modules/utf8/unicode-17-lowercase.wasm: modules/utf8/lib/unicode-17-lowercase-tables.zig modules/utf8/lib/utf8.zig
modules/utf8/unicode-17-uppercase.wasm: modules/utf8/lib/unicode-17-uppercase-tables.zig modules/utf8/lib/utf8.zig
modules/utf8/iso-4217-alpha-to-numeric.wasm: modules/utf8/lib/iso-4217-alpha-numeric-table.zig

modules/bytes/zlib-compress-dynamic-huffman-opt.wasm: modules/bytes/lib/deflate.zig
modules/image/bmp/bmp-to-png.wasm: modules/image/bmp/lib/deflate.zig
modules/bytes/zlib-decompress.wasm: modules/bytes/lib/inflate.zig modules/bytes/lib/deflate.zig
modules/image/png/png-to-bmp.wasm: modules/image/png/lib/inflate.zig modules/image/png/lib/deflate.zig

modules/%.wasm: modules/%.c
	$(ZIG_ENV) zig cc $< -target wasm32-freestanding -nostdlib -Wl,--no-entry $(WASM_STACK_FLAG) -Wl,--max-memory=$(ZIG_WASM_MAX_MEMORY) -Wl,--export=render -Wl,--export-memory -Wl,--export=input_ptr -Wl,--export=input_utf8_cap -Wl,--export=output_ptr -Wl,--export=output_utf8_cap -Oz -o $@

modules/%.wasm: modules/%.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

recipes/%.wasm: recipes/%.zig
	$(ZIG_ENV) zig build-exe $< $(ZIG_WASM_FLAGS) --max-memory=$(ZIG_WASM_MAX_MEMORY) -femit-bin=$@

recipes/application/warc/10-add-open-graph-image-meta.wasm: modules/application/warc/warc-add-open-graph-image-meta.wasm
	@mkdir -p $(dir $@)
	ln -sf ../../../modules/application/warc/warc-add-open-graph-image-meta.wasm $@

recipes/application/warc/99-add-custom-element-scripts.wasm: modules/application/warc/warc-add-custom-element-scripts.wasm
	ln -sf ../../../modules/application/warc/warc-add-custom-element-scripts.wasm $@

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
recipes: recipes/application/warc/99-add-custom-element-scripts.wasm
recipes: recipes/text/markdown/23-highlight-syntax-highlight-tsx.wasm
recipes: recipes/text/markdown/24-highlight-syntax-highlight-html.wasm
recipes: recipes/text/markdown/28-highlight-syntax-highlight-css.wasm
recipes: recipes/text/markdown/29-add-highlight-stylesheet-night-owl.wasm

modules: modules-wat-wasm modules-c-wasm modules-zig-wasm

test: qip modules test-go test-node test-zig test-snapshot test-comply

test-node: qip modules recipes/application/warc/25-add-content-size.wasm
	node --check site/qip-runner.js
	node test/qip-runner-smoke.mjs
	node --test test/qip-play-debug-stats.mjs
	node --test test/qip-edit-stats.mjs
	node --test test/qip-form-element.mjs
	node --test test/sudoku-ui.mjs
	node --test test/html-id-validator.mjs
	node --test test/css-expression-to-value.mjs
	node --test test/html-adjacent.mjs
	node --test test/html-to-accessibility-tree.mjs
	node --test test/luhn.mjs
	node --test test/unicode-17-lowercase.mjs
	node --test test/unicode-17-uppercase-comply.mjs
	node --test test/unicode-17-lowercase-comply.mjs
	node --test test/currency-format-usd-en-us-comply.mjs
	node --test test/currency-format-en-us-comply.mjs
	node --test test/currency-format-en-in-comply.mjs
	node --test test/currency-format-es-es-comply.mjs
	node --test test/currency-format-de-de-comply.mjs
	node --test test/currency-format-ar-eg-comply.mjs
	node --test test/currency-format-fr-fr-comply.mjs
	node --test test/currency-format-pt-br-comply.mjs
	node --test test/currency-format-ja-jp-comply.mjs
	node --test test/currency-format-zh-cn-comply.mjs
	node --test test/iso-4217-alpha-to-numeric-comply.mjs
	node --test test/svg-data-uri-comply.mjs
	node --test test/mermaid-to-unicode-html.mjs
	node --test test/warc-content-size.mjs
	node --test test/qip-wasm-checks.mjs
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
	deno test --allow-read --allow-write --allow-run --allow-sys --allow-env test/qip-play-debug-stats.mjs test/qip-edit-stats.mjs test/sudoku-ui.mjs test/html-id-validator.mjs test/html-adjacent.mjs test/html-to-accessibility-tree.mjs test/luhn.mjs test/trace-with.mjs test/wasm-trap-instance-continues.mjs

test-comply: qip modules compliance
	$(QIP_BIN) comply modules/text/html/highlight-syntax-highlight-tsx.wasm --with compliance/syntax-highlight-javascript.comply.wasm --profile strict
	$(QIP_BIN) comply modules/text/html/highlight-syntax-highlight-html.wasm --with compliance/syntax-highlight-html.comply.wasm --profile strict
	$(QIP_BIN) comply modules/text/html/highlight-syntax-highlight-css.wasm --with compliance/syntax-highlight-css.comply.wasm --profile strict
	$(QIP_BIN) comply recipes/text/markdown/25-highlight-syntax-highlight-python.wasm --with compliance/syntax-highlight-python.comply.wasm --profile strict
	$(QIP_BIN) comply recipes/text/markdown/26-highlight-syntax-highlight-java.wasm --with compliance/syntax-highlight-java.comply.wasm --profile strict
	$(QIP_BIN) comply recipes/text/markdown/27-highlight-syntax-highlight-csharp.wasm --with compliance/syntax-highlight-csharp.comply.wasm --profile strict
	$(QIP_BIN) comply modules/text/vnd.mermaid/mermaid-to-unicode-html.wasm --with compliance/mermaid-to-unicode-html.comply.wasm --profile strict
	$(QIP_BIN) comply modules/text/markdown/commonmark.0.31.2.wasm --with compliance/commonmark-spec-0.31.2.wasm --profile strict
	$(QIP_BIN) comply modules/text/markdown/gfm-commonmark.0.31.2.wasm --with compliance/commonmark-0.31.2-gfm.wasm --profile strict
	$(QIP_BIN) comply modules/utf8/luhn.wasm --with compliance/luhn.comply.wasm --legacy
	$(QIP_BIN) comply modules/utf8/unicode-17-lowercase.wasm --with compliance/unicode-17-lowercase.comply.wasm
	$(QIP_BIN) comply modules/utf8/unicode-17-uppercase.wasm --with compliance/unicode-17-uppercase.comply.wasm
	$(QIP_BIN) comply modules/utf8/currency-format-usd-en-us.wasm --with compliance/currency-format-usd-en-us.comply.wasm
	$(QIP_BIN) comply modules/utf8/currency-format-en-us.wasm --with compliance/currency-format-en-us.comply.wasm
	$(QIP_BIN) comply modules/utf8/currency-format-en-in.wasm --with compliance/currency-format-en-in.comply.wasm
	$(QIP_BIN) comply modules/utf8/currency-format-es-es.wasm --with compliance/currency-format-es-es.comply.wasm
	$(QIP_BIN) comply modules/utf8/currency-format-de-de.wasm --with compliance/currency-format-de-de.comply.wasm
	$(QIP_BIN) comply modules/utf8/currency-format-ar-eg.wasm --with compliance/currency-format-ar-eg.comply.wasm
	$(QIP_BIN) comply modules/utf8/currency-format-fr-fr.wasm --with compliance/currency-format-fr-fr.comply.wasm
	$(QIP_BIN) comply modules/utf8/currency-format-pt-br.wasm --with compliance/currency-format-pt-br.comply.wasm
	$(QIP_BIN) comply modules/utf8/currency-format-ja-jp.wasm --with compliance/currency-format-ja-jp.comply.wasm
	$(QIP_BIN) comply modules/utf8/currency-format-zh-cn.wasm --with compliance/currency-format-zh-cn.comply.wasm
	$(QIP_BIN) comply modules/utf8/iso-4217-alpha-to-numeric.wasm --with compliance/iso-4217-alpha-to-numeric.comply.wasm
	$(QIP_BIN) comply modules/image/svg+xml/svg-to-data-uri.wasm --with compliance/svg-to-data-uri.comply.wasm
	$(QIP_BIN) comply modules/text/uri-list/data-uri-to-css-url.wasm --with compliance/data-uri-to-css-url.comply.wasm

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
	@status=0; \
	for f in $^; do \
		echo "zig test $$f"; \
		$(ZIG_ENV) zig test "$$f" $(ZIG_TEST_FLAGS) || status=1; \
	done; \
	exit $$status

test-go:
	go test $(GO_TEST_PKGS)

site/favicon.ico: qip-logo.svg
	$(QIP_BIN) run -i qip-logo.svg -- modules/image/svg+xml/svg-rasterize.wasm modules/image/bmp/bmp-double.wasm modules/image/bmp/bmp-double.wasm modules/image/bmp/bmp-to-ico.wasm > $@

OG_MD_SOURCES := $(shell find site docs -type f -name '*.md' | sort)
OG_IMAGE_MODULES := modules/text/markdown/extract-title-text.wasm modules/utf8/text-to-path-svg-dejavu-sans-mono-bold.wasm modules/image/svg+xml/svg-rasterize.wasm modules/image/bmp/bmp-to-png.wasm

OG_PNG_TARGETS := $(sort $(patsubst site/_og/%/index.png,site/_og/%.png,$(patsubst docs/%.md,site/_og/docs/%.png,$(patsubst site/%.md,site/_og/%.png,$(OG_MD_SOURCES)))))

site/_og: $(OG_PNG_TARGETS)

define OG_RENDER_PNG_RECIPE
	@mkdir -p $(dir $@)
	$(QIP_BIN) run -i "$<" -o "$@" -- modules/text/markdown/extract-title-text.wasm modules/utf8/text-to-path-svg-dejavu-sans-mono-bold.wasm '?width=1200&height=630&font_size=72' modules/image/svg+xml/svg-rasterize.wasm '?background_color_rgba=0xeecc33ff' modules/image/bmp/bmp-to-png.wasm
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
		if $(QIP_BIN) run -i "$$f" -- modules/application/wasm/wasm-strict-profile.wasm modules/application/wasm/wasm-bounded-loops.wasm >/dev/null 2>&1; then \
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
	$(QIP_BIN) router warc ./site --view-source | $(QIP_BIN) run modules/application/warc/warc-check-broken-links.wasm modules/application/warc/warc-check-broken-module-imports.wasm modules/application/warc/warc-to-static-tar-no-trailing-slash.wasm > site-static.tar && mkdir -p site-static && tar -xvf site-static.tar -C site-static

site-static-with-og: site/_og recipes/application/warc/10-add-open-graph-image-meta.wasm site-static

site-checks:
	$(QIP_BIN) router get site / | $(QIP_BIN) run modules/text/html/html-wcag-contrast-aa.wasm

dev:
	$(QIP_BIN) dev ./site -p 4114 --view-source

defluff:
	find . -name '.DS_Store' -type f -delete
