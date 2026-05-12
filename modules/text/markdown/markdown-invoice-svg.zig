const std = @import("std");

const INPUT_CAP: usize = 256 * 1024;
const OUTPUT_CAP: usize = 1024 * 1024;
const INPUT_CONTENT_TYPE = "text/markdown";
const OUTPUT_CONTENT_TYPE = "image/svg+xml";

const PAGE_WIDTH_PX: u32 = 816; // 8.5in @ 96dpi
const PAGE_HEIGHT_PX: u32 = 1056; // 11in @ 96dpi
const MARGIN: f32 = 48.0;
const ROW_H: f32 = 24.0;

const MAX_ITEMS: usize = 128;
const MAX_FACTS: usize = 64;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const Fact = struct {
    heading: []const u8,
    value: []const u8,
};

const Item = struct {
    sku: []const u8,
    count: f64,
    cost: f64,
    desc: []const u8,
};

const Invoice = struct {
    number: []const u8 = "",
    created: []const u8 = "",
    due: []const u8 = "",
    tax_percent: f64 = 0,
    facts: [MAX_FACTS]Fact = undefined,
    facts_len: usize = 0,
    items: [MAX_ITEMS]Item = undefined,
    items_len: usize = 0,

    fn subtotal(self: *const Invoice) f64 {
        var sum: f64 = 0;
        for (self.items[0..self.items_len]) |it| {
            sum += it.count * it.cost;
        }
        return sum;
    }
};

const Line = struct {
    text: []const u8,
    next: usize,
};

const Writer = struct {
    idx: usize = 0,

    fn appendByte(self: *Writer, b: u8) !void {
        if (self.idx >= OUTPUT_CAP) return error.OutputOverflow;
        output_buf[self.idx] = b;
        self.idx += 1;
    }

    fn appendSlice(self: *Writer, s: []const u8) !void {
        if (self.idx + s.len > OUTPUT_CAP) return error.OutputOverflow;
        @memcpy(output_buf[self.idx .. self.idx + s.len], s);
        self.idx += s.len;
    }

    fn appendInt(self: *Writer, v: u32) !void {
        var buf: [20]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d}", .{v});
        try self.appendSlice(s);
    }

    fn appendFloat(self: *Writer, v: f32) !void {
        var buf: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d:.1}", .{v});
        try self.appendSlice(s);
    }

    fn appendMoney(self: *Writer, v: f64) !void {
        var buf: [40]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "${d:.2}", .{v});
        try self.appendSlice(s);
    }

    fn appendEscaped(self: *Writer, s: []const u8) !void {
        for (s) |b| {
            switch (b) {
                '&' => try self.appendSlice("&amp;"),
                '<' => try self.appendSlice("&lt;"),
                '>' => try self.appendSlice("&gt;"),
                '"' => try self.appendSlice("&quot;"),
                '\'' => try self.appendSlice("&apos;"),
                else => try self.appendByte(b),
            }
        }
    }
};

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
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

fn trimSpace(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and (s[a] == ' ' or s[a] == '\t' or s[a] == '\r' or s[a] == '\n')) : (a += 1) {}
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t' or s[b - 1] == '\r' or s[b - 1] == '\n')) : (b -= 1) {}
    return s[a..b];
}

fn asciiLower(b: u8) u8 {
    if (b >= 'A' and b <= 'Z') return b + 32;
    return b;
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (asciiLower(x) != asciiLower(y)) return false;
    }
    return true;
}

fn headingKind(heading: []const u8) enum { number, created, due, tax, items, other } {
    var norm_buf: [128]u8 = undefined;
    var n: usize = 0;
    for (heading) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '-' or ch == '_') continue;
        if (n >= norm_buf.len) break;
        norm_buf[n] = asciiLower(ch);
        n += 1;
    }
    const norm = norm_buf[0..n];
    if (eqIgnoreCase(norm, "invoicenumber") or eqIgnoreCase(norm, "number") or eqIgnoreCase(norm, "invoice#")) return .number;
    if (eqIgnoreCase(norm, "invoicecreateddate") or eqIgnoreCase(norm, "createddate") or eqIgnoreCase(norm, "created")) return .created;
    if (eqIgnoreCase(norm, "invoiceduedate") or eqIgnoreCase(norm, "duedate") or eqIgnoreCase(norm, "due")) return .due;
    if (eqIgnoreCase(norm, "tax") or eqIgnoreCase(norm, "taxpercent") or eqIgnoreCase(norm, "taxpercentage")) return .tax;
    if (eqIgnoreCase(norm, "items")) return .items;
    return .other;
}

