// markdown-table.zig
const std = @import("std");

const INPUT_CAP: u32 = 0x20000;
const OUTPUT_CAP: u32 = 0x40000;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&output_buf)));
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

const Writer = struct {
    buf: []u8,
    idx: usize,
    overflow: bool,

    fn init(buf: []u8) Writer {
        return .{ .buf = buf, .idx = 0, .overflow = false };
    }

    fn writeByte(self: *Writer, b: u8) void {
        if (self.overflow) return;
        if (self.idx >= self.buf.len) {
            self.overflow = true;
            return;
        }
        self.buf[self.idx] = b;
        self.idx += 1;
    }

    fn writeSlice(self: *Writer, s: []const u8) void {
        if (self.overflow) return;
        if (self.idx + s.len > self.buf.len) {
            const remaining = self.buf.len - self.idx;
            if (remaining > 0) {
                @memcpy(self.buf[self.idx..][0..remaining], s[0..remaining]);
                self.idx += remaining;
            }
            self.overflow = true;
            return;
        }
        @memcpy(self.buf[self.idx..][0..s.len], s);
        self.idx += s.len;
    }
};

fn stripCR(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

fn isBlank(line: []const u8) bool {
    for (line) |ch| {
        if (ch != ' ' and ch != '\t' and ch != '\r') return false;
    }
    return true;
}

fn trimIndent(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and i < 3 and line[i] == ' ') : (i += 1) {}
    return line[i..];
}

fn fenceLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    return std.mem.startsWith(u8, trimmed, "```");
}

fn hasPipe(line: []const u8) bool {
    return std.mem.indexOfScalar(u8, line, '|') != null;
}

fn countCells(line: []const u8) usize {
    const s = trimIndent(line);
    if (s.len == 0) return 0;
    if (!hasPipe(s)) return 0;
    const leading_pipe = s[0] == '|';
    const trailing_pipe = s[s.len - 1] == '|';
    var count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        if (i == s.len or s[i] == '|') {
            const raw = s[start..i];
            const trimmed = std.mem.trim(u8, raw, " \t");
            if (!(trimmed.len == 0 and ((leading_pipe and count == 0) or (i == s.len and trailing_pipe)))) {
                count += 1;
            }
            start = i + 1;
        }
    }
    return count;
}

fn separatorCellValid(cell: []const u8) bool {
    if (cell.len < 3) return false;
    var i: usize = 0;
    if (cell[i] == ':') i += 1;
    var dashes: usize = 0;
    while (i < cell.len and cell[i] == '-') : (i += 1) {
        dashes += 1;
    }
    if (dashes < 3) return false;
    if (i < cell.len and cell[i] == ':') i += 1;
    return i == cell.len;
}

fn countSeparatorCells(line: []const u8) usize {
    const s = trimIndent(line);
    if (!hasPipe(s)) return 0;
    const leading_pipe = s[0] == '|';
    const trailing_pipe = s[s.len - 1] == '|';
    var count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        if (i == s.len or s[i] == '|') {
            const raw = s[start..i];
            const trimmed = std.mem.trim(u8, raw, " \t");
            if (!(trimmed.len == 0 and ((leading_pipe and count == 0) or (i == s.len and trailing_pipe)))) {
                if (!separatorCellValid(trimmed)) return 0;
                count += 1;
            }
            start = i + 1;
        }
    }
    return count;
}

fn writeRow(line: []const u8, w: *Writer, cell_tag: []const u8) void {
    const s = trimIndent(line);
    const leading_pipe = s.len > 0 and s[0] == '|';
    const trailing_pipe = s.len > 0 and s[s.len - 1] == '|';
    var start: usize = 0;
    var count: usize = 0;
    var i: usize = 0;
    while (i <= s.len and !w.overflow) : (i += 1) {
        if (i == s.len or s[i] == '|') {
            const raw = s[start..i];
            const trimmed = std.mem.trim(u8, raw, " \t");
            if (!(trimmed.len == 0 and ((leading_pipe and count == 0) or (i == s.len and trailing_pipe)))) {
                w.writeByte('<');
                w.writeSlice(cell_tag);
                w.writeByte('>');
                w.writeSlice(trimmed);
                w.writeSlice("</");
                w.writeSlice(cell_tag);
                w.writeByte('>');
                count += 1;
            }
            start = i + 1;
        }
    }
}

fn renderTables(input: []const u8, output: []u8) usize {
    var w = Writer.init(output);
    var in_code = false;

    var i: usize = 0;
    while (i < input.len and !w.overflow) {
        var line_end = i;
        while (line_end < input.len and input[line_end] != '\n') : (line_end += 1) {}
        const line = stripCR(input[i..line_end]);
        const next_start = if (line_end < input.len) line_end + 1 else input.len;

        if (in_code) {
            w.writeSlice(line);
            w.writeByte('\n');
            if (fenceLine(line)) {
                in_code = false;
            }
            i = next_start;
            continue;
        }

        if (fenceLine(line)) {
            in_code = true;
            w.writeSlice(line);
            w.writeByte('\n');
            i = next_start;
            continue;
        }

        var next_line: []const u8 = &[_]u8{};
        var next_end = next_start;
        if (next_start < input.len) {
            while (next_end < input.len and input[next_end] != '\n') : (next_end += 1) {}
            next_line = stripCR(input[next_start..next_end]);
        }

        const header_cells = countCells(line);
        const sep_cells = countSeparatorCells(next_line);
        if (header_cells > 0 and sep_cells == header_cells) {
            w.writeSlice("<table>\n<thead>\n<tr>");
            writeRow(line, &w, "th");
            w.writeSlice("</tr>\n</thead>\n<tbody>\n");

            const row_start = next_end + 1;
            i = row_start;
            while (i < input.len and !w.overflow) {
                var row_end = i;
                while (row_end < input.len and input[row_end] != '\n') : (row_end += 1) {}
                const row = stripCR(input[i..row_end]);
                if (isBlank(row)) {
                    i = row_end + 1;
                    break;
                }
                if (!hasPipe(row)) {
                    break;
                }
                w.writeSlice("<tr>");
                writeRow(row, &w, "td");
                w.writeSlice("</tr>\n");
                i = row_end + 1;
            }

            w.writeSlice("</tbody>\n</table>\n");
            continue;
        }

        w.writeSlice(line);
        w.writeByte('\n');
        i = next_start;
    }

    return w.idx;
}

export fn run(input_size: u32) u32 {
    const input = input_buf[0..@as(usize, @intCast(input_size))];
    const output = output_buf[0..];
    const written = renderTables(input, output);
    return @as(u32, @intCast(written));
}

test "basic table" {
    var out: [2048]u8 = undefined;
    const input = "| A | B |\n| --- | --- |\n| 1 | 2 |\n";
    const written = renderTables(input, out[0..]);
    try std.testing.expectEqualStrings(
        "<table>\n<thead>\n<tr><th>A</th><th>B</th></tr>\n</thead>\n<tbody>\n<tr><td>1</td><td>2</td></tr>\n</tbody>\n</table>\n",
        out[0..written],
    );
}

test "non table passthrough" {
    var out: [1024]u8 = undefined;
    const input = "a | b\n---\n";
    const written = renderTables(input, out[0..]);
    try std.testing.expectEqualStrings(
        "a | b\n---\n",
        out[0..written],
    );
}
