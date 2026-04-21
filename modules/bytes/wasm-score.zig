const std = @import("std");

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = 1024 * 1024;
const MAX_DEFINED_FUNCS: usize = 8192;
const MAX_CALL_EDGES: usize = 262144;
const MAX_CONTROL_DEPTH: usize = 4096;
const INPUT_CONTENT_TYPE = "application/wasm";
const OUTPUT_CONTENT_TYPE = "text/plain";

const score_instr_jit_weight: f64 = 0.02;
const score_instr_interp_weight: f64 = 0.12;
const score_branch_jit_weight: f64 = 1.0;
const score_branch_interp_weight: f64 = 2.0;
const score_br_table_jit_base: f64 = 1.0;
const score_br_table_interp_base: f64 = 2.0;
const score_br_table_jit_per_target: f64 = 0.1;
const score_br_table_interp_per_target: f64 = 0.5;
const score_call_local_jit_weight: f64 = 0.5;
const score_call_local_interp_weight: f64 = 5.0;
const score_call_indirect_jit_weight: f64 = 20.0;
const score_call_indirect_interp_weight: f64 = 50.0;
const score_call_import_jit_weight: f64 = 20.0;
const score_call_import_interp_weight: f64 = 50.0;
const score_loop_backedge_jit_weight: f64 = 1.0;
const score_loop_backedge_interp_weight: f64 = 3.0;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

var edge_head_buf: [MAX_DEFINED_FUNCS]i32 = undefined;
var edge_to_buf: [MAX_CALL_EDGES]u32 = undefined;
var edge_next_buf: [MAX_CALL_EDGES]i32 = undefined;
var edge_count: usize = 0;

var dfs_state_buf: [MAX_DEFINED_FUNCS]u8 = undefined;
var dfs_stack_buf: [MAX_DEFINED_FUNCS]u32 = undefined;
var cycle_buf: [MAX_DEFINED_FUNCS]u32 = undefined;

const ParseError = error{
    InvalidWasm,
    UnsupportedVersion,
    UnexpectedEOF,
    InvalidLEB,
    TrailingBytes,
    UnsupportedImportKind,
    FunctionCodeMismatch,
    TooManyFunctions,
    TooManyEdges,
    TooDeepControl,
};

const ScoreMetrics = struct {
    instruction_total: u32 = 0,
    branch_decision: u32 = 0,
    br_table_count: u32 = 0,
    br_table_targets: u32 = 0,
    call_local: u32 = 0,
    call_indirect: u32 = 0,
    call_import: u32 = 0,
    loop_backedge: u32 = 0,
};

const ScoreResult = struct {
    metrics: ScoreMetrics,
    jit_score: f64,
    interp_score: f64,
    recursion_cycle: bool,
    recursion_len: usize,
    recursion_defined_nodes: [MAX_DEFINED_FUNCS]u32,
    defined_func_base: u32,
};

const Writer = struct {
    idx: usize = 0,
    overflow: bool = false,

    fn writeByte(self: *Writer, b: u8) void {
        if (self.overflow) return;
        if (self.idx >= output_buf.len) {
            self.overflow = true;
            return;
        }
        output_buf[self.idx] = b;
        self.idx += 1;
    }

    fn writeSlice(self: *Writer, s: []const u8) void {
        if (self.overflow or s.len == 0) return;
        if (self.idx + s.len > output_buf.len) {
            self.overflow = true;
            return;
        }
        @memcpy(output_buf[self.idx..][0..s.len], s);
        self.idx += s.len;
    }

    fn writeFmt(self: *Writer, comptime fmt: []const u8, args: anytype) void {
        var tmp: [256]u8 = undefined;
        const rendered = std.fmt.bufPrint(&tmp, fmt, args) catch {
            self.overflow = true;
            return;
        };
        self.writeSlice(rendered);
    }
};