fn nextLine(input: []const u8, start: usize) Line {
    var end = start;
    while (end < input.len and input[end] != '\n') : (end += 1) {}
    var line_end = end;
    if (line_end > start and input[line_end - 1] == '\r') line_end -= 1;
    return .{
        .text = input[start..line_end],
        .next = if (end < input.len) end + 1 else input.len,
    };
}

fn parseAtxHeading(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    var spaces: usize = 0;
    while (i < line.len and spaces < 3 and line[i] == ' ') : ({
        i += 1;
        spaces += 1;
    }) {}
    if (i >= line.len or line[i] != '#') return null;
    var count: usize = 0;
    while (i < line.len and line[i] == '#' and count < 6) : ({
        i += 1;
        count += 1;
    }) {}
    if (count == 0) return null;
    if (i < line.len and line[i] != ' ' and line[i] != '\t') return null;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    var out = trimSpace(line[i..]);
    var end = out.len;
    while (end > 0 and out[end - 1] == '#') end -= 1;
    out = trimSpace(out[0..end]);
    if (out.len == 0) return null;
    return out;
}

fn isSetextUnderline(line: []const u8) bool {
    const s = trimSpace(line);
    if (s.len == 0) return false;
    const ch = s[0];
    if (ch != '=' and ch != '-') return false;
    for (s) |b| {
        if (b != ch) return false;
    }
    return true;
}

fn firstParagraph(body: []const u8) []const u8 {
    var i: usize = 0;
    while (i < body.len) {
        const ln = nextLine(body, i);
        if (trimSpace(ln.text).len != 0) break;
        i = ln.next;
    }
    const start = i;
    while (i < body.len) {
        const ln = nextLine(body, i);
        if (trimSpace(ln.text).len == 0) break;
        i = ln.next;
    }
    return trimSpace(body[start..i]);
}

fn parsePercent(text: []const u8) f64 {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (text) |ch| {
        if ((ch >= '0' and ch <= '9') or ch == '.' or ch == '-') {
            if (n < buf.len) {
                buf[n] = ch;
                n += 1;
            }
        } else if (n > 0) {
            break;
        }
    }
    if (n == 0) return 0;
    return std.fmt.parseFloat(f64, buf[0..n]) catch 0;
}

fn parseItemLine(line: []const u8) ?Item {
    const s = trimSpace(line);
    if (s.len == 0) return null;

    var first_sp: ?usize = null;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == ' ' or s[i] == '\t') {
            first_sp = i;
            break;
        }
    }
    const sp1 = first_sp orelse return null;
    const sku = trimSpace(s[0..sp1]);
    if (sku.len == 0) return null;

    var j = sp1;
    while (j < s.len and (s[j] == ' ' or s[j] == '\t')) : (j += 1) {}
    const token_start = j;
    while (j < s.len and s[j] != ' ' and s[j] != '\t') : (j += 1) {}
    const token = s[token_start..j];
    const at = std.mem.indexOfScalar(u8, token, '@') orelse return null;
    const count_s = trimSpace(token[0..at]);
    const cost_s = trimSpace(token[at + 1 ..]);
    if (count_s.len == 0 or cost_s.len == 0) return null;

    const count = std.fmt.parseFloat(f64, count_s) catch return null;
    const cost = std.fmt.parseFloat(f64, cost_s) catch return null;

    while (j < s.len and (s[j] == ' ' or s[j] == '\t')) : (j += 1) {}
    const desc = if (j < s.len) s[j..] else "";

    return .{
        .sku = sku,
        .count = count,
        .cost = cost,
        .desc = desc,
    };
}

