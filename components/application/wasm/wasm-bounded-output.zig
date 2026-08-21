//! wasm-bounded-output: a QIP component that certifies the successful return
//! value of a Content component's `render(i32) -> i32` is within its declared
//! output capacity.
//!
//! The checker deliberately recognizes a small proof-carrying epilogue rather
//! than attempting whole-program range analysis. A dynamic result must be
//! copied to a local, compared unsigned against the exact static value exported
//! by `output_utf8_cap()` or `output_bytes_cap()`, and trap when it is greater:
//!
//!   local.get $size
//!   i32.const OUTPUT_CAP  ;; or global.get of an immutable OUTPUT_CAP
//!   i32.gt_u
//!   if
//!     unreachable
//!   end
//!   local.get $size
//!
//! A constant successful result no greater than the capacity is also accepted.
//! Explicit returns and branches to the function label are rejected, ensuring
//! every successful exit passes through the recognized final proof. The
//! checker proves the returned byte count only; other QIP ABI and artifact
//! rules belong to the normal contract validator and wasm-strict-profile.
//!
//! Input is a Wasm module; output is the same bytes on success. `commit`
//! rejects when the proof is absent or malformed.

const std = @import("std");
const wasm_reader = @import("lib/wasm-reader.zig");

const Reader = wasm_reader.Reader;
const Instr = wasm_reader.Instr;

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP;
const NO_RENDER: i64 = 1;
const ERROR_BIT: u64 = 1 << 63;
const INVALID_INPUT_BIT: u64 = 1 << 62;
const MAX_TYPES: usize = 4096;
const MAX_DEFINED_FUNCS: usize = 8192;
const MAX_GLOBALS: usize = 4096;
const TRACE_LEN: usize = 7;
const INPUT_CONTENT_TYPE = "application/wasm";
const OUTPUT_CONTENT_TYPE = "application/wasm";

var input_buf: [INPUT_CAP]u8 = undefined;
var pending_commit_result: i64 = NO_RENDER;
var type_buf: [MAX_TYPES]FuncType = undefined;
var func_type_buf: [MAX_DEFINED_FUNCS]u32 = undefined;
var function_body_buf: [MAX_DEFINED_FUNCS][]const u8 = undefined;
var global_buf: [MAX_GLOBALS]StaticGlobal = undefined;

const FuncType = struct {
    param_count: u32 = 0,
    first_param_type: u8 = 0,
    result_count: u32 = 0,
    result_type: u8 = 0,
};

const StaticGlobal = struct {
    is_static_i32: bool = false,
    value: u32 = 0,
};

const FunctionExport = union(enum) {
    missing,
    function: u32,
    invalid,
};

const OutputExports = struct {
    render: FunctionExport = .missing,
    utf8_cap: FunctionExport = .missing,
    bytes_cap: FunctionExport = .missing,
};

const CheckError = wasm_reader.Error || error{
    ImportNotSupported,
    TooManyTypes,
    TooManyFunctions,
    TooManyGlobals,
    FunctionCodeMismatch,
    RenderExportMissing,
    RenderExportInvalid,
    RenderSignatureInvalid,
    OutputCapacityMissing,
    OutputCapacityAmbiguous,
    OutputCapacityExportInvalid,
    OutputCapacitySignatureInvalid,
    OutputCapacityNotStatic,
    OutputCapacityGlobalNotStatic,
    OutputBoundNotProven,
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return INPUT_CAP;
}

