//! wasm-counts: static, factual counts for comparing WebAssembly modules.
//!
//! Input is a WebAssembly module. Output is deterministic long-form CSV with
//! one integer metric per row. Counts are deliberately not scores or policy
//! verdicts: callers can load the CSV into SQLite, DuckDB, a spreadsheet, or
//! their own CI analysis.

const std = @import("std");
const wasm_reader = @import("lib/wasm-reader.zig");

const Reader = wasm_reader.Reader;
const Instr = wasm_reader.Instr;

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = 32 * 1024;
const INPUT_CONTENT_TYPE = "application/wasm";
const OUTPUT_CONTENT_TYPE = "text/csv";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const CountError = wasm_reader.Error || error{
    UnsupportedImportKind,
    UnsupportedType,
    InvalidSection,
    FunctionCodeMismatch,
    OutputOverflow,
};

const Counts = struct {
    module_bytes: u64 = 0,
    sections: u64 = 0,
    custom_sections: u64 = 0,
    types: u64 = 0,
    v128_types: u64 = 0,
    functions_defined: u64 = 0,
    functions_imported: u64 = 0,
    tables_defined: u64 = 0,
    tables_imported: u64 = 0,
    globals_defined: u64 = 0,
    globals_imported: u64 = 0,
    memories_defined: u64 = 0,
    memories_imported: u64 = 0,
    memories_memory64: u64 = 0,
    memories_shared: u64 = 0,
    memories_with_maximum: u64 = 0,
    memory_initial_pages: u64 = 0,
    memory_maximum_pages: u64 = 0,
    data_segments: u64 = 0,
    active_data_segments: u64 = 0,
    data_bytes: u64 = 0,
    active_data_bytes: u64 = 0,
    instructions: u64 = 0,
    loops: u64 = 0,
    branches: u64 = 0,
    conditional_branches: u64 = 0,
    br_table_targets: u64 = 0,
    calls_direct_local: u64 = 0,
    calls_direct_imported: u64 = 0,
    calls_indirect: u64 = 0,
    simd_instructions: u64 = 0,
    explicit_traps: u64 = 0,
    integer_divisions: u64 = 0,
    integer_remainders: u64 = 0,
    trapping_float_to_int: u64 = 0,
    potentially_trapping_memory: u64 = 0,
    potentially_trapping_table: u64 = 0,
    potentially_trapping_instructions: u64 = 0,
};

const Writer = struct {
    off: usize = 0,

    fn write(self: *Writer, bytes: []const u8) CountError!void {
        if (bytes.len > output_buf.len - self.off) return CountError.OutputOverflow;
        @memcpy(output_buf[self.off..][0..bytes.len], bytes);
        self.off += bytes.len;
    }

    fn writeU64(self: *Writer, value: u64) CountError!void {
        var decimal: [20]u8 = undefined;
        var remaining = value;
        var start = decimal.len;

        if (remaining == 0) {
            start -= 1;
            decimal[start] = '0';
        } else {
            while (remaining != 0) {
                start -= 1;
                const digit: u8 = @intCast(remaining % 10);
                decimal[start] = '0' + digit;
                remaining /= 10;
            }
        }

        try self.write(decimal[start..]);
    }

    fn row(self: *Writer, comptime name: []const u8, value: u64) CountError!void {
        try self.write(name ++ ",");
        try self.writeU64(value);
        try self.write("\n");
    }
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_bytes_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
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

fn readName(r: *Reader) CountError!void {
    _ = try r.readN(try r.readVarU32());
}

fn countValueType(counts: *Counts, value_type: u8) CountError!void {
    switch (value_type) {
        0x7f, 0x7e, 0x7d, 0x7c, 0x70, 0x6f => {},
        0x7b => counts.v128_types += 1,
        else => return CountError.UnsupportedType,
    }
}

fn readRefType(r: *Reader) CountError!void {
    const kind = try r.readByte();
    switch (kind) {
        0x70, 0x6f => {},
        0x63, 0x64 => _ = try r.readVarS64(5),
        else => return CountError.UnsupportedType,
    }
}

fn addLimits(counts: *Counts, limits: wasm_reader.Limits) void {
    if (limits.memory64) counts.memories_memory64 += 1;
    if (limits.shared) counts.memories_shared += 1;
    counts.memory_initial_pages +|= limits.min;
    if (limits.has_max) {
        counts.memories_with_maximum += 1;
        counts.memory_maximum_pages +|= limits.max;
    }
}

fn parseTypeSection(counts: *Counts, payload: []const u8) CountError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    counts.types += count;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (try r.readByte() != 0x60) return CountError.UnsupportedType;
        const params = try r.readVarU32();
        var p: u32 = 0;
        while (p < params) : (p += 1) try countValueType(counts, try r.readByte());
        const results = try r.readVarU32();
        var q: u32 = 0;
        while (q < results) : (q += 1) try countValueType(counts, try r.readByte());
    }
    if (r.remaining() != 0) return CountError.TrailingBytes;
}

