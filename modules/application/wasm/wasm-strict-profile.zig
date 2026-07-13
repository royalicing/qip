//! wasm-strict-profile: a QIP component that enforces the strict artifact
//! profile's factual rules — the checks that are binary and stable:
//!
//! - no imports of any kind
//! - at most one linear memory, wasm32, not shared, with a declared maximum
//! - no `memory.grow`
//! - no atomic instructions
//! - no indirect calls (`call_indirect`, `return_call_indirect`, `call_ref`)
//! - no unknown instructions
//! - no recursion (the direct call graph must be acyclic)
//!
//! The recursion rule lives here rather than with the loop analysis because
//! it is one binary fact: edge collection rides the same decode pass the
//! allowlist needs, and its soundness depends on the indirect-call ban (with
//! indirect calls rejected, the recorded edges are the complete call graph).
//! Recursion is also a determinism problem for every tier: stack exhaustion
//! traps at a host-dependent depth.
//!
//! Input is a wasm module; output is the same bytes when the module passes;
//! the component traps on any violation. Subjective flow analysis (loop
//! bounds) lives in wasm-bounded-loops; run both for the full strict tier:
//!
//!   qip run -i m.wasm -- wasm-strict-profile.wasm wasm-bounded-loops.wasm
//!
//! The Go CLI's `internal/wasminspect` mirrors these checks with per-module
//! diagnostics; keep the two in sync.

const std = @import("std");
const wasm_reader = @import("lib/wasm-reader.zig");

const Reader = wasm_reader.Reader;
const Instr = wasm_reader.Instr;

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP;
const MAX_DEFINED_FUNCS: usize = 8192;
const MAX_CALL_EDGES: usize = 262144;
const INPUT_CONTENT_TYPE = "application/wasm";
const OUTPUT_CONTENT_TYPE = "application/wasm";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

var edge_head_buf: [MAX_DEFINED_FUNCS]i32 = undefined;
var edge_to_buf: [MAX_CALL_EDGES]u32 = undefined;
var edge_next_buf: [MAX_CALL_EDGES]i32 = undefined;
var edge_count: usize = 0;
var dfs_state_buf: [MAX_DEFINED_FUNCS]u8 = undefined;
var dfs_stack_buf: [MAX_DEFINED_FUNCS]u32 = undefined;
var dfs_edge_buf: [MAX_DEFINED_FUNCS]i32 = undefined;

const CheckError = wasm_reader.Error || error{
    ImportNotAllowed,
    Memory64NotAllowed,
    SharedMemoryNotAllowed,
    MemoryMaxRequired,
    TooManyMemories,
    MemoryGrowNotAllowed,
    AtomicsNotAllowed,
    IndirectCallNotAllowed,
    RecursionNotAllowed,
    FunctionCodeMismatch,
    TooManyFunctions,
    TooManyEdges,
};

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&output_buf)));
}

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

export fn input_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr)));
}

export fn input_content_type_size() u32 {
    return @as(u32, @intCast(INPUT_CONTENT_TYPE.len));
}

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(OUTPUT_CONTENT_TYPE.len));
}

// ---------------------------------------------------------------------------
// Call graph: direct calls between defined functions, rejected on any cycle.
// ---------------------------------------------------------------------------

fn initEdgeGraph(defined_funcs: usize) void {
    var i: usize = 0;
    while (i < defined_funcs) : (i += 1) {
        edge_head_buf[i] = -1;
    }
    edge_count = 0;
}

fn addEdge(src: u32, dst: u32) CheckError!void {
    if (edge_count >= MAX_CALL_EDGES) return CheckError.TooManyEdges;
    const idx = edge_count;
    edge_to_buf[idx] = dst;
    edge_next_buf[idx] = edge_head_buf[src];
    edge_head_buf[src] = @as(i32, @intCast(idx));
    edge_count += 1;
}

