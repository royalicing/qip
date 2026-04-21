package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestNormalizeScoreArgs(t *testing.T) {
	in := []string{"module.wasm"}
	got := normalizeScoreArgs(in)
	want := []string{"module.wasm"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("args=%v, want %v", got, want)
	}

	inWithDashDash := []string{"module.wasm", "--", "--not-a-flag"}
	gotWithDashDash := normalizeScoreArgs(inWithDashDash)
	wantWithDashDash := []string{"--", "module.wasm", "--not-a-flag"}
	if !reflect.DeepEqual(gotWithDashDash, wantWithDashDash) {
		t.Fatalf("args=%v, want %v", gotWithDashDash, wantWithDashDash)
	}
}

func TestAnalyzeWASMModuleCounts(t *testing.T) {
	module := buildTestModule(testModuleConfig{
		ImportFuncCount: 1,
		FunctionBodies: [][]byte{
			{
				0x03, 0x40, // loop
				0x0d, 0x00, // br_if 0 (backedge)
				0x0b,       // end loop
				0x04, 0x40, // if
				0x0b,       // end if
				0x02, 0x40, // block
				0x41, 0x00, // i32.const 0
				0x0e, 0x02, 0x00, 0x00, 0x00, // br_table [0,0] default 0
				0x0b,       // end block
				0x10, 0x00, // call import (global idx 0)
				0x10, 0x02, // call local (global idx 2)
				0x11, 0x00, 0x00, // call_indirect type 0 table 0
				0x0b, // end function
			},
			{
				0x0b, // end function
			},
		},
		WithTable: true,
	})

	metrics, edges, importedFuncCount, err := analyzeWASMModule(module)
	if err != nil {
		t.Fatalf("analyzeWASMModule: %v", err)
	}
	if importedFuncCount != 1 {
		t.Fatalf("importedFuncCount=%d, want 1", importedFuncCount)
	}

	if metrics.BranchDecision != 2 {
		t.Fatalf("branch decisions=%d, want 2", metrics.BranchDecision)
	}
	if metrics.BrTableCount != 1 || metrics.BrTableTargets != 2 {
		t.Fatalf("br_table count/targets=%d/%d, want 1/2", metrics.BrTableCount, metrics.BrTableTargets)
	}
	if metrics.CallImport != 1 || metrics.CallLocal != 1 || metrics.CallIndirect != 1 {
		t.Fatalf("calls import/local/indirect=%d/%d/%d, want 1/1/1", metrics.CallImport, metrics.CallLocal, metrics.CallIndirect)
	}
	if metrics.LoopBackedge != 1 {
		t.Fatalf("loop_backedge=%d, want 1", metrics.LoopBackedge)
	}
	if metrics.InstructionTotal != 14 {
		t.Fatalf("instruction total=%d, want 14", metrics.InstructionTotal)
	}

	hasCycle, cycle := detectCallCycle(edges)
	if hasCycle {
		t.Fatalf("unexpected recursion cycle: %v", cycle)
	}
}

func TestAnalyzeWASMModuleDetectsRecursion(t *testing.T) {
	module := buildTestModule(testModuleConfig{
		ImportFuncCount: 0,
		FunctionBodies: [][]byte{
			{0x10, 0x01, 0x0b}, // func 0 calls func 1
			{0x10, 0x00, 0x0b}, // func 1 calls func 0
		},
	})

	_, edges, _, err := analyzeWASMModule(module)
	if err != nil {
		t.Fatalf("analyzeWASMModule: %v", err)
	}
	hasCycle, cycle := detectCallCycle(edges)
	if !hasCycle {
		t.Fatal("expected recursion cycle")
	}
	if len(cycle) != 2 {
		t.Fatalf("cycle=%v, want 2 nodes", cycle)
	}
}

func TestRunScoreWritesASCIIAndDetails(t *testing.T) {
	module := buildTestModule(testModuleConfig{
		ImportFuncCount: 1,
		FunctionBodies:  [][]byte{{0x10, 0x00, 0x0b}}, // import call
	})
	dir := t.TempDir()
	path := filepath.Join(dir, "mod.wasm")
	if err := os.WriteFile(path, module, 0o644); err != nil {
		t.Fatalf("write module: %v", err)
	}

	var out bytes.Buffer
	err := RunScore([]string{path}, ScoreConfig{
		UsageScore: "usage score",
		Stdout:     &out,
	})
	if err != nil {
		t.Fatalf("RunScore: %v", err)
	}

	got := out.String()
	if !strings.Contains(got, "MODULE") {
		t.Fatalf("missing summary header: %q", got)
	}
	if !strings.Contains(got, "branch_decisions (br_if + if):") {
		t.Fatalf("missing details breakdown: %q", got)
	}
	if !strings.Contains(got, "range: [") {
		t.Fatalf("missing score range: %q", got)
	}
}