export fn output_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn output_bytes_cap() u32 {
    return OUTPUT_CAP;
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return INPUT_CONTENT_TYPE.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

fn parseTypeSection(payload: []const u8) CheckError!u32 {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    if (count > MAX_TYPES) return CheckError.TooManyTypes;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (try r.readByte() != 0x60) return CheckError.InvalidWasm;
        const param_count = try r.readVarU32();
        var first_param_type: u8 = 0;
        if (param_count > 0) {
            first_param_type = try r.readByte();
            if (param_count > 1) _ = try r.readN(param_count - 1);
        }
        const result_count = try r.readVarU32();
        var result_type: u8 = 0;
        if (result_count > 0) {
            result_type = try r.readByte();
            if (result_count > 1) _ = try r.readN(result_count - 1);
        }
        type_buf[i] = .{
            .param_count = param_count,
            .first_param_type = first_param_type,
            .result_count = result_count,
            .result_type = result_type,
        };
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
    return count;
}

fn parseImportSection(payload: []const u8) CheckError!void {
    var r = Reader.init(payload);
    if (try r.readVarU32() != 0) return CheckError.ImportNotSupported;
    if (r.remaining() != 0) return CheckError.TrailingBytes;
}

fn parseFunctionSection(payload: []const u8) CheckError!u32 {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    if (count > MAX_DEFINED_FUNCS) return CheckError.TooManyFunctions;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        func_type_buf[i] = try r.readVarU32();
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
    return count;
}

fn readInitExpr(r: *Reader, prior_global_count: u32) CheckError!StaticGlobal {
    const op = try r.readByte();
    var result = StaticGlobal{};
    switch (op) {
        0x41 => result = .{
            .is_static_i32 = true,
            .value = @bitCast(try r.readVarS32()),
        },
        0x42 => _ = try r.readVarS64(10),
        0x43 => _ = try r.readN(4),
        0x44 => _ = try r.readN(8),
        0x23 => {
            const index = try r.readVarU32();
            if (index < prior_global_count and global_buf[index].is_static_i32) {
                result = global_buf[index];
            }
        },
        0xd0 => _ = try r.readVarS64(5),
        0xd2 => _ = try r.readVarU32(),
        0xfd => {
            if (try r.readVarU32() != 12) return CheckError.InvalidWasm;
            _ = try r.readN(16);
        },
        else => return CheckError.InvalidWasm,
    }
    if (try r.readByte() != 0x0b) return CheckError.InvalidWasm;
    return result;
}

fn parseGlobalSection(payload: []const u8) CheckError!u32 {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    if (count > MAX_GLOBALS) return CheckError.TooManyGlobals;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const value_type = try r.readByte();
        const mutable = try r.readByte();
        const initial = try readInitExpr(&r, i);
        global_buf[i] = if (value_type == 0x7f and mutable == 0) initial else .{};
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
    return count;
}

fn exportSlot(exports: *OutputExports, name: []const u8) ?*FunctionExport {
    if (std.mem.eql(u8, name, "render")) return &exports.render;
    if (std.mem.eql(u8, name, "output_utf8_cap")) return &exports.utf8_cap;
    if (std.mem.eql(u8, name, "output_bytes_cap")) return &exports.bytes_cap;
    return null;
}

fn parseExportSection(payload: []const u8, exports: *OutputExports) CheckError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const name_len = try r.readVarU32();
        const name = try r.readN(name_len);
        const kind = try r.readByte();
        const index = try r.readVarU32();
        const slot = exportSlot(exports, name) orelse continue;
        slot.* = if (kind == 0x00) .{ .function = index } else .invalid;
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
}

fn parseCodeSection(payload: []const u8, defined_func_count: u32) CheckError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    if (count != defined_func_count) return CheckError.FunctionCodeMismatch;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const body_size = try r.readVarU32();
        function_body_buf[i] = try r.readN(body_size);
    }
    if (r.remaining() != 0) return CheckError.TrailingBytes;
}

fn functionIndex(target: FunctionExport, missing: CheckError, invalid: CheckError) CheckError!u32 {
    return switch (target) {
        .missing => missing,
        .invalid => invalid,
        .function => |index| index,
    };
}

fn functionType(index: u32, type_count: u32, defined_func_count: u32, invalid: CheckError) CheckError!FuncType {
    if (index >= defined_func_count) return invalid;
    const type_index = func_type_buf[index];
    if (type_index >= type_count) return invalid;
    return type_buf[type_index];
}

fn resolveStaticCapacity(
    target: FunctionExport,
    type_count: u32,
    defined_func_count: u32,
    global_count: u32,
) CheckError!u32 {
    const index = try functionIndex(
        target,
        CheckError.OutputCapacityMissing,
        CheckError.OutputCapacityExportInvalid,
    );
    const func_type = try functionType(
        index,
        type_count,
        defined_func_count,
        CheckError.OutputCapacitySignatureInvalid,
    );
    if (func_type.param_count != 0 or func_type.result_count != 1 or func_type.result_type != 0x7f) {
        return CheckError.OutputCapacitySignatureInvalid;
    }

    var r = Reader.init(function_body_buf[index]);
    if (try r.readVarU32() != 0) return CheckError.OutputCapacityNotStatic;
    const op = try r.readByte();
    const value: u32 = switch (op) {
        0x41 => @bitCast(try r.readVarS32()),
        0x23 => blk: {
            const global_index = try r.readVarU32();
            if (global_index >= global_count or !global_buf[global_index].is_static_i32) {
                return CheckError.OutputCapacityGlobalNotStatic;
            }
            break :blk global_buf[global_index].value;
        },
        else => return CheckError.OutputCapacityNotStatic,
    };
    if (try r.readByte() != 0x0b or r.remaining() != 0) {
        return CheckError.OutputCapacityNotStatic;
    }
    return value;
}