const Reader = struct {
    data: []const u8,
    off: usize = 0,

    fn init(data: []const u8) Reader {
        return .{ .data = data, .off = 0 };
    }

    fn remaining(self: *const Reader) usize {
        return self.data.len - self.off;
    }

    fn readByte(self: *Reader) ParseError!u8 {
        if (self.off >= self.data.len) return ParseError.UnexpectedEOF;
        const b = self.data[self.off];
        self.off += 1;
        return b;
    }

    fn peekByte(self: *const Reader) ParseError!u8 {
        if (self.off >= self.data.len) return ParseError.UnexpectedEOF;
        return self.data[self.off];
    }

    fn readN(self: *Reader, n: usize) ParseError![]const u8 {
        if (self.remaining() < n) return ParseError.UnexpectedEOF;
        const start = self.off;
        self.off += n;
        return self.data[start..self.off];
    }

    fn readVarU32(self: *Reader) ParseError!u32 {
        var result: u32 = 0;
        var shift: u5 = 0;
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const b = try self.readByte();
            result |= @as(u32, b & 0x7f) << shift;
            if ((b & 0x80) == 0) return result;
            shift += 7;
        }
        return ParseError.InvalidLEB;
    }

    fn readVarU64(self: *Reader) ParseError!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            const b = try self.readByte();
            result |= @as(u64, b & 0x7f) << shift;
            if ((b & 0x80) == 0) return result;
            shift += 7;
        }
        return ParseError.InvalidLEB;
    }

    fn readVarS32(self: *Reader) ParseError!i32 {
        var result: i32 = 0;
        var shift: u5 = 0;
        var i: usize = 0;
        var b: u8 = 0;
        while (i < 5) : (i += 1) {
            b = try self.readByte();
            result |= @as(i32, @intCast(b & 0x7f)) << shift;
            shift += 7;
            if ((b & 0x80) == 0) break;
            if (i == 4) return ParseError.InvalidLEB;
        }
        if (shift < 32 and (b & 0x40) != 0) {
            result |= ~@as(i32, 0) << shift;
        }
        return result;
    }

    fn readVarS64(self: *Reader, max_bytes: usize) ParseError!i64 {
        var result: i64 = 0;
        var shift: u6 = 0;
        var i: usize = 0;
        var b: u8 = 0;
        while (i < max_bytes) : (i += 1) {
            b = try self.readByte();
            result |= @as(i64, @intCast(b & 0x7f)) << shift;
            shift += 7;
            if ((b & 0x80) == 0) break;
            if (i == max_bytes - 1) return ParseError.InvalidLEB;
        }
        if (shift < 64 and (b & 0x40) != 0) {
            result |= ~@as(i64, 0) << shift;
        }
        return result;
    }

    fn readName(self: *Reader) ParseError![]const u8 {
        const n = try self.readVarU32();
        return self.readN(n);
    }
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

export fn output_utf8_cap() u32 {
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

fn computeScores(metrics: ScoreMetrics) struct { jit: f64, interp: f64 } {
    var jit: f64 = 0;
    var interp: f64 = 0;

    jit += @as(f64, @floatFromInt(metrics.instruction_total)) * score_instr_jit_weight;
    interp += @as(f64, @floatFromInt(metrics.instruction_total)) * score_instr_interp_weight;

    jit += @as(f64, @floatFromInt(metrics.branch_decision)) * score_branch_jit_weight;
    interp += @as(f64, @floatFromInt(metrics.branch_decision)) * score_branch_interp_weight;

    jit += @as(f64, @floatFromInt(metrics.br_table_count)) * score_br_table_jit_base;
    jit += @as(f64, @floatFromInt(metrics.br_table_targets)) * score_br_table_jit_per_target;

    interp += @as(f64, @floatFromInt(metrics.br_table_count)) * score_br_table_interp_base;
    interp += @as(f64, @floatFromInt(metrics.br_table_targets)) * score_br_table_interp_per_target;

    jit += @as(f64, @floatFromInt(metrics.call_local)) * score_call_local_jit_weight;
    interp += @as(f64, @floatFromInt(metrics.call_local)) * score_call_local_interp_weight;

    jit += @as(f64, @floatFromInt(metrics.call_indirect)) * score_call_indirect_jit_weight;
    interp += @as(f64, @floatFromInt(metrics.call_indirect)) * score_call_indirect_interp_weight;

    jit += @as(f64, @floatFromInt(metrics.call_import)) * score_call_import_jit_weight;
    interp += @as(f64, @floatFromInt(metrics.call_import)) * score_call_import_interp_weight;

    jit += @as(f64, @floatFromInt(metrics.loop_backedge)) * score_loop_backedge_jit_weight;
    interp += @as(f64, @floatFromInt(metrics.loop_backedge)) * score_loop_backedge_interp_weight;

    return .{ .jit = jit, .interp = interp };
}

fn formatScore(buf: *[32]u8, value: f64) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.2}", .{value}) catch "0.00";
}

