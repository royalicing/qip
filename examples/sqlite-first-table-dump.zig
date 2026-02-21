const std = @import("std");

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = 8 * 1024 * 1024;
const MAX_COLUMNS: usize = 256;
const MAX_TABLE_NAME: usize = 256;
const MAX_SQL: usize = 64 * 1024;
const MAX_PAYLOAD_COPY: usize = 1024 * 1024;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var payload_copy_buf: [MAX_PAYLOAD_COPY]u8 = undefined;

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

const SerialHeader = struct {
    count: usize,
    serials: [MAX_COLUMNS]u64,
    data_offset: usize,
};

const ColumnDecl = struct {
    name: []const u8,
    decl_type: []const u8,
};

const ParserState = struct {
    input: []const u8,
    page_size: u32,
    usable_page_bytes: u32,
    page_count: u32,

    table_found: bool = false,
    table_root_page: u32 = 0,
    table_name_len: usize = 0,
    table_sql_len: usize = 0,
    table_name_buf: [MAX_TABLE_NAME]u8 = undefined,
    table_sql_buf: [MAX_SQL]u8 = undefined,

    had_error: bool = false,
    error_msg: []const u8 = "",

    fn setError(self: *ParserState, msg: []const u8) void {
        if (!self.had_error) {
            self.had_error = true;
            self.error_msg = msg;
        }
    }

    fn tableName(self: *const ParserState) []const u8 {
        return self.table_name_buf[0..self.table_name_len];
    }

    fn tableSQL(self: *const ParserState) []const u8 {
        return self.table_sql_buf[0..self.table_sql_len];
    }
};

const Output = struct {
    index: usize = 0,
    overflow: bool = false,

    fn writeByte(self: *Output, b: u8) void {
        if (self.overflow) return;
        if (self.index >= output_buf.len) {
            self.overflow = true;
            return;
        }
        output_buf[self.index] = b;
        self.index += 1;
    }

    fn writeSlice(self: *Output, s: []const u8) void {
        if (self.overflow or s.len == 0) return;
        if (self.index + s.len > output_buf.len) {
            self.overflow = true;
            return;
        }
        @memcpy(output_buf[self.index..][0..s.len], s);
        self.index += s.len;
    }

    fn writeFmt(self: *Output, comptime fmt: []const u8, args: anytype) void {
        var tmp: [256]u8 = undefined;
        const rendered = std.fmt.bufPrint(&tmp, fmt, args) catch {
            self.overflow = true;
            return;
        };
        self.writeSlice(rendered);
    }

    fn writeEscapedText(self: *Output, s: []const u8) void {
        for (s) |c| {
            switch (c) {
                '\\' => self.writeSlice("\\\\"),
                '\n' => self.writeSlice("\\n"),
                '\r' => self.writeSlice("\\r"),
                '\t' => self.writeSlice("\\t"),
                else => {
                    if (c < 0x20) {
                        self.writeFmt("\\x{X:0>2}", .{c});
                    } else {
                        self.writeByte(c);
                    }
                },
            }
            if (self.overflow) return;
        }
    }
};

fn trimASCII(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and isASCIIWhitespace(s[start])) : (start += 1) {}
    while (end > start and isASCIIWhitespace(s[end - 1])) : (end -= 1) {}
    return s[start..end];
}

fn isASCIIWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn asciiLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (asciiLower(x) != asciiLower(y)) return false;
    }
    return true;
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn readU16BE(input: []const u8, off: usize) ?u16 {
    if (off + 2 > input.len) return null;
    return (@as(u16, input[off]) << 8) | @as(u16, input[off + 1]);
}

fn readU32BE(input: []const u8, off: usize) ?u32 {
    if (off + 4 > input.len) return null;
    return (@as(u32, input[off]) << 24) |
        (@as(u32, input[off + 1]) << 16) |
        (@as(u32, input[off + 2]) << 8) |
        @as(u32, input[off + 3]);
}

fn readVarint(input: []const u8, off: usize) ?struct { value: u64, used: usize } {
    if (off >= input.len) return null;
    var v: u64 = 0;
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        if (off + i >= input.len) return null;
        const c = input[off + i];
        if (i == 8) {
            v = (v << 8) | @as(u64, c);
            return .{ .value = v, .used = 9 };
        }
        v = (v << 7) | @as(u64, c & 0x7f);
        if ((c & 0x80) == 0) {
            return .{ .value = v, .used = i + 1 };
        }
    }
    return null;
}