fn parseTableType(r: *Reader) CountError!void {
    try readRefType(r);
    _ = try wasm_reader.readLimits(r);
}

fn parseImportSection(counts: *Counts, payload: []const u8) CountError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try readName(&r);
        try readName(&r);
        switch (try r.readByte()) {
            0 => {
                _ = try r.readVarU32();
                counts.functions_imported += 1;
            },
            1 => {
                try parseTableType(&r);
                counts.tables_imported += 1;
            },
            2 => {
                const limits = try wasm_reader.readLimits(&r);
                counts.memories_imported += 1;
                addLimits(counts, limits);
            },
            3 => {
                try countValueType(counts, try r.readByte());
                _ = try r.readByte();
                counts.globals_imported += 1;
            },
            4 => {
                _ = try r.readByte();
                _ = try r.readVarU32();
            },
            else => return CountError.UnsupportedImportKind,
        }
    }
    if (r.remaining() != 0) return CountError.TrailingBytes;
}

fn parseFunctionSection(counts: *Counts, payload: []const u8) CountError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    counts.functions_defined += count;
    var i: u32 = 0;
    while (i < count) : (i += 1) _ = try r.readVarU32();
    if (r.remaining() != 0) return CountError.TrailingBytes;
}

fn parseTableSection(counts: *Counts, payload: []const u8) CountError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    counts.tables_defined += count;
    var i: u32 = 0;
    while (i < count) : (i += 1) try parseTableType(&r);
    if (r.remaining() != 0) return CountError.TrailingBytes;
}

fn parseMemorySection(counts: *Counts, payload: []const u8) CountError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    counts.memories_defined += count;
    var i: u32 = 0;
    while (i < count) : (i += 1) addLimits(counts, try wasm_reader.readLimits(&r));
    if (r.remaining() != 0) return CountError.TrailingBytes;
}

fn skipConstExpr(r: *Reader, counts: *Counts) CountError!void {
    while (true) {
        const op = try r.readByte();
        counts.instructions += 1;
        switch (op) {
            0x0b => return,
            0x23, 0xd2 => _ = try r.readVarU32(),
            0x41 => _ = try r.readVarS32(),
            0x42 => _ = try r.readVarS64(10),
            0x43 => _ = try r.readN(4),
            0x44 => _ = try r.readN(8),
            0xd0 => _ = try r.readVarS64(5),
            0xfd => {
                if (try r.readVarU32() != 12) return CountError.InvalidSection;
                _ = try r.readN(16);
                counts.simd_instructions += 1;
            },
            // Extended constant expressions use ordinary numeric operators.
            0x45...0xc4 => {},
            else => return CountError.InvalidSection,
        }
    }
}

fn parseGlobalSection(counts: *Counts, payload: []const u8) CountError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    counts.globals_defined += count;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try countValueType(counts, try r.readByte());
        _ = try r.readByte();
        try skipConstExpr(&r, counts);
    }
    if (r.remaining() != 0) return CountError.TrailingBytes;
}

fn parseDataSection(counts: *Counts, payload: []const u8) CountError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    counts.data_segments += count;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const flags = try r.readVarU32();
        const active = switch (flags) {
            0 => blk: {
                try skipConstExpr(&r, counts);
                break :blk true;
            },
            1 => false,
            2 => blk: {
                _ = try r.readVarU32();
                try skipConstExpr(&r, counts);
                break :blk true;
            },
            else => return CountError.InvalidSection,
        };
        const size = try r.readVarU32();
        _ = try r.readN(size);
        counts.data_bytes += size;
        if (active) {
            counts.active_data_segments += 1;
            counts.active_data_bytes += size;
        }
    }
    if (r.remaining() != 0) return CountError.TrailingBytes;
}