fn initEdgeGraph(defined_funcs: usize) void {
    var i: usize = 0;
    while (i < defined_funcs) : (i += 1) {
        edge_head_buf[i] = -1;
    }
    edge_count = 0;
}

fn addEdge(src: u32, dst: u32) ParseError!void {
    if (edge_count >= MAX_CALL_EDGES) return ParseError.TooManyEdges;
    const idx = edge_count;
    edge_to_buf[idx] = dst;
    edge_next_buf[idx] = edge_head_buf[src];
    edge_head_buf[src] = @as(i32, @intCast(idx));
    edge_count += 1;
}

fn isLoopTarget(control_stack: []const u8, depth: u32) bool {
    const d: usize = @intCast(depth);
    if (d >= control_stack.len) return false;
    const target = control_stack[control_stack.len - 1 - d];
    return target == 0x03;
}

fn readBlockType(r: *Reader) ParseError!void {
    const b = try r.peekByte();
    switch (b) {
        0x40, 0x7f, 0x7e, 0x7d, 0x7c, 0x7b, 0x70, 0x6f => _ = try r.readByte(),
        else => _ = try r.readVarS64(5),
    }
}

fn readMemArg(r: *Reader) ParseError!void {
    _ = try r.readVarU32();
    _ = try r.readVarU32();
}

fn readFCImmediate(r: *Reader) ParseError!void {
    const sub = try r.readVarU32();
    switch (sub) {
        0 => {
            _ = try r.readVarU32();
            _ = try r.readVarU32();
        },
        1 => _ = try r.readVarU32(),
        2 => {
            _ = try r.readVarU32();
            _ = try r.readVarU32();
        },
        3 => _ = try r.readVarU32(),
        4 => {
            _ = try r.readVarU32();
            _ = try r.readVarU32();
        },
        5 => _ = try r.readVarU32(),
        6 => {
            _ = try r.readVarU32();
            _ = try r.readVarU32();
        },
        7, 8, 9 => _ = try r.readVarU32(),
        else => {},
    }
}

fn readFDImmediate(r: *Reader) ParseError!void {
    const sub = try r.readVarU32();
    switch (sub) {
        0...11 => try readMemArg(r),
        12, 13 => _ = try r.readN(16),
        21...34 => _ = try r.readByte(),
        84, 85 => try readMemArg(r),
        92...99 => {
            try readMemArg(r);
            _ = try r.readByte();
        },
        else => {},
    }
}

fn readFEImmediate(r: *Reader) ParseError!void {
    const sub = try r.readVarU32();
    if (sub == 3) {
        _ = try r.readByte();
        return;
    }
    try readMemArg(r);
}

