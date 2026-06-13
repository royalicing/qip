const std = @import("std");

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP;
const MAX_DEFINED_FUNCS: usize = 8192;
const MAX_CALL_EDGES: usize = 262144;
const MAX_CONTROL_DEPTH: usize = 4096;
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
        switch (op) {
            0x00, 0x01, 0x05, 0x0f, 0x1a, 0x1b => {},
            0x02, 0x03, 0x04 => {
                try readBlockType(&r);
                if (control_len >= MAX_CONTROL_DEPTH) return CheckError.TooDeepControl;
                control_stack[control_len] = op;
                control_len += 1;
            },
            0x0b => {
                if (control_len == 0) {
                    if (r.remaining() != 0) return CheckError.TrailingBytes;
                    return;
                }
                control_len -= 1;
            },
            0x0c, 0x0d => _ = try r.readVarU32(),
            0x0e => {
                const target_count = try r.readVarU32();
                var i: u32 = 0;
                while (i < target_count) : (i += 1) _ = try r.readVarU32();
                _ = try r.readVarU32();
            },
            0x10, 0x12 => {
                const idx = try r.readVarU32();
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
            0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26 => _ = try r.readVarU32(),
            0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f,
            0x30, 0x31, 0x32, 0x33, 0x34, 0x35,
            0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e => try readMemArg(&r),
            0x3f => _ = try r.readVarU32(),
            0x40 => return CheckError.MemoryGrowNotAllowed,
            0x41 => _ = try r.readVarS32(),
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
