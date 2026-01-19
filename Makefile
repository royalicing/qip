qip: main.go go.mod go.sum
	go fmt main.go
	go build -ldflags="-s -w" -trimpath

examples/%.wasm: examples/%.wat
	wat2wasm $< -o $@

examples-wasm: $(patsubst examples/%.wat,examples/%.wasm,$(wildcard examples/*.wat))