const InstructionCounter = struct {
    counts: *Counts,
    imported_functions: u64,

    pub fn onInstr(self: *InstructionCounter, instr: Instr) CountError!void {
        const c = self.counts;
        c.instructions += 1;

        switch (instr.op) {
            0x00 => {
                c.explicit_traps += 1;
                c.potentially_trapping_instructions += 1;
            },
            0x03 => c.loops += 1,
            0x04 => c.conditional_branches += 1,
            0x0c => c.branches += 1,
            0x0d => {
                c.branches += 1;
                c.conditional_branches += 1;
            },
            0x0e => {
                c.branches += 1;
                c.conditional_branches += 1;
            },
            0x10, 0x12 => {
                if (@as(u64, @intCast(instr.imm)) < self.imported_functions) {
                    c.calls_direct_imported += 1;
                } else {
                    c.calls_direct_local += 1;
                }
            },
            0x11, 0x13 => {
                c.calls_indirect += 1;
                c.potentially_trapping_table += 1;
                c.potentially_trapping_instructions += 1;
            },
            0x14 => {
                c.calls_indirect += 1;
                c.potentially_trapping_instructions += 1;
            },
            0x25, 0x26 => {
                c.potentially_trapping_table += 1;
                c.potentially_trapping_instructions += 1;
            },
            0x28...0x3e => {
                c.potentially_trapping_memory += 1;
                c.potentially_trapping_instructions += 1;
            },
            0x6d, 0x6e, 0x7f, 0x80 => {
                c.integer_divisions += 1;
                c.potentially_trapping_instructions += 1;
            },
            0x6f, 0x70, 0x81, 0x82 => {
                c.integer_remainders += 1;
                c.potentially_trapping_instructions += 1;
            },
            0xa8...0xab, 0xae...0xb1 => {
                c.trapping_float_to_int += 1;
                c.potentially_trapping_instructions += 1;
            },
            0xfc => switch (instr.subop) {
                8, 10, 11 => {
                    c.potentially_trapping_memory += 1;
                    c.potentially_trapping_instructions += 1;
                },
                12, 14, 17 => {
                    c.potentially_trapping_table += 1;
                    c.potentially_trapping_instructions += 1;
                },
                else => {},
            },
            0xfd => {
                c.simd_instructions += 1;
                if (instr.subop <= 11 or (instr.subop >= 84 and instr.subop <= 93)) {
                    c.potentially_trapping_memory += 1;
                    c.potentially_trapping_instructions += 1;
                }
            },
            0xfe => if (instr.subop != 3) {
                c.potentially_trapping_memory += 1;
                c.potentially_trapping_instructions += 1;
            },
            else => {},
        }
    }

    pub fn onBrTableTarget(self: *InstructionCounter, depth: u32) CountError!void {
        _ = depth;
        self.counts.br_table_targets += 1;
    }
};

fn parseCodeSection(counts: *Counts, payload: []const u8) CountError!void {
    var r = Reader.init(payload);
    const count = try r.readVarU32();
    if (count != counts.functions_defined) return CountError.FunctionCodeMismatch;
    var counter = InstructionCounter{
        .counts = counts,
        .imported_functions = counts.functions_imported,
    };
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const body = try r.readN(try r.readVarU32());
        var locals = Reader.init(body);
        const local_groups = try locals.readVarU32();
        var group: u32 = 0;
        while (group < local_groups) : (group += 1) {
            const local_count = try locals.readVarU32();
            const value_type = try locals.readByte();
            if (value_type == 0x7b) {
                counts.v128_types += local_count;
            } else {
                try countValueType(counts, value_type);
            }
        }
        try wasm_reader.walkFunctionBody(&counter, body);
        // walkFunctionBody omits the final end that closes the function.
        counts.instructions += 1;
    }
    if (r.remaining() != 0) return CountError.TrailingBytes;
}

fn analyze(wasm: []const u8) CountError!Counts {
    try wasm_reader.checkHeader(wasm);
    var counts = Counts{ .module_bytes = wasm.len };
    var r = Reader.init(wasm[8..]);
    while (r.remaining() > 0) {
        const section_id = try r.readByte();
        const payload = try r.readN(try r.readVarU32());
        counts.sections += 1;
        switch (section_id) {
            0 => counts.custom_sections += 1,
            1 => try parseTypeSection(&counts, payload),
            2 => try parseImportSection(&counts, payload),
            3 => try parseFunctionSection(&counts, payload),
            4 => try parseTableSection(&counts, payload),
            5 => try parseMemorySection(&counts, payload),
            6 => try parseGlobalSection(&counts, payload),
            10 => try parseCodeSection(&counts, payload),
            11 => try parseDataSection(&counts, payload),
            else => {},
        }
    }
    return counts;
}

