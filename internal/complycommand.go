package qinternal

import (
	"context"
	"crypto/sha256"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/royalicing/qip/internal/wasminspect"
	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

const usageComply = "Usage: qip comply [options] <file-or-dir> [...]\n\nOptions:\n  --with <compliance.wasm>        Run a Compliance oracle (repeatable)\n  --seed <n>                      Call uniform_set_seed(u32) on each oracle\n  --max-memory <bytes>            Reject implementation memory above bytes\n  --straight-line-oracles         Require each --with oracle to use straight-line oracle calls\n  -v, --verbose                   Print detailed validation logs"

var ErrComplyFailed = errors.New("compliance failed")

const (
	implModuleName              = "impl"
	complyExportMemory          = "memory"
	complyExportRun             = "render"
	complyExportInputPtr        = "input_ptr"
	complyExportInputUTF8Cap    = "input_utf8_cap"
	complyExportInputBytesCap   = "input_bytes_cap"
	complyExportTileRGBA32Float = "tile_rgba32float_64x64"
	maxFailurePreviewBytes      = 256
)

type stringListFlag []string

func (s *stringListFlag) String() string {
	return strings.Join(*s, ",")
}

func (s *stringListFlag) Set(v string) error {
	if strings.TrimSpace(v) == "" {
		return errors.New("--with path must not be empty")
	}
	*s = append(*s, v)
	return nil
}

type moduleKind string

const (
	moduleKindRun        moduleKind = "render"
	moduleKindTile       moduleKind = "tile"
	moduleKindRunAndTile moduleKind = "render+tile"
)

type baseValidationResult struct {
	kind moduleKind
}

type complianceSpec struct {
	index int
	path  string
	wasm  []byte
}

type complianceOutcomes struct {
	index    int
	path     string
	passed   bool
	cases    uint64 // declared cases run; 0 when the contract has no case count (legacy)
	err      error
	detail   string
	duration time.Duration
}

func RunComplyCommand(args []string) error {
	fs := flag.NewFlagSet("comply", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var withCompliances stringListFlag
	var verbose bool
	var straightLineOracles bool
	var seed uint32
	var seedSet bool
	var maxMemory uint64
	fs.Var(&withCompliances, "with", "Compliance oracle (repeatable)")
	fs.BoolVar(&verbose, "v", false, "enable verbose logging")
	fs.BoolVar(&verbose, "verbose", false, "enable verbose logging")
	fs.BoolVar(&straightLineOracles, "straight-line-oracles", false, "require each --with oracle to use straight-line oracle calls")
	fs.Func("seed", "call uniform_set_seed(u32) on each oracle", func(v string) error {
		n, err := strconv.ParseUint(v, 10, 32)
		if err != nil {
			return fmt.Errorf("invalid --seed: %q", v)
		}
		seed = uint32(n)
		seedSet = true
		return nil
	})
	fs.Func("max-memory", "reject implementation memory above bytes", func(v string) error {
		n, err := strconv.ParseUint(v, 10, 64)
		if err != nil || n == 0 {
			return fmt.Errorf("invalid --max-memory: %q", v)
		}
		maxMemory = n
		return nil
	})
	if err := fs.Parse(normalizeComplyArgs(args)); err != nil {
		return fmt.Errorf("%s %w", usageComply, err)
	}
	paths := fs.Args()
	if len(paths) == 0 {
		return errors.New(usageComply)
	}

	implPaths, err := discoverComplyWasmFiles(paths)
	if err != nil {
		return err
	}
	if len(implPaths) == 0 {
		return errors.New("No .wasm files found")
	}

	compliances := make([]complianceSpec, 0, len(withCompliances))
	slices.Sort(withCompliances)
	for i, path := range withCompliances {
		body, err := readComplyModulePath(path)
		if err != nil {
			return fmt.Errorf("failed to read --with %q: %w", path, err)
		}
		if straightLineOracles {
			if err := wasminspect.ValidateStraightLineComplyOracle(body); err != nil {
				return fmt.Errorf("Compliance oracle %q: %w", path, err)
			}
			if verbose {
				fmt.Fprintf(os.Stderr, "comply: straight-line oracle PASS --with %s\n", path)
			}
		}
		if verbose {
			sum := sha256.Sum256(body)
			fmt.Fprintf(os.Stderr, "compliance[%d] %s sha256: %x\n", i+1, path, sum)
		}
		compliances = append(compliances, complianceSpec{index: i, path: path, wasm: body})
	}

	var seedPtr *int32
	if seedSet {
		s := int32(seed)
		seedPtr = &s
	}
	pass, fail := 0, 0
	for _, implPath := range implPaths {
		implPass, implFail := runComplyForImplementation(implPath, compliances, seedPtr, maxMemory, verbose)
		pass += implPass
		fail += implFail
	}
	fmt.Printf("\npass=%d fail=%d total=%d\n", pass, fail, pass+fail)
	if fail > 0 {
		return ErrComplyFailed
	}
	return nil
}

func discoverComplyWasmFiles(paths []string) ([]string, error) {
	files := make([]string, 0)
	seen := map[string]bool{}
	for _, path := range paths {
		if strings.HasPrefix(path, "https://") {
			if seen[path] {
				continue
			}
			seen[path] = true
			files = append(files, path)
			continue
		}
		info, err := os.Stat(path)
		if err != nil {
			return nil, err
		}
		if !info.IsDir() {
			if !strings.HasSuffix(path, ".wasm") {
				return nil, fmt.Errorf("%s is not a .wasm file", path)
			}
			if !seen[path] {
				seen[path] = true
				files = append(files, path)
			}
			continue
		}
		err = filepath.WalkDir(path, func(child string, entry os.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".wasm") {
				return nil
			}
			if !seen[child] {
				seen[child] = true
				files = append(files, child)
			}
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	sort.Strings(files)
	return files, nil
}

func runComplyForImplementation(implPath string, compliances []complianceSpec, seed *int32, maxMemory uint64, verbose bool) (pass int, fail int) {
	implWasm, err := readComplyModulePath(implPath)
	if err != nil {
		fmt.Printf("FAIL %s: %v\n", implPath, err)
		return 0, 1
	}
	if verbose {
		sum := sha256.Sum256(implWasm)
		fmt.Fprintf(os.Stderr, "impl %s sha256: %x\n", implPath, sum)
	}
	if maxMemory > 0 {
		if err := wasminspect.ValidateModulePolicy(implWasm, wasminspect.ModulePolicy{MaxMemoryBytes: maxMemory}); err != nil {
			fmt.Printf("FAIL %s: %v\n", implPath, err)
			return 0, 1
		}
	}
	base, err := validateBaseContract(implPath, implWasm)
	if err != nil {
		fmt.Fprintf(os.Stderr, "comply: %s: %v\n", implPath, err)
		fmt.Printf("FAIL %s: %v\n", implPath, err)
		return 0, 1
	}
	if verbose {
		fmt.Fprintf(os.Stderr, "comply: module fulfills %s contract\n", base.kind)
	}
	analysis, err := wasminspect.AnalyzeModule(implWasm)
	if err != nil {
		fmt.Printf("FAIL %s: comply: static analysis failed: %v\n", implPath, err)
		return 0, 1
	}
	contractChecks, contractFail := wasminspect.EvaluateQIPContractChecks(analysis)
	if verbose {
		if len(contractChecks) == 0 {
			fmt.Fprintln(os.Stderr, "comply: static contract checks skipped (no qip contract exports found)")
		} else {
			status := "PASS"
			if contractFail {
				status = "FAIL"
			}
			fmt.Fprintf(os.Stderr, "comply: static contract checks %s (%d checked)\n", status, len(contractChecks))
			for _, check := range contractChecks {
				if check.Pass {
					fmt.Fprintf(os.Stderr, "  - %s (%s): PASS\n", check.Export, check.Kind)
					continue
				}
				fmt.Fprintf(os.Stderr, "  - %s (%s): FAIL (%s)\n", check.Export, check.Kind, check.Reason)
			}
		}
	}
	if contractFail {
		for _, check := range contractChecks {
			if check.Pass {
				continue
			}
			fmt.Fprintf(os.Stderr, "comply: %s: %s (%s): %s\n", implPath, check.Export, check.Kind, check.Reason)
		}
		fmt.Printf("FAIL %s: comply: static qip contract checks failed\n", implPath)
		return 0, 1
	}
	fmt.Printf("PASS %s\n", implPath)
	pass++

	for _, compliance := range compliances {
		out := runComplianceModule(implWasm, compliance, seed)
		if out.passed {
			fmt.Printf("PASS %s --with %s (%d cases)\n", implPath, out.path, out.cases)
			pass++
			continue
		}
		fmt.Printf("FAIL %s --with %s: %v\n", implPath, out.path, out.err)
		if verbose && out.detail != "" {
			fmt.Fprintf(os.Stderr, "%s\n", out.detail)
		}
		fail++
	}
	return pass, fail
}

func normalizeComplyArgs(args []string) []string {
	flagsWithValue := map[string]struct{}{
		"--with":       {},
		"--seed":       {},
		"--max-memory": {},
	}
	return NormalizeFlagArgs(args, flagsWithValue)
}

func readComplyModulePath(path string) ([]byte, error) {
	if strings.HasPrefix(path, "https://") {
		resp, err := http.Get(path)
		if err != nil {
			return nil, fmt.Errorf("Error fetching URL: %v", err)
		}
		defer resp.Body.Close()
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			return nil, fmt.Errorf("Error reading response: %v", err)
		}
		return body, nil
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("Error reading file: %v", err)
	}
	return body, nil
}

func validateBaseContract(label string, implWasm []byte) (baseValidationResult, error) {
	ctx := context.Background()
	r := wasmruntime.NewRunToCompletion(ctx)
	defer r.Close(ctx)

	compiled, err := r.CompileModule(ctx, implWasm)
	if err != nil {
		return baseValidationResult{}, errors.New("Wasm module could not be compiled")
	}
	defer compiled.Close(ctx)

	mod, err := r.InstantiateModule(ctx, compiled, wazero.NewModuleConfig().WithName(implModuleName))
	if err != nil {
		return baseValidationResult{}, errors.New("Wasm module could not be instantiated")
	}
	defer mod.Close(ctx)

	if mod.ExportedMemory(complyExportMemory) == nil {
		return baseValidationResult{}, fmt.Errorf("%s does not export memory", label)
	}

	funcs := compiled.ExportedFunctions()
	runDef, ok := funcs[complyExportRun]
	if !ok {
		return baseValidationResult{}, fmt.Errorf("%s must export render", label)
	}
	if err := requireSignature(runDef, []api.ValueType{api.ValueTypeI32}, []api.ValueType{api.ValueTypeI64}, complyExportRun); err != nil {
		return baseValidationResult{}, err
	}
	if _, ok, err := getExportedI32(ctx, mod, complyExportInputPtr); err != nil {
		return baseValidationResult{}, err
	} else if !ok {
		return baseValidationResult{}, fmt.Errorf("%s must export input_ptr", label)
	}
	hasInputUTF8 := false
	if _, ok, err := getExportedI32(ctx, mod, complyExportInputUTF8Cap); err != nil {
		return baseValidationResult{}, err
	} else if ok {
		hasInputUTF8 = true
	}
	hasInputBytes := false
	if _, ok, err := getExportedI32(ctx, mod, complyExportInputBytesCap); err != nil {
		return baseValidationResult{}, err
	} else if ok {
		hasInputBytes = true
	}
	if hasInputUTF8 == hasInputBytes {
		return baseValidationResult{}, fmt.Errorf("%s must export exactly one input capacity: input_utf8_cap or input_bytes_cap", label)
	}
	hasOutputUTF8 := false
	if _, ok, err := getExportedI32(ctx, mod, "output_utf8_cap"); err != nil {
		return baseValidationResult{}, err
	} else if ok {
		hasOutputUTF8 = true
	}
	hasOutputBytes := false
	if _, ok, err := getExportedI32(ctx, mod, "output_bytes_cap"); err != nil {
		return baseValidationResult{}, err
	} else if ok {
		hasOutputBytes = true
	}
	if hasOutputUTF8 == hasOutputBytes {
		return baseValidationResult{}, fmt.Errorf("%s must export exactly one output capacity: output_utf8_cap or output_bytes_cap", label)
	}
	return baseValidationResult{kind: moduleKindRun}, nil
}

func requireSignature(def api.FunctionDefinition, wantParams []api.ValueType, wantResults []api.ValueType, name string) error {
	if !sameTypes(def.ParamTypes(), wantParams) || !sameTypes(def.ResultTypes(), wantResults) {
		return fmt.Errorf("Wasm module export %s has invalid signature", name)
	}
	return nil
}

func sameTypes(a []api.ValueType, b []api.ValueType) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func getExportedI32(ctx context.Context, mod api.Module, name string) (int32, bool, error) {
	if fn := mod.ExportedFunction(name); fn != nil {
		if err := requireSignature(fn.Definition(), nil, []api.ValueType{api.ValueTypeI32}, name); err != nil {
			return 0, true, err
		}
		res, err := fn.Call(ctx)
		if err != nil {
			return 0, true, wasmruntime.HumanizeExecutionError(ctx, err)
		}
		if len(res) != 1 {
			return 0, true, fmt.Errorf("%s() returned %d values, want 1", name, len(res))
		}
		return api.DecodeI32(res[0]), true, nil
	}
	if mod.ExportedGlobal(name) != nil {
		return 0, true, fmt.Errorf("Wasm module must export %s() -> i32", name)
	}
	return 0, false, nil
}

func runComplianceModule(implWasm []byte, compliance complianceSpec, seed *int32) complianceOutcomes {
	return runBridgeComplianceModule(implWasm, compliance, seed)
}

func previewUTF8(in []byte) string {
	if len(in) > maxFailurePreviewBytes {
		in = in[:maxFailurePreviewBytes]
	}
	var b strings.Builder
	for _, c := range in {
		if c >= 0x20 && c <= 0x7e {
			b.WriteByte(c)
		} else {
			b.WriteString(fmt.Sprintf("\\x%02x", c))
		}
	}
	return b.String()
}

func previewHex(in []byte) string {
	if len(in) > maxFailurePreviewBytes {
		in = in[:maxFailurePreviewBytes]
	}
	var b strings.Builder
	for i, c := range in {
		if i > 0 {
			b.WriteByte(' ')
		}
		b.WriteString(fmt.Sprintf("%02x", c))
	}
	return b.String()
}