fn skipLimits(r: *Reader) ParseError!void {
    const flags = try r.readByte();
    const is_memory64 = (flags & 0x04) != 0;
    if (is_memory64) {
        _ = try r.readVarU64();
        if ((flags & 0x01) != 0) {
            _ = try r.readVarU64();
        }
        return;
    }
    _ = try r.readVarU32();
    if ((flags & 0x01) != 0) {
        _ = try r.readVarU32();
    }
}

fn skipTableType(r: *Reader) ParseError!void {
    _ = try r.readByte();
    try skipLimits(r);
}

fn skipGlobalType(r: *Reader) ParseError!void {
    _ = try r.readByte();
    _ = try r.readByte();
}

fn parseTypeSection(payload: []const u8) ParseError!void {
    var r = Reader.init(payload);
    const n = try r.readVarU32();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const form = try r.readByte();
        if (form != 0x60) return ParseError.InvalidWasm;
        const params = try r.readVarU32();
        _ = try r.readN(params);
        const results = try r.readVarU32();
        _ = try r.readN(results);
    }
    if (r.remaining() != 0) return ParseError.TrailingBytes;
}

fn parseImportSection(payload: []const u8) ParseError!u32 {
    var r = Reader.init(payload);
    const n = try r.readVarU32();
    var i: u32 = 0;
    var func_imports: u32 = 0;
    while (i < n) : (i += 1) {
        _ = try r.readName();
        _ = try r.readName();
        const kind = try r.readByte();
        switch (kind) {
            0x00 => {
                _ = try r.readVarU32();
                func_imports += 1;
            },
            0x01 => try skipTableType(&r),
            0x02 => try skipLimits(&r),
            0x03 => try skipGlobalType(&r),
            0x04 => {
                _ = try r.readByte();
                _ = try r.readVarU32();
            },
            else => return ParseError.UnsupportedImportKind,
        }
    }
    if (r.remaining() != 0) return ParseError.TrailingBytes;
    return func_imports;
}

fn parseFunctionSection(payload: []const u8) ParseError!u32 {
    var r = Reader.init(payload);
    const n = try r.readVarU32();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        _ = try r.readVarU32();
    }
    if (r.remaining() != 0) return ParseError.TrailingBytes;
    return n;
}

fn parseFunctionBody(body: []const u8, func_idx: u32, imported_func_count: u32, defined_func_count: u32, metrics: *ScoreMetrics) ParseError!void {
    var r = Reader.init(body);

    const local_decls = try r.readVarU32();
    var ld: u32 = 0;
    while (ld < local_decls) : (ld += 1) {
        _ = try r.readVarU32();
        _ = try r.readByte();
    }

    var control_stack: [MAX_CONTROL_DEPTH]u8 = undefined;
    var control_len: usize = 0;

    while (true) {
        const op = try r.readByte();
        metrics.instruction_total += 1;

        switch (op) {
            0x00, 0x01, 0x05, 0x0f, 0x1a, 0x1b => {},
            0x02, 0x03, 0x04 => {
                try readBlockType(&r);
                if (op == 0x04) metrics.branch_decision += 1;
                if (control_len >= MAX_CONTROL_DEPTH) return ParseError.TooDeepControl;
                control_stack[control_len] = op;
                control_len += 1;
            },
            0x0b => {
                if (control_len == 0) {
                    if (r.remaining() != 0) return ParseError.TrailingBytes;
                    return;
                }
                control_len -= 1;
            },
            0x0c => {
                const depth = try r.readVarU32();
                if (isLoopTarget(control_stack[0..control_len], depth)) {
                    metrics.loop_backedge += 1;
                }
            },
            0x0d => {
                const depth = try r.readVarU32();
                metrics.branch_decision += 1;
                if (isLoopTarget(control_stack[0..control_len], depth)) {
                    metrics.loop_backedge += 1;
                }
            },
            0x0e => {
                const target_count = try r.readVarU32();
                metrics.br_table_count += 1;
                metrics.br_table_targets += target_count;

                var has_loop_target = false;
                var i: u32 = 0;
                while (i < target_count) : (i += 1) {
                    const depth = try r.readVarU32();
                    if (isLoopTarget(control_stack[0..control_len], depth)) {
                        has_loop_target = true;
                    }
                }
                const default_depth = try r.readVarU32();
                if (isLoopTarget(control_stack[0..control_len], default_depth)) {
                    has_loop_target = true;
                }
                if (has_loop_target) metrics.loop_backedge += 1;
            },
            0x10, 0x12 => {
                const idx = try r.readVarU32();
                if (idx < imported_func_count) {
                    metrics.call_import += 1;
                } else {
                    metrics.call_local += 1;
                    const callee = idx - imported_func_count;
                    if (callee < defined_func_count) {
                        try addEdge(func_idx, callee);
                    }
                }
            },
            0x11, 0x13 => {
                _ = try r.readVarU32();
                _ = try r.readVarU32();
                metrics.call_indirect += 1;
            },
            0x14 => {
                _ = try r.readVarU32();
                metrics.call_indirect += 1;
            },
            0x1c => {
                const count = try r.readVarU32();
                _ = try r.readN(count);
            },
            0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26 => _ = try r.readVarU32(),
            0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f,
            0x30, 0x31, 0x32, 0x33, 0x34, 0x35,
            0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e => try readMemArg(&r),
            0x3f, 0x40 => _ = try r.readVarU32(),
            0x41 => _ = try r.readVarS32(),
            0x42 => _ = try r.readVarS64(10),
            0x43 => _ = try r.readN(4),
            0x44 => _ = try r.readN(8),
            0xd0 => _ = try r.readByte(),
            0xd2 => _ = try r.readVarU32(),
            0xfc => try readFCImmediate(&r),
            0xfd => try readFDImmediate(&r),
            0xfe => try readFEImmediate(&r),
            else => {},
        }
    }
}