fn hasCallCycle(defined_func_count: u32) bool {
    var i: usize = 0;
    while (i < defined_func_count) : (i += 1) {
        dfs_state_buf[i] = 0;
    }

    i = 0;
    while (i < defined_func_count) : (i += 1) {
        if (dfs_state_buf[i] != 0) continue;

        var stack_len: usize = 1;
        dfs_stack_buf[0] = @intCast(i);
        dfs_edge_buf[0] = edge_head_buf[i];
        dfs_state_buf[i] = 1;

        while (stack_len > 0) {
            const top = stack_len - 1;
            const e = dfs_edge_buf[top];
            if (e == -1) {
                const done: usize = @intCast(dfs_stack_buf[top]);
                dfs_state_buf[done] = 2;
                stack_len -= 1;
                continue;
            }

            const ei: usize = @intCast(e);
            dfs_edge_buf[top] = edge_next_buf[ei];
            const to = edge_to_buf[ei];
            if (to >= defined_func_count) continue;

            const to_usize: usize = @intCast(to);
            if (dfs_state_buf[to_usize] == 1) return true;
            if (dfs_state_buf[to_usize] == 0) {
                dfs_stack_buf[stack_len] = to;
                dfs_edge_buf[stack_len] = edge_head_buf[to_usize];
                dfs_state_buf[to_usize] = 1;
                stack_len += 1;
            }
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Per-instruction policy: banned opcodes and call-edge collection.
// ---------------------------------------------------------------------------

const ProfileHandler = struct {
    func_idx: u32,
    defined_func_count: u32,

    pub fn onInstr(self: *ProfileHandler, instr: Instr) CheckError!void {
        switch (instr.op) {
            0x40 => return CheckError.MemoryGrowNotAllowed,
            0xfe => return CheckError.AtomicsNotAllowed,
            0x11, 0x13, 0x14 => return CheckError.IndirectCallNotAllowed,
            0x10, 0x12 => {
                const callee: u32 = @intCast(instr.imm);
                if (callee < self.defined_func_count) {
                    try addEdge(self.func_idx, callee);
                }
            },
            else => {},
        }
    }

    pub fn onBrTableTarget(self: *ProfileHandler, depth: u32) CheckError!void {
        _ = self;
        _ = depth;
    }
};

// ---------------------------------------------------------------------------
// Sections
// ---------------------------------------------------------------------------

fn parseTypeSection(payload: []const u8) CheckError!void {
    var r = Reader.init(payload);
    const n = try r.readVarU32();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const form = try r.readByte();
        if (form != 0x60) return CheckError.InvalidWasm;
        const params = try r.readVarU32();
        _ = try r.readN(params);
        const results = try r.readVarU32();
        _ = try r.readN(results);
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
}

fn parseImportSection(payload: []const u8) CheckError!void {
    var r = Reader.init(payload);
    const n = try r.readVarU32();
    if (n > 0) return CheckError.ImportNotAllowed;
    if (r.remaining() != 0) return CheckError.TrailingBytes;
}

fn parseFunctionSection(payload: []const u8) CheckError!u32 {
    var r = Reader.init(payload);
    const n = try r.readVarU32();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        _ = try r.readVarU32();
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
    return n;
}

fn parseMemorySection(payload: []const u8) CheckError!void {
    var r = Reader.init(payload);
    const n = try r.readVarU32();
    if (n > 1) return CheckError.TooManyMemories;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const limits = try wasm_reader.readLimits(&r);
        if (limits.memory64) return CheckError.Memory64NotAllowed;
        if (limits.shared) return CheckError.SharedMemoryNotAllowed;
        if (!limits.has_max) return CheckError.MemoryMaxRequired;
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
}

fn parseCodeSection(payload: []const u8, defined_func_count: u32) CheckError!void {
    if (defined_func_count > MAX_DEFINED_FUNCS) return CheckError.TooManyFunctions;
    initEdgeGraph(defined_func_count);

    var r = Reader.init(payload);
    const n = try r.readVarU32();
    if (n != defined_func_count) return CheckError.FunctionCodeMismatch;

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const body_size = try r.readVarU32();
        const body = try r.readN(body_size);
        var handler = ProfileHandler{ .func_idx = i, .defined_func_count = defined_func_count };
        try wasm_reader.walkFunctionBody(&handler, body);
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
}

fn checkModule(wasm: []const u8) CheckError!void {
    try wasm_reader.checkHeader(wasm);

    var r = Reader.init(wasm[8..]);
    var defined_func_count: u32 = 0;
    var have_function_section = false;
    var have_code_section = false;

    while (r.remaining() > 0) {
        const section_id = try r.readByte();
        const section_size = try r.readVarU32();
        const payload = try r.readN(section_size);

        switch (section_id) {
            0 => {},
            1 => try parseTypeSection(payload),
            2 => try parseImportSection(payload),
            3 => {
                defined_func_count = try parseFunctionSection(payload);
                have_function_section = true;
            },
            5 => try parseMemorySection(payload),
            10 => {
                try parseCodeSection(payload, defined_func_count);
                have_code_section = true;
            },
            else => {},
        }
    }

    if (have_function_section and !have_code_section) return CheckError.InvalidWasm;
    if (hasCallCycle(defined_func_count)) return CheckError.RecursionNotAllowed;
}

export fn render(input_size: u32) u32 {
    const input_len: usize = @intCast(input_size);
    if (input_len > INPUT_CAP) @trap();
    checkModule(input_buf[0..input_len]) catch @trap();
    @memcpy(output_buf[0..input_len], input_buf[0..input_len]);
    return input_size;
}

// ---------------------------------------------------------------------------
// Tests. wat2wasm fixture bytes note their source text.
// ---------------------------------------------------------------------------

const moduleWithBody = wasm_reader.moduleWithBody;
const hexBytes = wasm_reader.hexBytes;

const ok_module = moduleWithBody(&[_]u8{0x0b});

const atomics_module = moduleWithBody(&[_]u8{ 0xfe, 0x10, 0x00, 0x00, 0x0b });

// Loop bounds are the other component's job: a bare backedge is fine here.
const unbounded_loop_module = moduleWithBody(&[_]u8{
    0x03, 0x40, // loop
    0x0c, 0x00, // br 0
    0x0b, 0x0b,
});

const no_memory_max_module = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x05, 0x03, 0x01, 0x00, 0x01,
};

const recursion_module = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
    0x03, 0x03, 0x02, 0x00, 0x00,
    0x05, 0x04, 0x01, 0x01, 0x01, 0x01,
    0x0a, 0x0b, 0x02,
    0x04, 0x00, 0x10, 0x01, 0x0b,
    0x04, 0x00, 0x10, 0x00, 0x0b,
};

const memory_grow_module = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
    0x03, 0x02, 0x01, 0x00,
    0x05, 0x04, 0x01, 0x01, 0x01, 0x01,
    0x0a, 0x08, 0x01, 0x06, 0x00, 0x41, 0x00, 0x40, 0x00, 0x0b,
};