const ProofHandler = struct {
    recent: [TRACE_LEN]Instr = undefined,
    recent_len: usize = 0,
    control_depth: usize = 0,
    has_escaping_exit: bool = false,

    fn append(self: *ProofHandler, instr: Instr) void {
        if (self.recent_len < TRACE_LEN) {
            self.recent[self.recent_len] = instr;
            self.recent_len += 1;
            return;
        }
        var i: usize = 1;
        while (i < TRACE_LEN) : (i += 1) self.recent[i - 1] = self.recent[i];
        self.recent[TRACE_LEN - 1] = instr;
    }

    pub fn onInstr(self: *ProofHandler, instr: Instr) CheckError!void {
        switch (instr.op) {
            0x02, 0x03, 0x04 => self.control_depth += 1,
            0x0b => {
                if (self.control_depth > 0) self.control_depth -= 1;
            },
            0x0f, 0x12, 0x13 => self.has_escaping_exit = true,
            0x0c, 0x0d => {
                const depth: usize = @intCast(instr.imm);
                if (depth >= self.control_depth) self.has_escaping_exit = true;
            },
            else => {},
        }
        self.append(instr);
    }

    pub fn onBrTableTarget(self: *ProofHandler, depth: u32) CheckError!void {
        if (depth >= self.control_depth) self.has_escaping_exit = true;
    }
};

fn isOp(instr: Instr, op: u8) bool {
    return instr.op == op;
}

fn i32ImmediateBits(instr: Instr) u32 {
    return @bitCast(@as(i32, @intCast(instr.imm)));
}

fn isCapacityOperand(instr: Instr, capacity: u32, global_count: u32) bool {
    if (instr.op == 0x41) return i32ImmediateBits(instr) == capacity;
    if (instr.op != 0x23) return false;
    const index: u32 = @intCast(instr.imm);
    return index < global_count and
        global_buf[index].is_static_i32 and
        global_buf[index].value == capacity;
}

fn provesFinalResult(recent: []const Instr, capacity: u32, global_count: u32) bool {
    if (recent.len == 0) return false;

    const last = recent[recent.len - 1];
    if (last.op == 0x41 and i32ImmediateBits(last) <= capacity) {
        return true;
    }
    if (recent.len < TRACE_LEN) return false;

    const proof = recent[recent.len - TRACE_LEN ..];
    if (!(isOp(proof[3], 0x04) and
        isOp(proof[4], 0x00) and
        isOp(proof[5], 0x0b))) return false;
    if (proof[6].op != 0x20) return false;

    // size > capacity
    if (proof[0].op == 0x20 and
        isCapacityOperand(proof[1], capacity, global_count) and
        proof[2].op == 0x4b and
        proof[6].imm == proof[0].imm) return true;

    // capacity < size
    if (isCapacityOperand(proof[0], capacity, global_count) and
        proof[1].op == 0x20 and
        proof[2].op == 0x49 and
        proof[6].imm == proof[1].imm) return true;

    return false;
}

fn validateRender(
    target: FunctionExport,
    capacity: u32,
    type_count: u32,
    defined_func_count: u32,
    global_count: u32,
) CheckError!void {
    const index = try functionIndex(
        target,
        CheckError.RenderExportMissing,
        CheckError.RenderExportInvalid,
    );
    const func_type = try functionType(
        index,
        type_count,
        defined_func_count,
        CheckError.RenderSignatureInvalid,
    );
    if (func_type.param_count != 1 or
        func_type.first_param_type != 0x7f or
        func_type.result_count != 1 or
        func_type.result_type != 0x7f)
    {
        return CheckError.RenderSignatureInvalid;
    }

    var handler = ProofHandler{};
    try wasm_reader.walkFunctionBody(&handler, function_body_buf[index]);
    if (handler.has_escaping_exit or
        !provesFinalResult(handler.recent[0..handler.recent_len], capacity, global_count))
    {
        return CheckError.OutputBoundNotProven;
    }
}