fn renderCsv(counts: Counts) CountError!usize {
    var w = Writer{};
    try w.write("metric,value\n");
    try w.row("module_bytes", counts.module_bytes);
    try w.row("sections", counts.sections);
    try w.row("custom_sections", counts.custom_sections);
    try w.row("types", counts.types);
    try w.row("v128_types", counts.v128_types);
    try w.row("functions_defined", counts.functions_defined);
    try w.row("functions_imported", counts.functions_imported);
    try w.row("tables_defined", counts.tables_defined);
    try w.row("tables_imported", counts.tables_imported);
    try w.row("globals_defined", counts.globals_defined);
    try w.row("globals_imported", counts.globals_imported);
    try w.row("memories_defined", counts.memories_defined);
    try w.row("memories_imported", counts.memories_imported);
    try w.row("memories_memory64", counts.memories_memory64);
    try w.row("memories_shared", counts.memories_shared);
    try w.row("memories_with_maximum", counts.memories_with_maximum);
    try w.row("memory_initial_pages", counts.memory_initial_pages);
    try w.row("memory_initial_bytes", counts.memory_initial_pages *| 65536);
    try w.row("memory_maximum_pages", counts.memory_maximum_pages);
    try w.row("memory_maximum_bytes", counts.memory_maximum_pages *| 65536);
    try w.row("data_segments", counts.data_segments);
    try w.row("active_data_segments", counts.active_data_segments);
    try w.row("data_bytes", counts.data_bytes);
    try w.row("active_data_bytes", counts.active_data_bytes);
    try w.row("instructions", counts.instructions);
    try w.row("loops", counts.loops);
    try w.row("branches", counts.branches);
    try w.row("conditional_branches", counts.conditional_branches);
    try w.row("br_table_targets", counts.br_table_targets);
    try w.row("calls_direct_local", counts.calls_direct_local);
    try w.row("calls_direct_imported", counts.calls_direct_imported);
    try w.row("calls_indirect", counts.calls_indirect);
    try w.row("simd_instructions", counts.simd_instructions);
    try w.row("explicit_traps", counts.explicit_traps);
    try w.row("integer_divisions", counts.integer_divisions);
    try w.row("integer_remainders", counts.integer_remainders);
    try w.row("trapping_float_to_int", counts.trapping_float_to_int);
    try w.row("potentially_trapping_memory", counts.potentially_trapping_memory);
    try w.row("potentially_trapping_table", counts.potentially_trapping_table);
    try w.row("potentially_trapping_instructions", counts.potentially_trapping_instructions);
    return w.off;
}

fn renderImpl(input_size: u32) u32 {
    if (input_size > INPUT_CAP) @trap();
    const counts = analyze(input_buf[0..input_size]) catch @trap();
    return @intCast(renderCsv(counts) catch @trap());
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

test "reports semantic, SIMD, trapping, and memory counts as CSV" {
    const body = [_]u8{
        0x03, 0x40, // loop
        0x41, 0x08, 0x41, 0x02, 0x6d, 0x1a, // i32.div_s; drop
        0xfd, 0x0c, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // v128.const
        0x1a, 0x0b, 0x0b, // drop; end loop; end function
    };
    const module = wasm_reader.moduleWithBody(&body);
    const counts = try analyze(&module);
    try std.testing.expectEqual(@as(u64, 1), counts.functions_defined);
    try std.testing.expectEqual(@as(u64, 1), counts.memories_defined);
    try std.testing.expectEqual(@as(u64, 1), counts.memory_initial_pages);
    try std.testing.expectEqual(@as(u64, 1), counts.loops);
    try std.testing.expectEqual(@as(u64, 1), counts.simd_instructions);
    try std.testing.expectEqual(@as(u64, 1), counts.integer_divisions);
    try std.testing.expectEqual(@as(u64, 1), counts.potentially_trapping_instructions);

    const out_len = try renderCsv(counts);
    const csv = output_buf[0..out_len];
    try std.testing.expect(std.mem.indexOf(u8, csv, "metric,value\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "simd_instructions,1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "integer_divisions,1\n") != null);
}
