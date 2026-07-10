const std = @import("std");

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP;
const MAX_DEFINED_FUNCS: usize = 8192;
const MAX_CALL_EDGES: usize = 262144;
const MAX_CONTROL_DEPTH: usize = 4096;
const MAX_LOOP_EVIDENCE: usize = 4096;
const MAX_LOOP_COUNTERS: usize = 16384;
const MAX_RECENT_INSTR: usize = 8;
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
var loop_has_backedge_buf: [MAX_LOOP_EVIDENCE]bool = undefined;
var loop_counter_head_buf: [MAX_LOOP_EVIDENCE]i32 = undefined;
var loop_counter_local_buf: [MAX_LOOP_COUNTERS]u32 = undefined;
var loop_counter_update_buf: [MAX_LOOP_COUNTERS]u8 = undefined;
var loop_counter_exit_buf: [MAX_LOOP_COUNTERS]u8 = undefined;
var loop_counter_next_buf: [MAX_LOOP_COUNTERS]i32 = undefined;
var loop_count_current: usize = 0;
var loop_counter_count: usize = 0;

const DIR_INC: u8 = 1;
const DIR_DEC: u8 = 2;

const ControlFrame = struct {
    op: u8,
    loop_idx: i32,
};

const InstrTrace = struct {
    op: u8 = 0,
    imm: i64 = 0,
    has_imm: bool = false,
};

const BoundCandidate = struct {
    local: u32,
    direction: u8,
};

const BoundCandidates = struct {
    items: [2]BoundCandidate = undefined,
    len: usize = 0,
};

const CheckError = error{
    InvalidWasm,
    UnsupportedVersion,
    UnexpectedEOF,
    InvalidLEB,
    TrailingBytes,
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
    TooDeepControl,
    TooManyLoops,
    TooManyLoopCounters,
    LoopBoundNotProven,
    UnsupportedImportKind,
    UnsupportedInstruction,
};