// (func (param i32) (result i32) (i32.trunc_sat_f32_s (f32.const 1.5)))
const trunc_sat_module = hexBytes(
    "0061736d0100000001060160017f017f03020100050401010101071302066d65" ++
        "6d6f727902000672656e64657200000a0b010900430000c03ffc000b",
);

// (func (export "render") (param i32) (result i32)
//   (memory.copy ...) (memory.fill ...) (i32.const 0))
const bulk_memory_module = hexBytes(
    "0061736d0100000001060160017f017f03020100050401010101071302066d65" ++
        "6d6f727902000672656e64657200000a19011700410041104108fc0a00004100" ++
        "41004108fc0b0041000b",
);

// (func (param i32) (result i32) (i32.extend8_s (local.get 0)))
const sign_extension_module = hexBytes(
    "0061736d0100000001060160017f017f030201000504010101010a0701050020" ++
        "00c00b",
);

// (func (param i32) (result i32) (local v128)
//   v128.const, v128.load8_lane, i8x16.shuffle, v128.store, i8x16.extract_lane_s
const simd_lane_module = hexBytes(
    "0061736d0100000001060160017f017f030201000504010101010a4601440101" ++
        "7b2000fd0c00000000000000000000000000000000fd54000003210120012001" ++
        "fd0d000102030405060708090a0b0c0d0e0f210141102001fd0b04002001fd15" ++
        "020b",
);

// (table 1 1 funcref) (elem (i32.const 0) $f) (func (call_indirect ...))
const call_indirect_module = hexBytes(
    "0061736d01000000010401600000030302000004050170010101050401010101" ++
        "0907010041000b01000a0c0202000b070041001100000b",
);

// (import "env" "log" (func (param i32)))
const import_module = hexBytes(
    "0061736d0100000001080260017f00600000020b0103656e76036c6f67000003" ++
        "0201010504010101010a08010600410110000b",
);

test "accepts a module with fixed memory and no calls" {
    try checkModule(&ok_module);
}

test "accepts an unbounded loop: loop bounds are wasm-bounded-loops' job" {
    try checkModule(&unbounded_loop_module);
}

test "accepts saturating truncation" {
    try checkModule(&trunc_sat_module);
}

test "accepts bulk memory copy and fill" {
    try checkModule(&bulk_memory_module);
}

test "accepts sign-extension operators" {
    try checkModule(&sign_extension_module);
}

test "accepts SIMD lane and shuffle immediates" {
    try checkModule(&simd_lane_module);
}

test "rejects call_indirect" {
    try std.testing.expectError(CheckError.IndirectCallNotAllowed, checkModule(&call_indirect_module));
}

test "rejects imports" {
    try std.testing.expectError(CheckError.ImportNotAllowed, checkModule(&import_module));
}

test "rejects atomics" {
    try std.testing.expectError(CheckError.AtomicsNotAllowed, checkModule(&atomics_module));
}

test "requires memory max when memory is declared" {
    try std.testing.expectError(CheckError.MemoryMaxRequired, checkModule(&no_memory_max_module));
}

test "rejects direct recursion" {
    try std.testing.expectError(CheckError.RecursionNotAllowed, checkModule(&recursion_module));
}

test "rejects memory.grow" {
    try std.testing.expectError(CheckError.MemoryGrowNotAllowed, checkModule(&memory_grow_module));
}