fn parseInvoice(input: []const u8) Invoice {
    var inv = Invoice{};

    var pos: usize = 0;
    var current_heading: ?[]const u8 = null;
    var body_start: usize = 0;

    while (pos < input.len) {
        const line = nextLine(input, pos);
        if (parseAtxHeading(line.text)) |heading| {
            if (current_heading) |h| {
                const body = input[body_start..pos];
                applySection(&inv, h, body);
            }
            current_heading = heading;
            body_start = line.next;
            pos = line.next;
            continue;
        }

        if (current_heading == null and line.next < input.len) {
            const next_ln = nextLine(input, line.next);
            if (isSetextUnderline(next_ln.text)) {
                current_heading = trimSpace(line.text);
                body_start = next_ln.next;
                pos = next_ln.next;
                continue;
            }
        }

        pos = line.next;
    }

    if (current_heading) |h| {
        const body = input[body_start..input.len];
        applySection(&inv, h, body);
    }

    return inv;
}

fn applySection(inv: *Invoice, heading_raw: []const u8, body: []const u8) void {
    const heading = trimSpace(heading_raw);
    const kind = headingKind(heading);
    const para = firstParagraph(body);

    switch (kind) {
        .number => if (para.len > 0) inv.number = para,
        .created => if (para.len > 0) inv.created = para,
        .due => if (para.len > 0) inv.due = para,
        .tax => inv.tax_percent = parsePercent(para),
        .items => {
            var p: usize = 0;
            while (p < body.len and inv.items_len < MAX_ITEMS) {
                const ln = nextLine(body, p);
                if (parseItemLine(ln.text)) |item| {
                    inv.items[inv.items_len] = item;
                    inv.items_len += 1;
                }
                p = ln.next;
            }
        },
        .other => if (para.len > 0 and inv.facts_len < MAX_FACTS) {
            inv.facts[inv.facts_len] = .{ .heading = heading, .value = para };
            inv.facts_len += 1;
        },
    }
}

fn writeText(w: *Writer, x: f32, y: f32, size: u32, weight: []const u8, text: []const u8) !void {
    try w.appendSlice("<text x=\"");
    try w.appendFloat(x);
    try w.appendSlice("\" y=\"");
    try w.appendFloat(y);
    try w.appendSlice("\" font-family=\"Arial, Helvetica, sans-serif\" font-size=\"");
    try w.appendInt(size);
    try w.appendSlice("\" font-weight=\"");
    try w.appendSlice(weight);
    try w.appendSlice("\">\n");
    try w.appendEscaped(text);
    try w.appendSlice("</text>");
}

fn writeTextRight(w: *Writer, x: f32, y: f32, size: u32, weight: []const u8, text: []const u8) !void {
    try w.appendSlice("<text text-anchor=\"end\" x=\"");
    try w.appendFloat(x);
    try w.appendSlice("\" y=\"");
    try w.appendFloat(y);
    try w.appendSlice("\" font-family=\"Arial, Helvetica, sans-serif\" font-size=\"");
    try w.appendInt(size);
    try w.appendSlice("\" font-weight=\"");
    try w.appendSlice(weight);
    try w.appendSlice("\">\n");
    try w.appendEscaped(text);
    try w.appendSlice("</text>");
}