fn serialTypeByteSize(serial: u64) ?usize {
    return switch (serial) {
        0 => 0,
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 4,
        5 => 6,
        6 => 8,
        7 => 8,
        8 => 0,
        9 => 0,
        else => blk: {
            if (serial >= 12) {
                if ((serial & 1) == 0) break :blk @as(usize, @intCast((serial - 12) / 2));
                break :blk @as(usize, @intCast((serial - 13) / 2));
            }
            break :blk null;
        },
    };
}

fn decodeSignedBigEndian(bytes: []const u8) i64 {
    if (bytes.len == 0) return 0;
    var u: u64 = 0;
    for (bytes) |b| {
        u = (u << 8) | @as(u64, b);
    }
    const bit_count: u7 = @intCast(bytes.len * 8);
    if (bit_count < 64) {
        const sign_bit = @as(u64, 1) << @as(u6, @intCast(bit_count - 1));
        if ((u & sign_bit) != 0) {
            u |= (~@as(u64, 0)) << @as(u6, @intCast(bit_count));
        }
    }
    return @as(i64, @bitCast(u));
}

fn decodeFloat64BigEndian(bytes: []const u8) ?f64 {
    if (bytes.len != 8) return null;
    var u: u64 = 0;
    for (bytes) |b| {
        u = (u << 8) | @as(u64, b);
    }
    return @as(f64, @bitCast(u));
}

fn parseRecordHeader(payload: []const u8) ?SerialHeader {
    const header_size_varint = readVarint(payload, 0) orelse return null;
    const header_size: usize = @intCast(header_size_varint.value);
    if (header_size == 0 or header_size > payload.len) return null;

    var serials: [MAX_COLUMNS]u64 = undefined;
    var count: usize = 0;
    var cursor: usize = header_size_varint.used;
    while (cursor < header_size) {
        if (count >= serials.len) return null;
        const serial_varint = readVarint(payload, cursor) orelse return null;
        serials[count] = serial_varint.value;
        count += 1;
        cursor += serial_varint.used;
    }

    if (cursor != header_size) return null;
    return .{ .count = count, .serials = serials, .data_offset = header_size };
}

fn extractFieldSlice(payload: []const u8, header: SerialHeader, field_idx: usize) ?struct { serial: u64, data: []const u8 } {
    if (field_idx >= header.count) return null;
    var cursor = header.data_offset;
    var i: usize = 0;
    while (i < header.count) : (i += 1) {
        const serial = header.serials[i];
        const field_size = serialTypeByteSize(serial) orelse return null;
        if (cursor + field_size > payload.len) return null;
        if (i == field_idx) {
            return .{ .serial = serial, .data = payload[cursor .. cursor + field_size] };
        }
        cursor += field_size;
    }
    return null;
}

fn copyToFixed(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    if (n > 0) @memcpy(dst[0..n], src[0..n]);
    return n;
}

fn pageOffset(state: *const ParserState, page_num: u32) ?usize {
    if (page_num == 0 or page_num > state.page_count) return null;
    const off64 = (@as(u64, page_num) - 1) * @as(u64, state.page_size);
    if (off64 >= state.input.len) return null;
    return @intCast(off64);
}

fn pageHeaderOffset(state: *const ParserState, page_num: u32) ?usize {
    const off = pageOffset(state, page_num) orelse return null;
    return if (page_num == 1) off + 100 else off;
}

fn computeLocalPayloadBytes(usable: u32, payload_size: usize) usize {
    const max_local: usize = usable - 35;
    const min_local: usize = ((usable - 12) * 32 / 255) - 23;
    if (payload_size <= max_local) return payload_size;

    var local = min_local + ((payload_size - min_local) % (usable - 4));
    if (local > max_local) local = min_local;
    return local;
}