fn parseCodeSection(payload: []const u8, imported_func_count: u32, defined_func_count: u32, metrics: *ScoreMetrics) ParseError!void {
    if (defined_func_count > MAX_DEFINED_FUNCS) return ParseError.TooManyFunctions;

    initEdgeGraph(defined_func_count);

    var r = Reader.init(payload);
    const n = try r.readVarU32();
    if (n != defined_func_count) return ParseError.FunctionCodeMismatch;

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const body_size = try r.readVarU32();
        const body = try r.readN(body_size);
        try parseFunctionBody(body, i, imported_func_count, defined_func_count, metrics);
    }

    if (r.remaining() != 0) return ParseError.TrailingBytes;
}

fn dfsVisit(v: u32, defined_func_count: u32, stack_len: *usize, cycle_len: *usize) bool {
    dfs_state_buf[v] = 1;
    dfs_stack_buf[stack_len.*] = v;
    stack_len.* += 1;

    var e = edge_head_buf[v];
    while (e != -1) {
        const ei: usize = @intCast(e);
        const to = edge_to_buf[ei];
        if (to < defined_func_count) {
            if (dfs_state_buf[to] == 0) {
                if (dfsVisit(to, defined_func_count, stack_len, cycle_len)) return true;
            } else if (dfs_state_buf[to] == 1) {
                var start: usize = 0;
                var i = stack_len.*;
                while (i > 0) {
                    i -= 1;
                    if (dfs_stack_buf[i] == to) {
                        start = i;
                        break;
                    }
                }
                cycle_len.* = stack_len.* - start;
                var j: usize = 0;
                while (j < cycle_len.*) : (j += 1) {
                    cycle_buf[j] = dfs_stack_buf[start + j];
                }
                return true;
            }
        }
        e = edge_next_buf[ei];
    }

    stack_len.* -= 1;
    dfs_state_buf[v] = 2;
    return false;
}

fn sortU32(slice: []u32) void {
    var i: usize = 1;
    while (i < slice.len) : (i += 1) {
        const key = slice[i];
        var j: usize = i;
        while (j > 0 and slice[j - 1] > key) : (j -= 1) {
            slice[j] = slice[j - 1];
        }
        slice[j] = key;
    }
}