func TestRunScoreFailsOnRecursion(t *testing.T) {
	module := buildTestModule(testModuleConfig{
		FunctionBodies: [][]byte{
			{0x10, 0x01, 0x0b},
			{0x10, 0x00, 0x0b},
		},
	})
	dir := t.TempDir()
	path := filepath.Join(dir, "rec.wasm")
	if err := os.WriteFile(path, module, 0o644); err != nil {
		t.Fatalf("write module: %v", err)
	}

	var out bytes.Buffer
	err := RunScore([]string{path}, ScoreConfig{
		UsageScore: "usage score",
		Stdout:     &out,
	})
	if err == nil || !strings.Contains(err.Error(), "recursion cycle") {
		t.Fatalf("expected recursion error, got %v", err)
	}
	if !strings.Contains(out.String(), "FAIL(recursion)") {
		t.Fatalf("expected FAIL(recursion) output, got %q", out.String())
	}
}

type testModuleConfig struct {
	ImportFuncCount int
	FunctionBodies  [][]byte
	WithTable       bool
}

func buildTestModule(cfg testModuleConfig) []byte {
	typeEntry := []byte{0x60, 0x00, 0x00} // () -> ()
	typeSecPayload := append(encodeU32(1), typeEntry...)
	typeSec := makeSection(1, typeSecPayload)

	importEntries := make([][]byte, 0, cfg.ImportFuncCount)
	for i := 0; i < cfg.ImportFuncCount; i++ {
		entry := []byte{}
		entry = append(entry, encodeName("env")...)
		entry = append(entry, encodeName("imp"+strconvI(i))...)
		entry = append(entry, 0x00)            // import kind func
		entry = append(entry, encodeU32(0)...) // typeidx 0
		importEntries = append(importEntries, entry)
	}
	importSec := []byte{}
	if len(importEntries) > 0 {
		payload := append(encodeU32(uint32(len(importEntries))), joinBytes(importEntries...)...)
		importSec = makeSection(2, payload)
	}

	functionTypeIdx := make([]byte, 0, len(cfg.FunctionBodies)*2)
	functionTypeIdx = append(functionTypeIdx, encodeU32(uint32(len(cfg.FunctionBodies)))...)
	for range cfg.FunctionBodies {
		functionTypeIdx = append(functionTypeIdx, 0x00) // typeidx 0
	}
	functionSec := makeSection(3, functionTypeIdx)

	tableSec := []byte{}
	if cfg.WithTable {
		payload := []byte{}
		payload = append(payload, encodeU32(1)...) // one table
		payload = append(payload, 0x70)            // funcref
		payload = append(payload, 0x00)            // min only
		payload = append(payload, encodeU32(1)...) // min=1
		tableSec = makeSection(4, payload)
	}

	codePayload := []byte{}
	codePayload = append(codePayload, encodeU32(uint32(len(cfg.FunctionBodies)))...)
	for _, ops := range cfg.FunctionBodies {
		body := []byte{0x00} // local decl count
		body = append(body, ops...)
		codePayload = append(codePayload, encodeU32(uint32(len(body)))...)
		codePayload = append(codePayload, body...)
	}
	codeSec := makeSection(10, codePayload)

	module := []byte{0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00}
	module = append(module, typeSec...)
	module = append(module, importSec...)
	module = append(module, functionSec...)
	module = append(module, tableSec...)
	module = append(module, codeSec...)
	return module
}

func makeSection(id byte, payload []byte) []byte {
	out := []byte{id}
	out = append(out, encodeU32(uint32(len(payload)))...)
	out = append(out, payload...)
	return out
}

func encodeName(s string) []byte {
	out := encodeU32(uint32(len(s)))
	out = append(out, []byte(s)...)
	return out
}

func encodeU32(v uint32) []byte {
	if v == 0 {
		return []byte{0x00}
	}
	out := make([]byte, 0, 5)
	for v > 0 {
		b := byte(v & 0x7f)
		v >>= 7
		if v != 0 {
			b |= 0x80
		}
		out = append(out, b)
	}
	return out
}

func joinBytes(parts ...[]byte) []byte {
	total := 0
	for _, p := range parts {
		total += len(p)
	}
	out := make([]byte, 0, total)
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

func strconvI(v int) string {
	if v == 0 {
		return "0"
	}
	neg := v < 0
	if neg {
		v = -v
	}
	buf := make([]byte, 0, 12)
	for v > 0 {
		d := byte(v % 10)
		buf = append([]byte{'0' + d}, buf...)
		v /= 10
	}
	if neg {
		buf = append([]byte{'-'}, buf...)
	}
	return string(buf)
}