fn readCellPayloadFromLeafTable(state: *ParserState, cell_off: usize) ?[]const u8 {
    const payload_size_varint = readVarint(state.input, cell_off) orelse return null;
    const payload_size: usize = @intCast(payload_size_varint.value);

    const rowid_varint = readVarint(state.input, cell_off + payload_size_varint.used) orelse return null;
    const payload_off = cell_off + payload_size_varint.used + rowid_varint.used;
    if (payload_off > state.input.len) return null;

    const local_bytes = computeLocalPayloadBytes(state.usable_page_bytes, payload_size);
    if (payload_off + local_bytes > state.input.len) return null;

    if (payload_size <= local_bytes) {
        return state.input[payload_off .. payload_off + payload_size];
    }

    if (payload_size > payload_copy_buf.len) return null;
    @memcpy(payload_copy_buf[0..local_bytes], state.input[payload_off .. payload_off + local_bytes]);

    if (payload_off + local_bytes + 4 > state.input.len) return null;
    var overflow_page = readU32BE(state.input, payload_off + local_bytes) orelse return null;
    var copied: usize = local_bytes;
    var remaining = payload_size - local_bytes;

    while (remaining > 0) {
        if (overflow_page == 0) return null;
        const overflow_off = pageOffset(state, overflow_page) orelse return null;
        if (overflow_off + 4 > state.input.len) return null;

        const next = readU32BE(state.input, overflow_off) orelse return null;
        const chunk_cap: usize = state.usable_page_bytes - 4;
        const chunk = @min(remaining, chunk_cap);
        if (overflow_off + 4 + chunk > state.input.len) return null;

        @memcpy(payload_copy_buf[copied..][0..chunk], state.input[overflow_off + 4 .. overflow_off + 4 + chunk]);
        copied += chunk;
        remaining -= chunk;
        overflow_page = next;
    }

    return payload_copy_buf[0..payload_size];
}

fn parseSchemaRecord(state: *ParserState, payload: []const u8) void {
    const header = parseRecordHeader(payload) orelse return;
    if (header.count < 5) return;

    const type_field = extractFieldSlice(payload, header, 0) orelse return;
    const name_field = extractFieldSlice(payload, header, 1) orelse return;
    const root_field = extractFieldSlice(payload, header, 3) orelse return;
    const sql_field = extractFieldSlice(payload, header, 4) orelse return;

    if (!(type_field.serial >= 13 and (type_field.serial & 1) == 1)) return;
    if (!(name_field.serial >= 13 and (name_field.serial & 1) == 1)) return;
    if (!(sql_field.serial >= 13 and (sql_field.serial & 1) == 1)) return;

    if (!std.mem.eql(u8, type_field.data, "table")) return;
    if (startsWithIgnoreCase(name_field.data, "sqlite_")) return;

    var root_page: i64 = 0;
    switch (root_field.serial) {
        1, 2, 3, 4, 5, 6 => root_page = decodeSignedBigEndian(root_field.data),
        8 => root_page = 0,
        9 => root_page = 1,
        else => return,
    }
    if (root_page <= 0 or root_page > std.math.maxInt(u32)) return;

    state.table_name_len = copyToFixed(&state.table_name_buf, name_field.data);
    state.table_sql_len = copyToFixed(&state.table_sql_buf, sql_field.data);
    state.table_root_page = @intCast(root_page);
    state.table_found = true;
}

fn walkSchemaPage(state: *ParserState, page_num: u32) void {
    if (state.had_error or state.table_found) return;

    const header_off = pageHeaderOffset(state, page_num) orelse {
        state.setError("invalid schema page header");
        return;
    };
    if (header_off + 8 > state.input.len) {
        state.setError("schema page header out of bounds");
        return;
    }

    const page_type = state.input[header_off];
    if (page_type == 0x05) {
        if (header_off + 12 > state.input.len) {
            state.setError("schema interior page header out of bounds");
            return;
        }
        const cell_count = readU16BE(state.input, header_off + 3) orelse {
            state.setError("schema interior cell count");
            return;
        };
        const right_ptr = readU32BE(state.input, header_off + 8) orelse {
            state.setError("schema right pointer");
            return;
        };
        const cell_ptrs_off = header_off + 12;
        var i: u16 = 0;
        while (i < cell_count) : (i += 1) {
            const ptr = readU16BE(state.input, cell_ptrs_off + @as(usize, i) * 2) orelse {
                state.setError("schema interior cell pointer");
                return;
            };
            const page_off = pageOffset(state, page_num) orelse {
                state.setError("schema interior page offset");
                return;
            };
            const cell_off = page_off + ptr;
            const child = readU32BE(state.input, cell_off) orelse {
                state.setError("schema interior child pointer");
                return;
            };
            walkSchemaPage(state, child);
            if (state.table_found or state.had_error) return;
        }
        walkSchemaPage(state, right_ptr);
        return;
    }

    if (page_type != 0x0d) {
        state.setError("unexpected schema page type");
        return;
    }

    const cell_count = readU16BE(state.input, header_off + 3) orelse {
        state.setError("schema leaf cell count");
        return;
    };
    const cell_ptrs_off = header_off + 8;
    const page_off = pageOffset(state, page_num) orelse {
        state.setError("schema leaf page offset");
        return;
    };

    var i: u16 = 0;
    while (i < cell_count) : (i += 1) {
        const ptr = readU16BE(state.input, cell_ptrs_off + @as(usize, i) * 2) orelse {
            state.setError("schema leaf cell pointer");
            return;
        };
        const cell_off = page_off + ptr;
        const payload = readCellPayloadFromLeafTable(state, cell_off) orelse {
            state.setError("schema payload decode failed");
            return;
        };
        parseSchemaRecord(state, payload);
        if (state.table_found) return;
    }
}