fn detectCallCycle(defined_func_count: u32) struct { has_cycle: bool, cycle_len: usize } {
    var i: usize = 0;
    while (i < defined_func_count) : (i += 1) {
        dfs_state_buf[i] = 0;
    }

    var stack_len: usize = 0;
    var cycle_len: usize = 0;

    i = 0;
    while (i < defined_func_count) : (i += 1) {
        if (dfs_state_buf[i] == 0) {
            if (dfsVisit(@intCast(i), defined_func_count, &stack_len, &cycle_len)) {
                sortU32(cycle_buf[0..cycle_len]);
                return .{ .has_cycle = true, .cycle_len = cycle_len };
            }
        }
    }

    return .{ .has_cycle = false, .cycle_len = 0 };
}

fn analyzeModule(wasm: []const u8) ParseError!ScoreResult {
    if (wasm.len < 8) return ParseError.InvalidWasm;
    if (!(wasm[0] == 0x00 and wasm[1] == 0x61 and wasm[2] == 0x73 and wasm[3] == 0x6d)) {
        return ParseError.InvalidWasm;
    }
    if (!(wasm[4] == 0x01 and wasm[5] == 0x00 and wasm[6] == 0x00 and wasm[7] == 0x00)) {
        return ParseError.UnsupportedVersion;
    }

    var r = Reader.init(wasm[8..]);
    var imported_func_count: u32 = 0;
    var defined_func_count: u32 = 0;
    var have_function_section = false;
    var have_code_section = false;
    var metrics = ScoreMetrics{};

    while (r.remaining() > 0) {
        const section_id = try r.readByte();
        const section_size = try r.readVarU32();
        const payload = try r.readN(section_size);

        switch (section_id) {
            0 => {},
            1 => try parseTypeSection(payload),
            2 => imported_func_count = try parseImportSection(payload),
            3 => {
                defined_func_count = try parseFunctionSection(payload);
                have_function_section = true;
            },
            10 => {
                try parseCodeSection(payload, imported_func_count, defined_func_count, &metrics);
                have_code_section = true;
            },
            else => {},
        }
    }

    if (have_function_section and !have_code_section) return ParseError.InvalidWasm;

    const scores = computeScores(metrics);
    const cycle = detectCallCycle(defined_func_count);

    var recursion_nodes: [MAX_DEFINED_FUNCS]u32 = undefined;
    var i: usize = 0;
    while (i < cycle.cycle_len) : (i += 1) {
        recursion_nodes[i] = cycle_buf[i];
    }

    return .{
        .metrics = metrics,
        .jit_score = scores.jit,
        .interp_score = scores.interp,
        .recursion_cycle = cycle.has_cycle,
        .recursion_len = cycle.cycle_len,
        .recursion_defined_nodes = recursion_nodes,
        .defined_func_base = imported_func_count,
    };
}

fn writeU32List(w: *Writer, list: []const u32) void {
    w.writeByte('[');
    for (list, 0..) |v, i| {
        if (i > 0) w.writeSlice(", ");
        w.writeFmt("{d}", .{v});
    }
    w.writeByte(']');
}

