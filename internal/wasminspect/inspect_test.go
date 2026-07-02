package wasminspect

import "testing"

func TestAnalyzeModuleCountsAndNoCycle(t *testing.T) {
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
			{0x0b}, // end function
		},
		WithTable: true,
	})

	analysis, err := AnalyzeModule(module)
	if err != nil {
		t.Fatalf("AnalyzeModule: %v", err)
	}
	if analysis.ImportedFuncCount != 1 {
		t.Fatalf("importedFuncCount=%d, want 1", analysis.ImportedFuncCount)
	}
	if analysis.Metrics.BranchDecision != 2 {
		t.Fatalf("branch decisions=%d, want 2", analysis.Metrics.BranchDecision)
	}
	if analysis.Metrics.BrTableCount != 1 || analysis.Metrics.BrTableTargets != 2 {
		t.Fatalf("br_table count/targets=%d/%d, want 1/2", analysis.Metrics.BrTableCount, analysis.Metrics.BrTableTargets)
	}
	if analysis.Metrics.CallImport != 1 || analysis.Metrics.CallLocal != 1 || analysis.Metrics.CallIndirect != 1 {
		t.Fatalf("calls import/local/indirect=%d/%d/%d, want 1/1/1", analysis.Metrics.CallImport, analysis.Metrics.CallLocal, analysis.Metrics.CallIndirect)
	}
	if analysis.Metrics.LoopBackedge != 1 {
		t.Fatalf("loop_backedge=%d, want 1", analysis.Metrics.LoopBackedge)
	}
	if analysis.Metrics.InstructionTotal != 14 {
		t.Fatalf("instruction total=%d, want 14", analysis.Metrics.InstructionTotal)
	}

	hasCycle, _ := DetectCallCycle(analysis.CallEdges)
	if hasCycle {
		t.Fatalf("unexpected recursion cycle")
	}
}

func TestDetectCallCycle(t *testing.T) {
	module := buildTestModule(testModuleConfig{
		FunctionBodies: [][]byte{
			{0x10, 0x01, 0x0b}, // func 0 calls func 1
			{0x10, 0x00, 0x0b}, // func 1 calls func 0
		},
	})
	analysis, err := AnalyzeModule(module)
	if err != nil {
		t.Fatalf("AnalyzeModule: %v", err)
	}
	hasCycle, cycle := DetectCallCycle(analysis.CallEdges)
	if !hasCycle {
		t.Fatalf("expected recursion cycle")
	}
	if len(cycle) != 2 {
		t.Fatalf("cycle=%v, want 2 nodes", cycle)
	}
}

func TestEvaluateQIPContractChecksFailDynamicFunction(t *testing.T) {
	module := buildTestModule(testModuleConfig{
		ImportFuncCount: 1,
		FunctionBodies:  [][]byte{{0x10, 0x00, 0x0b}}, // call import
		Exports: []testExport{
			{Name: "input_ptr", Kind: 0x00, Index: 1},
		},
	})
	analysis, err := AnalyzeModule(module)
	if err != nil {
		t.Fatalf("AnalyzeModule: %v", err)
	}
	checks, fail := EvaluateQIPContractChecks(analysis)
	if !fail {
		t.Fatalf("expected contract failure")
	}
	if len(checks) != 1 {
		t.Fatalf("checks=%d, want 1", len(checks))
	}
	if checks[0].Pass || checks[0].Export != "input_ptr" || checks[0].Kind != "func" {
		t.Fatalf("unexpected check result: %+v", checks[0])
	}
}

func TestEvaluateQIPContractChecksPassGlobalGetFunction(t *testing.T) {
	module := buildTestModule(testModuleConfig{
		Globals: []testGlobal{
			{ValueType: 0x7f, InitExpr: []byte{0x41, 0x80, 0x80, 0x40}}, // i32.const 1048576
		},
		FunctionBodies: [][]byte{{0x23, 0x00, 0x0b}}, // global.get 0
		Exports: []testExport{
			{Name: "input_ptr", Kind: 0x00, Index: 0},
		},
	})
	analysis, err := AnalyzeModule(module)
	if err != nil {
		t.Fatalf("AnalyzeModule: %v", err)
	}
	checks, fail := EvaluateQIPContractChecks(analysis)
	if fail {
		t.Fatalf("unexpected contract failure: %+v", checks)
	}
	if len(checks) != 1 {
		t.Fatalf("checks=%d, want 1", len(checks))
	}
	if !checks[0].Pass || checks[0].Export != "input_ptr" || checks[0].Kind != "func" {
		t.Fatalf("unexpected check result: %+v", checks[0])
	}
}