fn isConstraintStart(token: []const u8) bool {
    return eqlIgnoreCase(token, "constraint") or
        eqlIgnoreCase(token, "primary") or
        eqlIgnoreCase(token, "not") or
        eqlIgnoreCase(token, "unique") or
        eqlIgnoreCase(token, "check") or
        eqlIgnoreCase(token, "default") or
        eqlIgnoreCase(token, "collate") or
        eqlIgnoreCase(token, "references") or
        eqlIgnoreCase(token, "generated");
}

fn isTableConstraint(item: []const u8) bool {
    const trimmed = trimASCII(item);
    var i: usize = 0;
    while (i < trimmed.len and !isASCIIWhitespace(trimmed[i])) : (i += 1) {}
    const first = trimmed[0..i];
    return eqlIgnoreCase(first, "constraint") or
        eqlIgnoreCase(first, "primary") or
        eqlIgnoreCase(first, "unique") or
        eqlIgnoreCase(first, "check") or
        eqlIgnoreCase(first, "foreign");
}

fn parseIdentifier(item: []const u8) struct { ident: []const u8, rest_start: usize } {
    var i: usize = 0;
    while (i < item.len and isASCIIWhitespace(item[i])) : (i += 1) {}
    if (i >= item.len) return .{ .ident = "", .rest_start = item.len };

    if (item[i] == '"' or item[i] == '\'' or item[i] == '`') {
        const quote = item[i];
        const start = i + 1;
        i += 1;
        while (i < item.len and item[i] != quote) : (i += 1) {}
        if (i < item.len) {
            return .{ .ident = item[start..i], .rest_start = i + 1 };
        }
        return .{ .ident = item[start..], .rest_start = item.len };
    }
    if (item[i] == '[') {
        const start = i + 1;
        i += 1;
        while (i < item.len and item[i] != ']') : (i += 1) {}
        if (i < item.len) {
            return .{ .ident = item[start..i], .rest_start = i + 1 };
        }
        return .{ .ident = item[start..], .rest_start = item.len };
    }

    const start = i;
    while (i < item.len and !isASCIIWhitespace(item[i])) : (i += 1) {}
    return .{ .ident = item[start..i], .rest_start = i };
}

fn parseDeclaredType(item: []const u8, start_at: usize) []const u8 {
    var i = start_at;
    while (i < item.len and isASCIIWhitespace(item[i])) : (i += 1) {}
    if (i >= item.len) return "";

    const type_start = i;
    var type_end = i;
    var paren_depth: usize = 0;
    while (i < item.len) {
        if (item[i] == '(') paren_depth += 1 else if (item[i] == ')' and paren_depth > 0) paren_depth -= 1;

        if (paren_depth == 0 and isASCIIWhitespace(item[i])) {
            var j = i;
            while (j < item.len and isASCIIWhitespace(item[j])) : (j += 1) {}
            if (j >= item.len) {
                type_end = i;
                break;
            }
            var k = j;
            while (k < item.len and !isASCIIWhitespace(item[k]) and item[k] != '(' and item[k] != ',') : (k += 1) {}
            const token = item[j..k];
            if (isConstraintStart(token)) {
                type_end = i;
                break;
            }
        }

        type_end = i + 1;
        i += 1;
    }

    return trimASCII(item[type_start..type_end]);
}