const Reader = struct {
    data: []const u8,
    off: usize = 0,

    fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    fn remaining(self: *const Reader) usize {
        return self.data.len - self.off;
    }

    fn readByte(self: *Reader) CheckError!u8 {
        if (self.off >= self.data.len) return CheckError.UnexpectedEOF;
        const b = self.data[self.off];
        self.off += 1;
        return b;
    }

    fn peekByte(self: *const Reader) CheckError!u8 {
        if (self.off >= self.data.len) return CheckError.UnexpectedEOF;
        return self.data[self.off];
    }

    fn readN(self: *Reader, n: usize) CheckError![]const u8 {
        if (self.remaining() < n) return CheckError.UnexpectedEOF;
        const start = self.off;
        self.off += n;
        return self.data[start..self.off];
    }

    fn readVarU32(self: *Reader) CheckError!u32 {
        var result: u32 = 0;
        var shift: u5 = 0;
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const b = try self.readByte();
            result |= @as(u32, b & 0x7f) << shift;
            if ((b & 0x80) == 0) return result;
            shift += 7;
        }
        return CheckError.InvalidLEB;
    }

    fn readVarU64(self: *Reader) CheckError!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            const b = try self.readByte();
            result |= @as(u64, b & 0x7f) << shift;
            if ((b & 0x80) == 0) return result;
            shift += 7;
        }
        return CheckError.InvalidLEB;
    }

    fn readVarS32(self: *Reader) CheckError!i32 {
        var result: i32 = 0;
        var shift: u5 = 0;
        var i: usize = 0;
        var b: u8 = 0;
        while (i < 5) : (i += 1) {
            b = try self.readByte();
            result |= @as(i32, @intCast(b & 0x7f)) << shift;
            shift += 7;
            if ((b & 0x80) == 0) break;
            if (i == 4) return CheckError.InvalidLEB;
        }
        if (shift < 32 and (b & 0x40) != 0) {
            result |= ~@as(i32, 0) << shift;
        }
        return result;
    }

    fn readVarS64(self: *Reader, max_bytes: usize) CheckError!i64 {
        var result: i64 = 0;
        var shift: u6 = 0;
        var i: usize = 0;
        var b: u8 = 0;
        while (i < max_bytes) : (i += 1) {
            b = try self.readByte();
            result |= @as(i64, @intCast(b & 0x7f)) << shift;
            shift += 7;
            if ((b & 0x80) == 0) break;
            if (i == max_bytes - 1) return CheckError.InvalidLEB;
        }
        if (shift < 64 and (b & 0x40) != 0) {
            result |= ~@as(i64, 0) << shift;
        }
        return result;
    }

    fn readName(self: *Reader) CheckError![]const u8 {
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

fn initLoopEvidence() void {
    loop_count_current = 0;
    loop_counter_count = 0;
}

fn addLoopEvidence() CheckError!u32 {
    if (loop_count_current >= MAX_LOOP_EVIDENCE) return CheckError.TooManyLoops;
    const idx = loop_count_current;
    loop_has_backedge_buf[idx] = false;
    loop_counter_head_buf[idx] = -1;
    loop_count_current += 1;
    return @intCast(idx);
}

fn findLoopCounter(loop_idx: u32, local: u32) ?usize {
    var edge = loop_counter_head_buf[loop_idx];
    while (edge != -1) {
        const i: usize = @intCast(edge);
        if (loop_counter_local_buf[i] == local) return i;
        edge = loop_counter_next_buf[i];
    }
    return null;
}

fn loopCounterSlot(loop_idx: u32, local: u32) CheckError!usize {
    if (findLoopCounter(loop_idx, local)) |idx| return idx;
    if (loop_counter_count >= MAX_LOOP_COUNTERS) return CheckError.TooManyLoopCounters;
    const idx = loop_counter_count;
    loop_counter_local_buf[idx] = local;
    loop_counter_update_buf[idx] = 0;
    loop_counter_exit_buf[idx] = 0;
    loop_counter_next_buf[idx] = loop_counter_head_buf[loop_idx];
    loop_counter_head_buf[loop_idx] = @intCast(idx);
    loop_counter_count += 1;
    return idx;
}

fn markLoopCounterUpdate(loop_idx: u32, local: u32, direction: u8) CheckError!void {
    if (direction == 0) return;
    const idx = try loopCounterSlot(loop_idx, local);
    loop_counter_update_buf[idx] |= direction;
}

fn markLoopCounterExit(loop_idx: u32, candidate: BoundCandidate) CheckError!void {
    if (candidate.direction == 0) return;
    const idx = try loopCounterSlot(loop_idx, candidate.local);
    loop_counter_exit_buf[idx] |= candidate.direction;
}

fn loopHasBoundedCounter(loop_idx: u32) bool {
    var edge = loop_counter_head_buf[loop_idx];
    while (edge != -1) {
        const i: usize = @intCast(edge);
        if ((loop_counter_update_buf[i] & loop_counter_exit_buf[i]) != 0) return true;
        edge = loop_counter_next_buf[i];
    }
    return false;
}

fn appendTrace(recent: *[MAX_RECENT_INSTR]InstrTrace, recent_len: *usize, instr: InstrTrace) void {
    if (recent_len.* < MAX_RECENT_INSTR) {
        recent[recent_len.*] = instr;
        recent_len.* += 1;
        return;
    }
    var i: usize = 1;
    while (i < MAX_RECENT_INSTR) : (i += 1) {
        recent[i - 1] = recent[i];
    }
    recent[MAX_RECENT_INSTR - 1] = instr;
}

fn traceLocalGet(t: InstrTrace) ?u32 {
    if (t.op != 0x20 or !t.has_imm or t.imm < 0) return null;
    return @intCast(t.imm);
}

fn traceI32Const(t: InstrTrace) ?i32 {
    if (t.op != 0x41 or !t.has_imm) return null;
    return @intCast(t.imm);
}

fn counterDirection(op: u8, delta: i32) ?u8 {
    if (delta == 0) return null;
    switch (op) {
        0x6a => return if (delta > 0) DIR_INC else DIR_DEC,
        0x6b => return if (delta > 0) DIR_DEC else DIR_INC,
        else => return null,
    }
}

fn detectCounterUpdate(recent: []const InstrTrace, set_local: u32) ?u8 {
    if (recent.len < 3) return null;
    const a = recent[recent.len - 3];
    const b = recent[recent.len - 2];
    const op = recent[recent.len - 1];
    if (op.op != 0x6a and op.op != 0x6b) return null;

    if (traceLocalGet(a)) |local| {
        if (local == set_local) {
            if (traceI32Const(b)) |delta| return counterDirection(op.op, delta);
        }
    }
    if (op.op == 0x6a) {
        if (traceI32Const(a)) |delta| {
            if (traceLocalGet(b)) |local| {
                if (local == set_local) return counterDirection(op.op, delta);
            }
        }
    }
    return null;
}

fn isI32Compare(op: u8) bool {
    return switch (op) {
        0x46, 0x47, 0x48, 0x49, 0x4b, 0x4d, 0x4f => true,
        else => false,
    };
}

fn pushCandidate(out: *BoundCandidates, local: u32, direction: u8) void {
    if (direction == 0 or out.len >= out.items.len) return;
    out.items[out.len] = .{ .local = local, .direction = direction };
    out.len += 1;
}

fn chooseBoundDirection(exit_direction: u8, branch_back: bool) u8 {
    if (!branch_back) return exit_direction;
    return switch (exit_direction) {
        DIR_INC => DIR_DEC,
        DIR_DEC => DIR_INC,
        else => exit_direction,
    };
}

fn compareLocalConstBoundCandidates(op: u8, local: u32, local_on_right: bool, branch_back: bool) BoundCandidates {
    var out = BoundCandidates{};
    if (local_on_right) {
        switch (op) {
            0x46, 0x47 => pushCandidate(&out, local, DIR_INC | DIR_DEC),
            0x4f, 0x4b => pushCandidate(&out, local, chooseBoundDirection(DIR_DEC, branch_back)),
            0x4d, 0x49 => pushCandidate(&out, local, chooseBoundDirection(DIR_INC, branch_back)),
            else => {},
        }
        return out;
    }
    switch (op) {
        0x46, 0x47 => pushCandidate(&out, local, DIR_INC | DIR_DEC),
        0x4f, 0x4b => pushCandidate(&out, local, chooseBoundDirection(DIR_INC, branch_back)),
        0x4d, 0x49 => pushCandidate(&out, local, chooseBoundDirection(DIR_DEC, branch_back)),
        else => {},
    }
    return out;
}

fn compareBoundCandidates(op: u8, left: u32, right: u32, branch_back: bool) BoundCandidates {
    var out = BoundCandidates{};
    switch (op) {
        0x46, 0x47 => {
            pushCandidate(&out, left, DIR_INC | DIR_DEC);
            pushCandidate(&out, right, DIR_INC | DIR_DEC);
        },
        0x4f, 0x4b => {
            pushCandidate(&out, left, chooseBoundDirection(DIR_INC, branch_back));
            pushCandidate(&out, right, chooseBoundDirection(DIR_DEC, branch_back));
        },
        0x4d, 0x49 => {
            pushCandidate(&out, left, chooseBoundDirection(DIR_DEC, branch_back));
            pushCandidate(&out, right, chooseBoundDirection(DIR_INC, branch_back));
        },
        else => {},
    }
    return out;
}

fn detectBoundCandidates(recent: []const InstrTrace, branch_back: bool) BoundCandidates {
    var out = BoundCandidates{};
    if (recent.len < 2) return out;

    const last = recent[recent.len - 1];
    const prev = recent[recent.len - 2];
    if (last.op == 0x45) {
        if (branch_back) return out;
        if (traceLocalGet(prev)) |local| pushCandidate(&out, local, DIR_DEC);
        return out;
    }
    if (!isI32Compare(last.op)) return out;

    if (recent.len >= 3) {
        const left = recent[recent.len - 3];
        const right = recent[recent.len - 2];
        if (traceLocalGet(left)) |left_local| {
            if (traceLocalGet(right)) |right_local| return compareBoundCandidates(last.op, left_local, right_local, branch_back);
            if (traceI32Const(right) != null) return compareLocalConstBoundCandidates(last.op, left_local, false, branch_back);
        }
        if (traceLocalGet(right)) |right_local| {
            if (traceI32Const(left) != null) return compareLocalConstBoundCandidates(last.op, right_local, true, branch_back);
        }
    }

    if (recent.len >= 6 and recent[recent.len - 2].op == 0x22) {
        const local: u32 = @intCast(recent[recent.len - 2].imm);
        if (traceLocalGet(recent[recent.len - 6]) != null) {
            if (detectCounterUpdate(recent[0 .. recent.len - 2], local)) |dir| {
                pushCandidate(&out, local, dir);
                return out;
            }
        }
    }
    if (recent.len >= 6 and recent[recent.len - 3].op == 0x22) {
        const local: u32 = @intCast(recent[recent.len - 3].imm);
        if (traceLocalGet(recent[recent.len - 2]) != null) {
            if (detectCounterUpdate(recent[0 .. recent.len - 3], local)) |dir| {
                pushCandidate(&out, local, dir);
                return out;
            }
        }
    }

    return out;
}

fn markActiveLoopCounterUpdate(control_stack: []const ControlFrame, local: u32, direction: u8) CheckError!void {
    if (direction == 0) return;
    for (control_stack) |frame| {
        if (frame.op != 0x03 or frame.loop_idx < 0) continue;
        try markLoopCounterUpdate(@intCast(frame.loop_idx), local, direction);
    }
}

fn markBranchLoopEvidence(control_stack: []const ControlFrame, depth: u32, exit_candidates: BoundCandidates, continue_candidates: BoundCandidates) CheckError!void {
    if (depth >= control_stack.len) return;
    const target_index = control_stack.len - 1 - @as(usize, @intCast(depth));
    const target = control_stack[target_index];
    if (target.op == 0x03) {
        if (target.loop_idx >= 0) {
            const loop_idx: u32 = @intCast(target.loop_idx);
            loop_has_backedge_buf[loop_idx] = true;
            var i: usize = 0;
            while (i < continue_candidates.len) : (i += 1) try markLoopCounterExit(loop_idx, continue_candidates.items[i]);
        }
        return;
    }

    var i = control_stack.len;
    while (i > target_index + 1) {
        i -= 1;
        const frame = control_stack[i];
        if (frame.op != 0x03 or frame.loop_idx < 0) continue;
        const loop_idx: u32 = @intCast(frame.loop_idx);
        var j: usize = 0;
        while (j < exit_candidates.len) : (j += 1) try markLoopCounterExit(loop_idx, exit_candidates.items[j]);
    }
}

fn isLoopTarget(control_stack: []const ControlFrame, depth: u32) bool {
    if (depth >= control_stack.len) return false;
    const target = control_stack[control_stack.len - 1 - @as(usize, @intCast(depth))];
    return target.op == 0x03;
}

fn readBlockType(r: *Reader) CheckError!void {
    const b = try r.peekByte();
    switch (b) {
        0x40, 0x7f, 0x7e, 0x7d, 0x7c, 0x7b, 0x70, 0x6f => _ = try r.readByte(),
        else => _ = try r.readVarS64(5),
    }
}

fn readMemArg(r: *Reader) CheckError!void {
    _ = try r.readVarU32();
    _ = try r.readVarU32();
}

fn readFCImmediate(r: *Reader) CheckError!void {
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

fn readFDImmediate(r: *Reader) CheckError!void {
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

fn skipLimitsAndCheckMemory(r: *Reader) CheckError!void {
    const flags = try r.readByte();
    if ((flags & 0x04) != 0) return CheckError.Memory64NotAllowed;
    if ((flags & 0x02) != 0) return CheckError.SharedMemoryNotAllowed;
    _ = try r.readVarU32();
    if ((flags & 0x01) == 0) return CheckError.MemoryMaxRequired;
    _ = try r.readVarU32();
}

fn skipLimits(r: *Reader) CheckError!void {
    const flags = try r.readByte();
    const is_memory64 = (flags & 0x04) != 0;
    if (is_memory64) {
        _ = try r.readVarU64();
        if ((flags & 0x01) != 0) _ = try r.readVarU64();
        return;
    }
    _ = try r.readVarU32();
    if ((flags & 0x01) != 0) _ = try r.readVarU32();
}

fn skipTableType(r: *Reader) CheckError!void {
    _ = try r.readByte();
    try skipLimits(r);
}

fn skipGlobalType(r: *Reader) CheckError!void {
    _ = try r.readByte();
    _ = try r.readByte();
}

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
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        _ = try r.readName();
        _ = try r.readName();
        const kind = try r.readByte();
        switch (kind) {
            0x00 => _ = try r.readVarU32(),
            0x01 => try skipTableType(&r),
            0x02 => try skipLimitsAndCheckMemory(&r),
            0x03 => try skipGlobalType(&r),
            0x04 => {
                _ = try r.readByte();
                _ = try r.readVarU32();
            },
            else => return CheckError.UnsupportedImportKind,
        }
        return CheckError.ImportNotAllowed;
    }
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

fn parseMemorySection(payload: []const u8) CheckError!u32 {
    var r = Reader.init(payload);
    const n = try r.readVarU32();
    if (n > 1) return CheckError.TooManyMemories;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        try skipLimitsAndCheckMemory(&r);
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
    return n;
}

fn parseFunctionBody(body: []const u8, func_idx: u32, imported_func_count: u32, defined_func_count: u32) CheckError!void {
    initLoopEvidence();
    var r = Reader.init(body);

    const local_decls = try r.readVarU32();
    var ld: u32 = 0;
    while (ld < local_decls) : (ld += 1) {
        _ = try r.readVarU32();
        _ = try r.readByte();
    }

    var control_stack: [MAX_CONTROL_DEPTH]ControlFrame = undefined;
    var control_len: usize = 0;
    var recent: [MAX_RECENT_INSTR]InstrTrace = undefined;
    var recent_len: usize = 0;

    while (true) {
        const op = try r.readByte();
        var trace = InstrTrace{ .op = op };
        switch (op) {
            0x00, 0x01, 0x05, 0x0f, 0x1a, 0x1b => {},
            0x02, 0x03, 0x04 => {
                try readBlockType(&r);
                if (control_len >= MAX_CONTROL_DEPTH) return CheckError.TooDeepControl;
                var loop_idx: i32 = -1;
                if (op == 0x03) loop_idx = @intCast(try addLoopEvidence());
                control_stack[control_len] = .{ .op = op, .loop_idx = loop_idx };
                control_len += 1;
            },
            0x0b => {
                if (control_len == 0) {
                    if (r.remaining() != 0) return CheckError.TrailingBytes;
                    return;
                }
                const frame = control_stack[control_len - 1];
                control_len -= 1;
                if (frame.op == 0x03 and frame.loop_idx >= 0) {
                    const loop_idx: u32 = @intCast(frame.loop_idx);
                    if (loop_has_backedge_buf[loop_idx] and !loopHasBoundedCounter(loop_idx)) {
                        return CheckError.LoopBoundNotProven;
                    }
                }
            },
            0x0c => {
                const depth = try r.readVarU32();
                trace.imm = depth;
                trace.has_imm = true;
                try markBranchLoopEvidence(control_stack[0..control_len], depth, BoundCandidates{}, BoundCandidates{});
            },
            0x0d => {
                const depth = try r.readVarU32();
                trace.imm = depth;
                trace.has_imm = true;
                const exit_candidates = detectBoundCandidates(recent[0..recent_len], false);
                const continue_candidates = detectBoundCandidates(recent[0..recent_len], true);
                try markBranchLoopEvidence(control_stack[0..control_len], depth, exit_candidates, continue_candidates);
            },
            0x0e => {
                const target_count = try r.readVarU32();
                trace.imm = target_count;
                trace.has_imm = true;
                const exit_candidates = detectBoundCandidates(recent[0..recent_len], false);
                const continue_candidates = detectBoundCandidates(recent[0..recent_len], true);
                var i: u32 = 0;
                while (i < target_count) : (i += 1) {
                    const depth = try r.readVarU32();
                    try markBranchLoopEvidence(control_stack[0..control_len], depth, exit_candidates, continue_candidates);
                }
                const default_depth = try r.readVarU32();
                try markBranchLoopEvidence(control_stack[0..control_len], default_depth, exit_candidates, continue_candidates);
            },
            0x10, 0x12 => {
                const idx = try r.readVarU32();
                trace.imm = idx;
                trace.has_imm = true;
                if (idx < imported_func_count) return CheckError.ImportNotAllowed;
                const callee = idx - imported_func_count;
                if (callee < defined_func_count) try addEdge(func_idx, callee);
            },
            0x11, 0x13 => return CheckError.IndirectCallNotAllowed,
            0x14 => {
                _ = try r.readVarU32();
                return CheckError.IndirectCallNotAllowed;
            },
            0x1c => {
                const count = try r.readVarU32();
                _ = try r.readN(count);
            },
            0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26 => {
                const idx = try r.readVarU32();
                trace.imm = idx;
                trace.has_imm = true;
                if (op == 0x21 or op == 0x22) {
                    if (detectCounterUpdate(recent[0..recent_len], idx)) |dir| {
                        try markActiveLoopCounterUpdate(control_stack[0..control_len], idx, dir);
                    }
                }
            },
            0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f,
            0x30, 0x31, 0x32, 0x33, 0x34, 0x35,
            0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e => try readMemArg(&r),
            0x3f => _ = try r.readVarU32(),
            0x40 => return CheckError.MemoryGrowNotAllowed,
            0x41 => {
                const value = try r.readVarS32();
                trace.imm = value;
                trace.has_imm = true;
            },
            0x42 => _ = try r.readVarS64(10),
            0x43 => _ = try r.readN(4),
            0x44 => _ = try r.readN(8),
            0x45...0xbf => {},
            0xd0 => _ = try r.readByte(),
            0xd1 => {},
            0xd2 => _ = try r.readVarU32(),
            0xfc => try readFCImmediate(&r),
            0xfd => try readFDImmediate(&r),
            0xfe => return CheckError.AtomicsNotAllowed,
            else => return CheckError.UnsupportedInstruction,
        }
        appendTrace(&recent, &recent_len, trace);
    }
}

fn parseCodeSection(payload: []const u8, imported_func_count: u32, defined_func_count: u32) CheckError!void {
    if (defined_func_count > MAX_DEFINED_FUNCS) return CheckError.TooManyFunctions;
    initEdgeGraph(defined_func_count);

    var r = Reader.init(payload);
    const n = try r.readVarU32();
    if (n != defined_func_count) return CheckError.FunctionCodeMismatch;

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const body_size = try r.readVarU32();
        const body = try r.readN(body_size);
        try parseFunctionBody(body, i, imported_func_count, defined_func_count);
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
}

fn checkModule(wasm: []const u8) CheckError!void {
    if (wasm.len < 8) return CheckError.InvalidWasm;
    if (!(wasm[0] == 0x00 and wasm[1] == 0x61 and wasm[2] == 0x73 and wasm[3] == 0x6d)) {
        return CheckError.InvalidWasm;
    }
    if (!(wasm[4] == 0x01 and wasm[5] == 0x00 and wasm[6] == 0x00 and wasm[7] == 0x00)) {
        return CheckError.UnsupportedVersion;
    }

    var r = Reader.init(wasm[8..]);
    const imported_func_count: u32 = 0;
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
            5 => _ = try parseMemorySection(payload),
            10 => {
                try parseCodeSection(payload, imported_func_count, defined_func_count);
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

fn okModule() []const u8 {
    return &[_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x00,
        0x05, 0x04, 0x01, 0x01, 0x01, 0x01,
        0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
    };
}

fn noMemoryMaxModule() []const u8 {
    return &[_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x05, 0x03, 0x01, 0x00, 0x01,
    };
}

fn recursionModule() []const u8 {
    return &[_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x03, 0x03, 0x02, 0x00, 0x00,
        0x05, 0x04, 0x01, 0x01, 0x01, 0x01,
        0x0a, 0x0b, 0x02,
        0x04, 0x00, 0x10, 0x01, 0x0b,
        0x04, 0x00, 0x10, 0x00, 0x0b,
    };
}

fn memoryGrowModule() []const u8 {
    return &[_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
        0x03, 0x02, 0x01, 0x00,
        0x05, 0x04, 0x01, 0x01, 0x01, 0x01,
        0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x00, 0x40, 0x00, 0x0b,
    };
}

test "accepts a module with fixed memory and no calls" {
    try checkModule(okModule());
}

test "requires memory max when memory is declared" {
    try std.testing.expectError(CheckError.MemoryMaxRequired, checkModule(noMemoryMaxModule()));
}

test "rejects direct recursion" {
    try std.testing.expectError(CheckError.RecursionNotAllowed, checkModule(recursionModule()));
}

test "rejects memory.grow" {
    try std.testing.expectError(CheckError.MemoryGrowNotAllowed, checkModule(memoryGrowModule()));
}