fn renderInvoice(inv: *const Invoice) !u32 {
    var w = Writer{};

    const subtotal = inv.subtotal();
    const tax_amount = subtotal * inv.tax_percent / 100.0;
    const total = subtotal + tax_amount;

    const x0 = MARGIN;
    const x1: f32 = 170.0;
    const x2: f32 = 500.0;
    const x3: f32 = 570.0;
    const x4: f32 = 660.0;
    const x5 = @as(f32, @floatFromInt(PAGE_WIDTH_PX)) - MARGIN;

    try w.appendSlice("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8.5in\" height=\"11in\" viewBox=\"0 0 ");
    try w.appendInt(PAGE_WIDTH_PX);
    try w.appendByte(' ');
    try w.appendInt(PAGE_HEIGHT_PX);
    try w.appendSlice("\">\n<rect x=\"0\" y=\"0\" width=\"");
    try w.appendInt(PAGE_WIDTH_PX);
    try w.appendSlice("\" height=\"");
    try w.appendInt(PAGE_HEIGHT_PX);
    try w.appendSlice("\" fill=\"#ffffff\"/>\n");

    try writeText(&w, x0, 74.0, 34, "700", "INVOICE");

    if (inv.number.len > 0) {
        try writeText(&w, x0, 108.0, 14, "700", "Invoice #");
        try writeText(&w, 148.0, 108.0, 14, "400", inv.number);
    }

    if (inv.created.len > 0) {
        try writeText(&w, x5 - 220.0, 96.0, 12, "700", "Created");
        try writeTextRight(&w, x5, 96.0, 12, "400", inv.created);
    }
    if (inv.due.len > 0) {
        try writeText(&w, x5 - 220.0, 116.0, 12, "700", "Due");
        try writeTextRight(&w, x5, 116.0, 12, "400", inv.due);
    }
    var y: f32 = 154.0;
    var f: usize = 0;
    while (f < inv.facts_len and y < 320.0) : (f += 1) {
        const fact = inv.facts[f];
        try writeText(&w, x0, y, 12, "700", fact.heading);
        try writeText(&w, 190.0, y, 12, "400", ":");
        try writeText(&w, 205.0, y, 12, "400", fact.value);
        y += 18.0;
    }

    if (y < 354.0) y = 354.0;
    const rows: usize = inv.items_len + 1;
    const table_h = ROW_H * @as(f32, @floatFromInt(rows));

    try w.appendSlice("<rect fill=\"none\" stroke=\"#111\" stroke-width=\"1\" x=\"");
    try w.appendFloat(x0);
    try w.appendSlice("\" y=\"");
    try w.appendFloat(y);
    try w.appendSlice("\" width=\"");
    try w.appendFloat(x5 - x0);
    try w.appendSlice("\" height=\"");
    try w.appendFloat(table_h);
    try w.appendSlice("\"/>\n");

    const vert = [_]f32{ x1, x2, x3, x4 };
    for (vert) |vx| {
        try w.appendSlice("<line stroke=\"#111\" stroke-width=\"1\" x1=\"");
        try w.appendFloat(vx);
        try w.appendSlice("\" y1=\"");
        try w.appendFloat(y);
        try w.appendSlice("\" x2=\"");
        try w.appendFloat(vx);
        try w.appendSlice("\" y2=\"");
        try w.appendFloat(y + table_h);
        try w.appendSlice("\"/>\n");
    }

    var r: usize = 1;
    while (r < rows) : (r += 1) {
        const ly = y + ROW_H * @as(f32, @floatFromInt(r));
        try w.appendSlice("<line stroke=\"#111\" stroke-width=\"1\" x1=\"");
        try w.appendFloat(x0);
        try w.appendSlice("\" y1=\"");
        try w.appendFloat(ly);
        try w.appendSlice("\" x2=\"");
        try w.appendFloat(x5);
        try w.appendSlice("\" y2=\"");
        try w.appendFloat(ly);
        try w.appendSlice("\"/>\n");
    }

    const header_y = y + 16.0;
    try writeText(&w, x0 + 8.0, header_y, 12, "700", "SKU");
    try writeText(&w, x1 + 8.0, header_y, 12, "700", "Description");
    try writeTextRight(&w, x3 - 8.0, header_y, 12, "700", "Qty");
    try writeTextRight(&w, x4 - 8.0, header_y, 12, "700", "Unit");
    try writeTextRight(&w, x5 - 8.0, header_y, 12, "700", "Line Total");

    r = 0;
    while (r < inv.items_len) : (r += 1) {
        const item = inv.items[r];
        const row_y = y + ROW_H * @as(f32, @floatFromInt(r + 1)) + 16.0;

        var count_buf: [32]u8 = undefined;
        const count_s = try std.fmt.bufPrint(&count_buf, "{d:g}", .{item.count});

        try writeText(&w, x0 + 8.0, row_y, 12, "400", item.sku);
        try writeText(&w, x1 + 8.0, row_y, 12, "400", item.desc);
        try writeTextRight(&w, x3 - 8.0, row_y, 12, "400", count_s);

        try w.appendSlice("<text text-anchor=\"end\" x=\"");
        try w.appendFloat(x4 - 8.0);
        try w.appendSlice("\" y=\"");
        try w.appendFloat(row_y);
        try w.appendSlice("\" font-family=\"Arial, Helvetica, sans-serif\" font-size=\"12\" font-weight=\"400\">");
        try w.appendMoney(item.cost);
        try w.appendSlice("</text>");

        try w.appendSlice("<text text-anchor=\"end\" x=\"");
        try w.appendFloat(x5 - 8.0);
        try w.appendSlice("\" y=\"");
        try w.appendFloat(row_y);
        try w.appendSlice("\" font-family=\"Arial, Helvetica, sans-serif\" font-size=\"12\" font-weight=\"400\">");
        try w.appendMoney(item.count * item.cost);
        try w.appendSlice("</text>");
    }

    const totals_y = y + table_h + 38.0;
    try writeTextRight(&w, x4 - 8.0, totals_y, 13, "700", "Subtotal");
    try w.appendSlice("<text text-anchor=\"end\" x=\"");
    try w.appendFloat(x5 - 8.0);
    try w.appendSlice("\" y=\"");
    try w.appendFloat(totals_y);
    try w.appendSlice("\" font-family=\"Arial, Helvetica, sans-serif\" font-size=\"13\" font-weight=\"400\">");
    try w.appendMoney(subtotal);
    try w.appendSlice("</text>");

    var tax_label_buf: [48]u8 = undefined;
    const tax_label = try std.fmt.bufPrint(&tax_label_buf, "Tax ({d:.2}%)", .{inv.tax_percent});
    try writeTextRight(&w, x4 - 8.0, totals_y + 22.0, 13, "700", tax_label);
    try w.appendSlice("<text text-anchor=\"end\" x=\"");
    try w.appendFloat(x5 - 8.0);
    try w.appendSlice("\" y=\"");
    try w.appendFloat(totals_y + 22.0);
    try w.appendSlice("\" font-family=\"Arial, Helvetica, sans-serif\" font-size=\"13\" font-weight=\"400\">");
    try w.appendMoney(tax_amount);
    try w.appendSlice("</text>");

    try writeTextRight(&w, x4 - 8.0, totals_y + 48.0, 15, "700", "Total");
    try w.appendSlice("<text text-anchor=\"end\" x=\"");
    try w.appendFloat(x5 - 8.0);
    try w.appendSlice("\" y=\"");
    try w.appendFloat(totals_y + 48.0);
    try w.appendSlice("\" font-family=\"Arial, Helvetica, sans-serif\" font-size=\"15\" font-weight=\"700\">");
    try w.appendMoney(total);
    try w.appendSlice("</text>");

    try w.appendSlice("</svg>");
    return @as(u32, @intCast(w.idx));
}