fn checkModule(wasm: []const u8) CheckError!void {
    try wasm_reader.checkHeader(wasm);

    var r = Reader.init(wasm[8..]);
    var type_count: u32 = 0;
    var defined_func_count: u32 = 0;
    var global_count: u32 = 0;
    var have_function_section = false;
    var have_code_section = false;
    var exports = OutputExports{};

    while (r.remaining() > 0) {
        const section_id = try r.readByte();
        const section_size = try r.readVarU32();
        const payload = try r.readN(section_size);
        switch (section_id) {
            0 => {},
            1 => type_count = try parseTypeSection(payload),
            2 => try parseImportSection(payload),
            3 => {
                defined_func_count = try parseFunctionSection(payload);
                have_function_section = true;
            },
            6 => global_count = try parseGlobalSection(payload),
            7 => try parseExportSection(payload, &exports),
            10 => {
                try parseCodeSection(payload, defined_func_count);
                have_code_section = true;
            },
            else => {},
        }
    }

    if (!have_function_section or !have_code_section) return CheckError.InvalidWasm;
    const has_utf8 = exports.utf8_cap != .missing;
    const has_bytes = exports.bytes_cap != .missing;
    if (!has_utf8 and !has_bytes) return CheckError.OutputCapacityMissing;
    if (has_utf8 and has_bytes) return CheckError.OutputCapacityAmbiguous;
    const capacity = try resolveStaticCapacity(
        if (has_utf8) exports.utf8_cap else exports.bytes_cap,
        type_count,
        defined_func_count,
        global_count,
    );
    try validateRender(exports.render, capacity, type_count, defined_func_count, global_count);
}

export fn render(input_size: u32) u32 {
    const input_len: usize = @intCast(input_size);
    if (pending_commit_result != NO_RENDER) @trap();
    if (input_len > INPUT_CAP) @trap();

    pending_commit_result = @bitCast(ERROR_BIT | INVALID_INPUT_BIT);
    checkModule(input_buf[0..input_len]) catch return 0;
    pending_commit_result = 0;
    return input_size;
}

/// Close the policy-check transaction. This function does not trap.
export fn commit() i64 {
    const result = if (pending_commit_result == NO_RENDER)
        @as(i64, @bitCast(ERROR_BIT | INVALID_INPUT_BIT))
    else
        pending_commit_result;
    pending_commit_result = NO_RENDER;
    return result;
}

const hexBytes = wasm_reader.hexBytes;

// (module
//   (memory (export "memory") 1 1)
//   (func (export "output_utf8_cap") (result i32) (i32.const 100))
//   (func (export "render") (param i32) (result i32) (local i32)
//     local.get 0 local.set 1
//     local.get 1 i32.const 100 i32.gt_u
//     if unreachable end
//     local.get 1))
const guarded_module = hexBytes(
    "0061736d01000000010a026000017f60017f017f0303020001050401010101" ++
        "072503066d656d6f727902000f6f75747075745f757466385f636170000006" ++
        "72656e64657200010a1c02050041e4000b1401017f20002101200141e4004b" ++
        "0440000b20010b",
);

const unguarded_module = hexBytes(
    "0061736d01000000010a026000017f60017f017f0303020001050401010101" ++
        "072503066d656d6f727902000f6f75747075745f757466385f636170000006" ++
        "72656e64657200010a0c02050041e4000b040020000b",
);

const wrong_capacity_module = hexBytes(
    "0061736d01000000010a026000017f60017f017f0303020001050401010101" ++
        "072603066d656d6f72790200106f75747075745f62797465735f6361700000" ++
        "0672656e64657200010a1c02050041e4000b1401017f20002101200141e500" ++
        "4b0440000b20010b",
);

const early_return_module = hexBytes(
    "0061736d01000000010a026000017f60017f017f0303020001050401010101" ++
        "072503066d656d6f727902000f6f75747075745f757466385f636170000006" ++
        "72656e64657200010a2402050041e4000b1c01017f2000044020000f0b2000" ++
        "2101200141e4004b0440000b20010b",
);

test "accepts an exact guarded output bound" {
    try checkModule(&guarded_module);
}

test "render rejects an unproved output and the instance recovers" {
    @memcpy(input_buf[0..unguarded_module.len], &unguarded_module);
    try std.testing.expectEqual(@as(u32, 0), render(unguarded_module.len));
    try std.testing.expect(commit() < 0);

    @memcpy(input_buf[0..guarded_module.len], &guarded_module);
    try std.testing.expectEqual(@as(u32, guarded_module.len), render(guarded_module.len));
    try std.testing.expectEqualSlices(u8, &guarded_module, input_buf[0..guarded_module.len]);
    try std.testing.expectEqual(@as(i64, 0), commit());
}

test "rejects an unguarded dynamic result" {
    try std.testing.expectError(CheckError.OutputBoundNotProven, checkModule(&unguarded_module));
}

test "rejects a guard against a different capacity" {
    try std.testing.expectError(CheckError.OutputBoundNotProven, checkModule(&wrong_capacity_module));
}

test "rejects a path returning before the guard" {
    try std.testing.expectError(CheckError.OutputBoundNotProven, checkModule(&early_return_module));
}