fn renderScore(result: ScoreResult, w: *Writer) void {
    var jit_buf: [32]u8 = undefined;
    var interp_buf: [32]u8 = undefined;
    const jit = formatScore(&jit_buf, result.jit_score);
    const interp = formatScore(&interp_buf, result.interp_score);

    w.writeSlice("JIT  INTERPRETED  STATUS\n");
    if (result.recursion_cycle) {
        w.writeSlice("FAIL  FAIL  FAIL(recursion)\n\n");
    } else {
        w.writeFmt("{s}  {s}  OK\n\n", .{ jit, interp });
    }

    w.writeFmt("  instr_total: {d}\n", .{result.metrics.instruction_total});
    w.writeFmt("  branch_decisions (br_if + if): {d}\n", .{result.metrics.branch_decision});
    w.writeFmt("  br_table_count: {d}\n", .{result.metrics.br_table_count});
    w.writeFmt("  br_table_targets: {d}\n", .{result.metrics.br_table_targets});
    w.writeFmt("  call_local: {d}\n", .{result.metrics.call_local});
    w.writeFmt("  call_indirect: {d}\n", .{result.metrics.call_indirect});
    w.writeFmt("  call_import: {d}\n", .{result.metrics.call_import});
    w.writeFmt("  loop_backedge: {d}\n", .{result.metrics.loop_backedge});

    if (result.recursion_cycle) {
        w.writeSlice("  recursion: FAIL (defined functions=");
        writeU32List(w, result.recursion_defined_nodes[0..result.recursion_len]);
        w.writeSlice(", global indices=");

        var global_nodes: [MAX_DEFINED_FUNCS]u32 = undefined;
        var i: usize = 0;
        while (i < result.recursion_len) : (i += 1) {
            global_nodes[i] = result.defined_func_base + result.recursion_defined_nodes[i];
        }
        writeU32List(w, global_nodes[0..result.recursion_len]);
        w.writeSlice(")\n");
        return;
    }

    w.writeFmt("  score_jit: {s}\n", .{jit});
    w.writeFmt("  score_interp: {s}\n", .{interp});
    w.writeFmt("  range: [{s}, {s}]\n", .{ jit, interp });
}

export fn run(input_size: u32) u32 {
    const input_len: usize = @intCast(input_size);
    if (input_len > INPUT_CAP) @trap();

    const result = analyzeModule(input_buf[0..input_len]) catch @trap();

    var w = Writer{};
    renderScore(result, &w);
    if (w.overflow) @trap();
    return @as(u32, @intCast(w.idx));
}

fn runForTest(input: []const u8) []const u8 {
    if (input.len > INPUT_CAP) @trap();
    @memcpy(input_buf[0..input.len], input);
    const out_len = run(@intCast(input.len));
    return output_buf[0..out_len];
}

fn testModuleCounts() []const u8 {
    return &[_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x02, 0x0c, 0x01, 0x03, 'e', 'n', 'v', 0x04, 'i', 'm', 'p', '0', 0x00, 0x00,
        0x03, 0x03, 0x02, 0x00, 0x00,
        0x04, 0x04, 0x01, 0x70, 0x00, 0x01,
        0x0a, 0x21, 0x02,
        0x1b, 0x00,
        0x03, 0x40,
        0x0d, 0x00,
        0x0b,
        0x04, 0x40,
        0x0b,
        0x02, 0x40,
        0x41, 0x00,
        0x0e, 0x02, 0x00, 0x00, 0x00,
        0x0b,
        0x10, 0x00,
        0x10, 0x02,
        0x11, 0x00, 0x00,
        0x0b,
        0x02, 0x00, 0x0b,
    };
}

fn testModuleRecursion() []const u8 {
    return &[_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x03, 0x03, 0x02, 0x00, 0x00,
        0x0a, 0x0b, 0x02,
        0x04, 0x00, 0x10, 0x01, 0x0b,
        0x04, 0x00, 0x10, 0x00, 0x0b,
    };
}

test "analyzes and renders expected scores" {
    const input = testModuleCounts();
    const out = runForTest(input);
    try std.testing.expect(std.mem.indexOf(u8, out, "JIT  INTERPRETED  STATUS") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "44.98") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "116.68") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "  call_import: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "  loop_backedge: 1") != null);
}

test "reports recursion failure" {
    const input = testModuleRecursion();
    const out = runForTest(input);
    try std.testing.expect(std.mem.indexOf(u8, out, "FAIL(recursion)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "recursion: FAIL") != null);
}