func TestEvaluateQIPContractChecksPassConstantGlobal(t *testing.T) {
	module := buildTestModule(testModuleConfig{
		Globals: []testGlobal{
			{ValueType: 0x7f, InitExpr: []byte{0x41, 0x80, 0x80, 0x40}}, // i32.const 1048576
		},
		Exports: []testExport{{Name: "input_ptr", Kind: 0x03, Index: 0}},
	})
	analysis, err := AnalyzeModule(module)
	if err != nil {
		t.Fatalf("AnalyzeModule: %v", err)
	}
	checks, fail := EvaluateQIPContractChecks(analysis)
	if fail {
		t.Fatalf("unexpected contract failure: %+v", checks)
	}
	if len(checks) != 1 {
		t.Fatalf("checks=%d, want 1", len(checks))
	}
	if !checks[0].Pass || checks[0].Kind != "global" {
		t.Fatalf("unexpected check result: %+v", checks[0])
	}
}

type testModuleConfig struct {
	ImportFuncCount   int
	ImportGlobalCount int
	FunctionBodies    [][]byte
	WithTable         bool
	Globals           []testGlobal
	Exports           []testExport
	StartFunc         *uint32
}

type testGlobal struct {
	ValueType byte
	Mutable   bool
	InitExpr  []byte // without trailing end (0x0b)
}

type testExport struct {
	Name  string
	Kind  byte
	Index uint32
}

func buildTestModule(cfg testModuleConfig) []byte {
	typeEntry := []byte{0x60, 0x00, 0x00} // () -> ()
	typeSecPayload := append(encodeU32(1), typeEntry...)
	typeSec := makeSection(1, typeSecPayload)

	importEntries := make([][]byte, 0, cfg.ImportFuncCount+cfg.ImportGlobalCount)
	for i := 0; i < cfg.ImportFuncCount; i++ {
		entry := []byte{}
		entry = append(entry, encodeName("env")...)
		entry = append(entry, encodeName("imp"+strconvI(i))...)
		entry = append(entry, 0x00)            // import kind func
		entry = append(entry, encodeU32(0)...) // typeidx 0
		importEntries = append(importEntries, entry)
	}
	for i := 0; i < cfg.ImportGlobalCount; i++ {
		entry := []byte{}
		entry = append(entry, encodeName("env")...)
		entry = append(entry, encodeName("gimp"+strconvI(i))...)
		entry = append(entry, 0x03) // import kind global
		entry = append(entry, 0x7f) // i32
		entry = append(entry, 0x00) // immutable
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

	globalSec := []byte{}
	if len(cfg.Globals) > 0 {
		payload := []byte{}
		payload = append(payload, encodeU32(uint32(len(cfg.Globals)))...)
		for _, g := range cfg.Globals {
			payload = append(payload, g.ValueType)
			if g.Mutable {
				payload = append(payload, 0x01)
			} else {
				payload = append(payload, 0x00)
			}
			payload = append(payload, g.InitExpr...)
			payload = append(payload, 0x0b) // end const expr
		}
		globalSec = makeSection(6, payload)
	}

	exportSec := []byte{}
	if len(cfg.Exports) > 0 {
		payload := []byte{}
		payload = append(payload, encodeU32(uint32(len(cfg.Exports)))...)
		for _, e := range cfg.Exports {
			payload = append(payload, encodeName(e.Name)...)
			payload = append(payload, e.Kind)
			payload = append(payload, encodeU32(e.Index)...)
		}
		exportSec = makeSection(7, payload)
	}

	startSec := []byte{}
	if cfg.StartFunc != nil {
		startSec = makeSection(8, encodeU32(*cfg.StartFunc))
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
	module = append(module, globalSec...)
	module = append(module, exportSec...)
	module = append(module, startSec...)
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
