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
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/royalicing/qip/internal/wasminspect"
	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

const usageComply = "Usage: qip comply <impl.wasm> [--with <compliance.wasm> ...] [--declarative-checkers] [--seed <n>] [-v|--verbose]"

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
	var declarativeCheckers bool
	var seedFlag int
	var seedSet bool
	fs.Var(&withCompliances, "with", "compliance component (repeatable)")
	fs.BoolVar(&verbose, "v", false, "enable verbose logging")
	fs.BoolVar(&verbose, "verbose", false, "enable verbose logging")
	fs.BoolVar(&declarativeCheckers, "declarative-checkers", false, "require each --with checker to be an unconditional list of oracle calls")
	fs.Func("seed", "fuzz seed passed to Content Compliance components via uniform_set_seed", func(v string) error {
		n, err := strconv.Atoi(v)
		if err != nil {
			return fmt.Errorf("invalid --seed: %q", v)
		}
		seedFlag = n
		seedSet = true
		return nil
	})
	if err := fs.Parse(normalizeComplyArgs(args)); err != nil {
		return fmt.Errorf("%s %w", usageComply, err)
	}
	rest := fs.Args()
	if len(rest) != 1 {
		return errors.New(usageComply)
	}

	implPath := rest[0]
	implWasm, err := readComplyModulePath(implPath)
	if err != nil {
		return err
	}

	if verbose {
		sum := sha256.Sum256(implWasm)
		fmt.Fprintf(os.Stderr, "impl sha256: %x\n", sum)
	}

	base, err := validateBaseContract(implWasm)
	if err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "comply: module fulfills %s contract\n", base.kind)

	analysis, err := wasminspect.AnalyzeModule(implWasm)
	if err != nil {
		return fmt.Errorf("comply: static analysis failed: %w", err)
	}
	contractChecks, contractFail := wasminspect.EvaluateQIPContractChecks(analysis)
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
		if contractFail {
			return errors.New("comply: static qip contract checks failed")
		}
	}

	if len(withCompliances) == 0 {
		return nil
	}

	compliances := make([]complianceSpec, 0, len(withCompliances))
	for i, path := range withCompliances {
		body, err := readComplyModulePath(path)
		if err != nil {
			return fmt.Errorf("failed to read --with %q: %w", path, err)
		}
		if verbose {
			sum := sha256.Sum256(body)
			fmt.Fprintf(os.Stderr, "compliance[%d] %s sha256: %x\n", i+1, path, sum)
		}
		if declarativeCheckers {
			if err := wasminspect.ValidateDeclarativeComplyChecker(body); err != nil {
				return fmt.Errorf("compliance component %q: %w", path, err)
			}
			fmt.Fprintf(os.Stderr, "comply: declarative checker PASS --with %s\n", path)
		}
		compliances = append(compliances, complianceSpec{index: i, path: path, wasm: body})
	}

	outcomes := make(chan complianceOutcomes, len(compliances))
	var wg sync.WaitGroup
	var seed *int32
	if seedSet {
		s := int32(seedFlag)
		seed = &s
	}
	for _, compliance := range compliances {
		wg.Go(func() {
			outcomes <- runComplianceModule(implWasm, compliance, seed)
		})
	}
	wg.Wait()
	close(outcomes)

	results := make([]complianceOutcomes, 0, len(compliances))
	for out := range outcomes {
		results = append(results, out)
	}
	sort.Slice(results, func(i, j int) bool { return results[i].index < results[j].index })

	failCount := 0
	for _, out := range results {
		if out.passed {
			if out.cases > 0 {
				fmt.Fprintf(os.Stderr, "comply: PASS --with %s (%d cases, %dms)\n", out.path, out.cases, out.duration.Milliseconds())
				continue
			}
			fmt.Fprintf(os.Stderr, "comply: PASS --with %s (%dms)\n", out.path, out.duration.Milliseconds())
			continue
		}
		failCount++
		fmt.Fprintf(os.Stderr, "comply: FAIL --with %s (%dms): %v\n", out.path, out.duration.Milliseconds(), out.err)
		if out.detail != "" {
			fmt.Fprintf(os.Stderr, "%s\n", out.detail)
		}
	}

	if failCount > 0 {
		return fmt.Errorf("compliance failed: %d/%d compliance components failed", failCount, len(results))
	}
	return nil
}

func normalizeComplyArgs(args []string) []string {
	flagsWithValue := map[string]struct{}{
		"--with": {},
		"--seed": {},
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

func validateBaseContract(implWasm []byte) (baseValidationResult, error) {
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
		return baseValidationResult{}, errors.New("Wasm module must export memory")
	}

	funcs := compiled.ExportedFunctions()
	hasRun := false
	if runDef, ok := funcs[complyExportRun]; ok {
		if err := requireSignature(runDef, []api.ValueType{api.ValueTypeI32}, []api.ValueType{api.ValueTypeI32}, complyExportRun); err != nil {
			return baseValidationResult{}, err
		}
		if _, ok, err := getExportedI32(ctx, mod, complyExportInputPtr); err != nil {
			return baseValidationResult{}, err
		} else if !ok {
			return baseValidationResult{}, errors.New("Wasm render module must export input_ptr as global or function")
		}
		if _, ok, err := getExportedI32(ctx, mod, complyExportInputUTF8Cap); err != nil {
			return baseValidationResult{}, err
		} else if ok {
			hasRun = true
		} else if _, ok, err := getExportedI32(ctx, mod, complyExportInputBytesCap); err != nil {
			return baseValidationResult{}, err
		} else if ok {
			hasRun = true
		} else {
			return baseValidationResult{}, errors.New("Wasm render module must export input_utf8_cap or input_bytes_cap as global or function")
		}
	}

	hasTile := false
	if tileDef, ok := funcs[complyExportTileRGBA32Float]; ok {
		if err := requireSignature(tileDef, []api.ValueType{api.ValueTypeF32, api.ValueTypeF32}, []api.ValueType{}, complyExportTileRGBA32Float); err != nil {
			return baseValidationResult{}, err
		}
		if _, ok, err := getExportedI32(ctx, mod, complyExportInputPtr); err != nil {
			return baseValidationResult{}, err
		} else if !ok {
			return baseValidationResult{}, errors.New("Wasm tile module must export input_ptr as global or function")
		}
		if _, ok, err := getExportedI32(ctx, mod, complyExportInputBytesCap); err != nil {
			return baseValidationResult{}, err
		} else if !ok {
			return baseValidationResult{}, errors.New("Wasm tile module must export input_bytes_cap as global or function")
		}
		hasTile = true
	}

	switch {
	case hasRun && hasTile:
		return baseValidationResult{kind: moduleKindRunAndTile}, nil
	case hasRun:
		return baseValidationResult{kind: moduleKindRun}, nil
	case hasTile:
		return baseValidationResult{kind: moduleKindTile}, nil
	default:
		return baseValidationResult{}, errors.New("Wasm module is neither a render module nor a tile module")
	}
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
	if g := mod.ExportedGlobal(name); g != nil {
		return int32(uint32(g.Get())), true, nil
	}
	if fn := mod.ExportedFunction(name); fn != nil {
		res, err := fn.Call(ctx)
		if err != nil {
			return 0, true, wasmruntime.HumanizeExecutionError(ctx, err)
		}
		if len(res) != 1 {
			return 0, true, fmt.Errorf("%s() returned %d values, want 1", name, len(res))
		}
		return api.DecodeI32(res[0]), true, nil
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