export fn run(input_size_in: u32) u32 {
    const size = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    const inv = parseInvoice(input_buf[0..size]);
    return renderInvoice(&inv) catch 0;
}

test "parses invoice headings and items" {
    const input =
        \\# Invoice Number
        \\INV-1042
        \\
        \\## Invoice Created Date
        \\2026-05-01
        \\
        \\## Invoice Due Date
        \\2026-05-31
        \\
        \\## Tax
        \\8.25%
        \\
        \\## Billing To
        \\Acme Corp
        \\
        \\## Items
        \\SKU-1 2@10.00 Widget A
        \\SKU-2 1@30.00 Widget B
    ;

    const inv = parseInvoice(input);
    try std.testing.expectEqualStrings("INV-1042", inv.number);
    try std.testing.expectEqualStrings("2026-05-01", inv.created);
    try std.testing.expectEqualStrings("2026-05-31", inv.due);
    try std.testing.expectApproxEqAbs(@as(f64, 8.25), inv.tax_percent, 0.0001);
    try std.testing.expectEqual(@as(usize, 1), inv.facts_len);
    try std.testing.expectEqual(@as(usize, 2), inv.items_len);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), inv.subtotal(), 0.0001);
}

test "renders letter-sized svg with totals" {
    const input =
        \\# Invoice Number
        \\INV-9
        \\
        \\## Tax
        \\10%
        \\
        \\## Items
        \\A1 2@15.00 Alpha
    ;

    const inv = parseInvoice(input);
    const out_len = try renderInvoice(&inv);
    const out = output_buf[0..out_len];

    try std.testing.expect(std.mem.indexOf(u8, out, "width=\"8.5in\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "height=\"11in\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Subtotal") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$30.00") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$3.00") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$33.00") != null);
}
