package main

import (
	"context"
	"fmt"
	"sort"
	"strconv"

	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero/api"
)

func parseUniformInt(value string, bitSize int) (int64, error) {
	base := 10
	raw := value

	if len(value) >= 2 && value[0] == '0' && (value[1] == 'x' || value[1] == 'X') {
		base = 16
		raw = value[2:]
	} else if len(value) >= 3 && (value[0] == '+' || value[0] == '-') && value[1] == '0' && (value[2] == 'x' || value[2] == 'X') {
		base = 16
		raw = value[:1] + value[3:]
	}

	return strconv.ParseInt(raw, base, bitSize)
}

func parseUniformHexUint(value string, bitSize int) (uint64, bool, error) {
	if len(value) < 2 || value[0] != '0' || (value[1] != 'x' && value[1] != 'X') {
		return 0, false, nil
	}

	parsed, err := strconv.ParseUint(value[2:], 16, bitSize)
	if err != nil {
		return 0, true, err
	}
	return parsed, true, nil
}

func applyModuleUniforms(ctx context.Context, mod api.Module, uniforms map[string]string) error {
	if len(uniforms) == 0 {
		return nil
	}
	defs := mod.ExportedFunctionDefinitions()
	keys := make([]string, 0, len(uniforms))
	for key := range uniforms {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	for _, key := range keys {
		fnName := "uniform_set_" + key
		fn := mod.ExportedFunction(fnName)
		if fn == nil {
			return fmt.Errorf("Wasm module does not export %s for query key %q", fnName, key)
		}
		def, ok := defs[fnName]
		if !ok {
			return fmt.Errorf("Wasm module is missing function definition for %s", fnName)
		}
		paramTypes := def.ParamTypes()
		if len(paramTypes) != 1 {
			return fmt.Errorf("%s must accept exactly one argument", fnName)
		}
		value := uniforms[key]

		var args [1]uint64
		switch paramTypes[0] {
		case api.ValueTypeF32:
			parsed, err := strconv.ParseFloat(value, 32)
			if err != nil {
				return fmt.Errorf("invalid value %q for %s (expected f32)", value, fnName)
			}
			args[0] = api.EncodeF32(float32(parsed))
		case api.ValueTypeF64:
			parsed, err := strconv.ParseFloat(value, 64)
			if err != nil {
				return fmt.Errorf("invalid value %q for %s (expected f64)", value, fnName)
			}
			args[0] = api.EncodeF64(parsed)
		case api.ValueTypeI32:
			parsedHex, isHex, err := parseUniformHexUint(value, 32)
			if isHex {
				if err != nil {
					return fmt.Errorf("invalid value %q for %s (expected i32)", value, fnName)
				}
				args[0] = uint64(uint32(parsedHex))
				break
			}
			parsed, err := parseUniformInt(value, 32)
			if err != nil {
				return fmt.Errorf("invalid value %q for %s (expected i32)", value, fnName)
			}
			args[0] = uint64(uint32(int32(parsed)))
		case api.ValueTypeI64:
			parsedHex, isHex, err := parseUniformHexUint(value, 64)
			if isHex {
				if err != nil {
					return fmt.Errorf("invalid value %q for %s (expected i64)", value, fnName)
				}
				args[0] = parsedHex
				break
			}
			parsed, err := parseUniformInt(value, 64)
			if err != nil {
				return fmt.Errorf("invalid value %q for %s (expected i64)", value, fnName)
			}
			args[0] = uint64(parsed)
		default:
			return fmt.Errorf("%s has unsupported parameter type", fnName)
		}

		if _, err := fn.Call(ctx, args[0]); err != nil {
			return fmt.Errorf("Error running %s(%s): %w", fnName, value, wasmruntime.HumanizeExecutionError(ctx, err))
		}
	}
	return nil
}