fn parseColumnsFromCreateSQL(sql: []const u8, out_cols: *[MAX_COLUMNS]ColumnDecl) usize {
    var open_idx: ?usize = null;
    var close_idx: ?usize = null;
    var i: usize = 0;
    var depth: usize = 0;
    var quote: u8 = 0;

    while (i < sql.len) : (i += 1) {
        const c = sql[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'' or c == '`') {
            quote = c;
            continue;
        }
        if (c == '(') {
            if (open_idx == null) open_idx = i;
            depth += 1;
            continue;
        }
        if (c == ')') {
            if (depth > 0) {
                depth -= 1;
                if (depth == 0) {
                    close_idx = i;
                    break;
                }
            }
        }
    }

    if (open_idx == null or close_idx == null or close_idx.? <= open_idx.?) return 0;
    const body = sql[open_idx.? + 1 .. close_idx.?];

    var count: usize = 0;
    var part_start: usize = 0;
    i = 0;
    depth = 0;
    quote = 0;
    while (i <= body.len) : (i += 1) {
        const at_end = i == body.len;
        const c: u8 = if (at_end) ',' else body[i];
        if (!at_end) {
            if (quote != 0) {
                if (c == quote) quote = 0;
                continue;
            }
            if (c == '"' or c == '\'' or c == '`') {
                quote = c;
                continue;
            }
            if (c == '(') {
                depth += 1;
                continue;
            }
            if (c == ')' and depth > 0) {
                depth -= 1;
                continue;
            }
        }

        if ((at_end or c == ',') and depth == 0) {
            const raw_part = trimASCII(body[part_start..i]);
            part_start = i + 1;
            if (raw_part.len == 0) continue;
            if (isTableConstraint(raw_part)) continue;
            if (count >= out_cols.len) break;

            const parsed_ident = parseIdentifier(raw_part);
            const name = trimASCII(parsed_ident.ident);
            if (name.len == 0) continue;
            const decl_type = parseDeclaredType(raw_part, parsed_ident.rest_start);
            out_cols[count] = .{ .name = name, .decl_type = decl_type };
            count += 1;
        }
    }
    return count;
}

fn writeValue(out: *Output, serial: u64, data: []const u8) void {
    switch (serial) {
        0 => out.writeSlice("NULL"),
        1, 2, 3, 4, 5, 6 => out.writeFmt("{d}", .{decodeSignedBigEndian(data)}),
        7 => {
            const f = decodeFloat64BigEndian(data) orelse {
                out.writeSlice("NULL");
                return;
            };
            out.writeFmt("{d}", .{f});
        },
        8 => out.writeSlice("0"),
        9 => out.writeSlice("1"),
        else => {
            if (serial >= 12 and (serial & 1) == 1) {
                out.writeEscapedText(data);
                return;
            }
            if (serial >= 12 and (serial & 1) == 0) {
                out.writeSlice("x'");
                for (data) |b| out.writeFmt("{X:0>2}", .{b});
                out.writeByte('\'');
                return;
            }
            out.writeSlice("NULL");
        },
    }
}

fn writeRowFromPayload(out: *Output, payload: []const u8) bool {
    const header = parseRecordHeader(payload) orelse return false;
    var data_cursor = header.data_offset;
    var i: usize = 0;
    while (i < header.count) : (i += 1) {
        if (i > 0) out.writeByte('\t');
        const serial = header.serials[i];
        const field_size = serialTypeByteSize(serial) orelse return false;
        if (data_cursor + field_size > payload.len) return false;
        const data = payload[data_cursor .. data_cursor + field_size];
        writeValue(out, serial, data);
        data_cursor += field_size;
        if (out.overflow) return false;
    }
    out.writeByte('\n');
    return !out.overflow;
}

fn walkTableRows(state: *ParserState, page_num: u32, out: *Output) void {
    if (state.had_error or out.overflow) return;

    const header_off = pageHeaderOffset(state, page_num) orelse {
        state.setError("table page header invalid");
        return;
    };
    if (header_off + 8 > state.input.len) {
        state.setError("table page header out of bounds");
        return;
    }

    const page_type = state.input[header_off];
    if (page_type == 0x05) {
        if (header_off + 12 > state.input.len) {
            state.setError("table interior page header out of bounds");
            return;
        }
        const cell_count = readU16BE(state.input, header_off + 3) orelse {
            state.setError("table interior cell count");
            return;
        };
        const right_ptr = readU32BE(state.input, header_off + 8) orelse {
            state.setError("table interior right pointer");
            return;
        };
        const cell_ptrs_off = header_off + 12;
        const page_off = pageOffset(state, page_num) orelse {
            state.setError("table interior page offset");
            return;
        };
        var i: u16 = 0;
        while (i < cell_count) : (i += 1) {
            const ptr = readU16BE(state.input, cell_ptrs_off + @as(usize, i) * 2) orelse {
                state.setError("table interior cell pointer");
                return;
            };
            const child = readU32BE(state.input, page_off + ptr) orelse {
                state.setError("table interior child pointer");
                return;
            };
            walkTableRows(state, child, out);
            if (state.had_error or out.overflow) return;
        }
        walkTableRows(state, right_ptr, out);
        return;
    }

    if (page_type != 0x0d) {
        state.setError("unexpected table page type");
        return;
    }

    const cell_count = readU16BE(state.input, header_off + 3) orelse {
        state.setError("table leaf cell count");
        return;
    };
    const cell_ptrs_off = header_off + 8;
    const page_off = pageOffset(state, page_num) orelse {
        state.setError("table leaf page offset");
        return;
    };

    var i: u16 = 0;
    while (i < cell_count) : (i += 1) {
        const ptr = readU16BE(state.input, cell_ptrs_off + @as(usize, i) * 2) orelse {
            state.setError("table leaf cell pointer");
            return;
        };
        const cell_off = page_off + ptr;
        const payload = readCellPayloadFromLeafTable(state, cell_off) orelse {
            state.setError("table row payload decode failed");
            return;
        };
        if (!writeRowFromPayload(out, payload)) {
            state.setError("table row decode failed");
            return;
        }
    }
}

