.PHONY: build verify bench memory clean

INPUT ?= ../../README.md
QIP ?= ../../qip
CC ?= cc
CFLAGS ?= -O3 -std=c11
ZIG_CACHE_DIR ?= /tmp/zig-cache
ZIG_GLOBAL_CACHE_DIR ?= /tmp/zig-global-cache
ZIG_ENV := ZIG_CACHE_DIR=$(ZIG_CACHE_DIR) ZIG_GLOBAL_CACHE_DIR=$(ZIG_GLOBAL_CACHE_DIR)

build: \
	wordcount_simple.zig.bin \
	wordcount_optimized.zig.bin \
	wordcount_simple.c.bin \
	wordcount_optimized.c.bin \
	wordcount_simple.go.bin \
	wordcount_optimized.go.bin \
	wordcount_zig_wasm.wasm \
	wordcount_c_wasm.wasm

wordcount_simple.zig.bin: wordcount_simple.zig wordcount_core.zig
	$(ZIG_ENV) zig build-exe wordcount_simple.zig -O ReleaseFast -femit-bin=$@

wordcount_optimized.zig.bin: wordcount_optimized.zig wordcount_core.zig
	$(ZIG_ENV) zig build-exe wordcount_optimized.zig -O ReleaseFast -femit-bin=$@

wordcount_simple.c.bin: wordcount_simple.c
	$(CC) $(CFLAGS) wordcount_simple.c -o $@

wordcount_optimized.c.bin: wordcount_optimized.c
	$(CC) $(CFLAGS) wordcount_optimized.c -o $@

wordcount_zig_wasm.wasm: wordcount_zig_wasm.zig wordcount_core.zig
	$(ZIG_ENV) zig build-exe wordcount_zig_wasm.zig -target wasm32-freestanding -O ReleaseSmall -fno-entry -rdynamic -femit-bin=$@

wordcount_c_wasm.wasm: wordcount_c_wasm.c
	$(ZIG_ENV) zig cc wordcount_c_wasm.c -target wasm32-freestanding -nostdlib -Wl,--no-entry -Wl,--export=render -Wl,--export=input_ptr -Wl,--export=input_bytes_cap -Wl,--export=output_bytes_cap -Oz -o $@

wordcount_simple.go.bin: wordcount_simple.go
	go build -o $@ wordcount_simple.go

wordcount_optimized.go.bin: wordcount_optimized.go
	go build -o $@ wordcount_optimized.go

verify: build
	INPUT="$(INPUT)" QIP="$(QIP)" ./verify.sh

bench: build
	INPUT="$(INPUT)" QIP="$(QIP)" ./bench.sh

memory: build
	INPUT="$(INPUT)" QIP="$(QIP)" ./memory.sh

clean:
	rm -f *.bin *.wasm out.*