fn writeDump(state: *ParserState, out: *Output) void {
    out.writeSlice("table\t");
    out.writeSlice(state.tableName());
    out.writeByte('\n');

    var columns: [MAX_COLUMNS]ColumnDecl = undefined;
    const column_count = parseColumnsFromCreateSQL(state.tableSQL(), &columns);

    out.writeSlice("columns");
    var i: usize = 0;
    while (i < column_count) : (i += 1) {
        out.writeByte('\t');
        out.writeSlice(columns[i].name);
    }
    out.writeByte('\n');

    out.writeSlice("types");
    i = 0;
    while (i < column_count) : (i += 1) {
        out.writeByte('\t');
        out.writeSlice(columns[i].decl_type);
    }
    out.writeByte('\n');

    out.writeSlice("rows\n");
    walkTableRows(state, state.table_root_page, out);
}

fn initState(input: []const u8) ?ParserState {
    if (input.len < 100) return null;
    if (!std.mem.eql(u8, input[0..16], "SQLite format 3\x00")) return null;

    const ps = readU16BE(input, 16) orelse return null;
    const page_size: u32 = if (ps == 1) 65536 else ps;
    if (page_size == 0) return null;

    const reserved = input[20];
    if (reserved >= page_size) return null;
    const usable_page_bytes = page_size - reserved;
    if (usable_page_bytes < 480) return null;

    const page_count: u32 = @intCast((input.len + page_size - 1) / page_size);
    return .{
        .input = input,
        .page_size = page_size,
        .usable_page_bytes = usable_page_bytes,
        .page_count = page_count,
    };
}

export fn run(input_size_u32: u32) u32 {
    const input_size = @min(@as(usize, @intCast(input_size_u32)), INPUT_CAP);
    const input = input_buf[0..input_size];

    var out = Output{};
    var state = initState(input) orelse {
        out.writeSlice("error\tinvalid sqlite file\n");
        return @as(u32, @intCast(out.index));
    };

    walkSchemaPage(&state, 1);
    if (state.had_error) {
        out.writeSlice("error\t");
        out.writeSlice(state.error_msg);
        out.writeByte('\n');
        return @as(u32, @intCast(out.index));
    }
    if (!state.table_found) {
        out.writeSlice("error\tno user table found\n");
        return @as(u32, @intCast(out.index));
    }

    writeDump(&state, &out);
    if (state.had_error) {
        out.writeSlice("error\t");
        out.writeSlice(state.error_msg);
        out.writeByte('\n');
    } else if (out.overflow) {
        return 0;
    }

    return @as(u32, @intCast(out.index));
}

test "dumps first table schema and rows from sqlite fixture" {
    const sqlite_bytes = @embedFile("sqlite3/countries.sqlite");
    try std.testing.expect(sqlite_bytes.len <= INPUT_CAP);
    @memcpy(input_buf[0..sqlite_bytes.len], sqlite_bytes);

    const out_size = run(@as(u32, @intCast(sqlite_bytes.len)));
    try std.testing.expect(out_size > 0);
    const out = output_buf[0..@as(usize, @intCast(out_size))];

    try std.testing.expect(std.mem.indexOf(u8, out, "table\tcountries\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "columns\tiso_3166_code\tname_en\tcurrency\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "types\tTEXT\tTEXT\tTEXT\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "rows\nAU\tAustralia\tAUD\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "US\tUnited States\tUSD\n") != null);
}
