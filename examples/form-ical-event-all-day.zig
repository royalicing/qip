const std = @import("std");

const INPUT_CAP: u32 = 1024;
const OUTPUT_CAP: u32 = 8192;
const TITLE_CAP: usize = 256;

const KEY_TITLE = "title";
const KEY_DATE = "date";
const LABEL_TITLE = "Event title";
const LABEL_DATE = "Event date (YYYY-MM-DD)";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var error_buf: [256]u8 = undefined;
var error_len: u32 = 0;

var step: u32 = 0;
var title_buf: [TITLE_CAP]u8 = undefined;
var title_len: u32 = 0;
var date_buf: [10]u8 = undefined; // YYYY-MM-DD

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

export fn input_key_ptr() u32 {
    return switch (step) {
        0 => @as(u32, @intCast(@intFromPtr(KEY_TITLE.ptr))),
        1 => @as(u32, @intCast(@intFromPtr(KEY_DATE.ptr))),
        else => 0,
    };
}

export fn input_key_len() u32 {
    return switch (step) {
        0 => @as(u32, @intCast(KEY_TITLE.len)),
        1 => @as(u32, @intCast(KEY_DATE.len)),
        else => 0,
    };
}

export fn input_label_ptr() u32 {
    return switch (step) {
        0 => @as(u32, @intCast(@intFromPtr(LABEL_TITLE.ptr))),
        1 => @as(u32, @intCast(@intFromPtr(LABEL_DATE.ptr))),
        else => 0,
    };
}

export fn input_label_len() u32 {
    return switch (step) {
        0 => @as(u32, @intCast(LABEL_TITLE.len)),
        1 => @as(u32, @intCast(LABEL_DATE.len)),
        else => 0,
    };
}

export fn error_message_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&error_buf)));
}

export fn error_message_len() u32 {
    return error_len;
}

const Date = struct {
    year: u16,
    month: u8,
    day: u8,
};

const Writer = struct {
    idx: usize = 0,
    overflow: bool = false,

    fn writeSlice(self: *Writer, s: []const u8) void {
        if (self.overflow) return;
        if (self.idx + s.len > output_buf.len) {
            self.overflow = true;
            return;
        }
        @memcpy(output_buf[self.idx..][0..s.len], s);
        self.idx += s.len;
    }
};

fn resetError() void {
    error_len = 0;
}

fn setError(msg: []const u8) void {
    const n = @min(msg.len, error_buf.len);
    if (n > 0) @memcpy(error_buf[0..n], msg[0..n]);
    error_len = @as(u32, @intCast(n));
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

fn trimASCII(input: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = input.len;
    while (start < end and isSpace(input[start])) : (start += 1) {}
    while (end > start and isSpace(input[end - 1])) : (end -= 1) {}
    return input[start..end];
}

fn storeTitle(input: []const u8) bool {
    const title = trimASCII(input);
    if (title.len == 0) {
        setError("Event title is required.");
        return false;
    }
    if (title.len > title_buf.len) {
        setError("Event title is too long.");
        return false;
    }
    @memcpy(title_buf[0..title.len], title);
    title_len = @as(u32, @intCast(title.len));
    return true;
}

fn parseAsciiInt(comptime T: type, s: []const u8) ?T {
    var v: T = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return null;
        v = v * 10 + @as(T, ch - '0');
    }
    return v;
}

fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn parseDateYYYYMMDD(s: []const u8) ?Date {
    if (s.len != 10) return null;
    if (s[4] != '-' or s[7] != '-') return null;

    const year = parseAsciiInt(u16, s[0..4]) orelse return null;
    const month = parseAsciiInt(u8, s[5..7]) orelse return null;
    const day = parseAsciiInt(u8, s[8..10]) orelse return null;
    if (month < 1 or month > 12) return null;

    const dim = daysInMonth(year, month);
    if (day < 1 or day > dim) return null;

    return Date{ .year = year, .month = month, .day = day };
}

fn nextDay(date: Date) Date {
    const dim = daysInMonth(date.year, date.month);
    if (date.day < dim) {
        return Date{ .year = date.year, .month = date.month, .day = date.day + 1 };
    }
    if (date.month < 12) {
        return Date{ .year = date.year, .month = date.month + 1, .day = 1 };
    }
    return Date{ .year = date.year + 1, .month = 1, .day = 1 };
}

fn writeDateCompact(out: *[8]u8, date: Date) void {
    out[0] = @as(u8, @intCast('0' + (date.year / 1000) % 10));
    out[1] = @as(u8, @intCast('0' + (date.year / 100) % 10));
    out[2] = @as(u8, @intCast('0' + (date.year / 10) % 10));
    out[3] = @as(u8, @intCast('0' + date.year % 10));
    out[4] = @as(u8, @intCast('0' + (date.month / 10) % 10));
    out[5] = @as(u8, @intCast('0' + date.month % 10));
    out[6] = @as(u8, @intCast('0' + (date.day / 10) % 10));
    out[7] = @as(u8, @intCast('0' + date.day % 10));
}

fn storeDate(input: []const u8) bool {
    const date_text = trimASCII(input);
    const date = parseDateYYYYMMDD(date_text) orelse {
        setError("Date must be a valid YYYY-MM-DD value.");
        return false;
    };
    _ = date;
    @memcpy(date_buf[0..10], date_text[0..10]);
    return true;
}

fn buildICS() u32 {
    const date = parseDateYYYYMMDD(date_buf[0..10]) orelse {
        setError("Internal date parse error.");
        return 0;
    };
    const date_end = nextDay(date);

    var compact_start: [8]u8 = undefined;
    var compact_end: [8]u8 = undefined;
    writeDateCompact(&compact_start, date);
    writeDateCompact(&compact_end, date_end);

    const title = title_buf[0..@as(usize, @intCast(title_len))];

    var w = Writer{};
    w.writeSlice("BEGIN:VCALENDAR\r\n");
    w.writeSlice("VERSION:2.0\r\n");
    w.writeSlice("PRODID:-//qip//Form Calendar//EN\r\n");
    w.writeSlice("CALSCALE:GREGORIAN\r\n");
    w.writeSlice("BEGIN:VEVENT\r\n");
    w.writeSlice("UID:qip-form-");
    w.writeSlice(compact_start[0..]);
    w.writeSlice("@example.com\r\n");
    w.writeSlice("DTSTAMP:");
    w.writeSlice(compact_start[0..]);
    w.writeSlice("T000000Z\r\n");
    w.writeSlice("SUMMARY:");
    w.writeSlice(title);
    w.writeSlice("\r\n");
    w.writeSlice("DTSTART;VALUE=DATE:");
    w.writeSlice(compact_start[0..]);
    w.writeSlice("\r\n");
    w.writeSlice("DTEND;VALUE=DATE:");
    w.writeSlice(compact_end[0..]);
    w.writeSlice("\r\n");
    w.writeSlice("END:VEVENT\r\n");
    w.writeSlice("END:VCALENDAR\r\n");

    if (w.overflow) {
        setError("Generated calendar exceeded output capacity.");
        return 0;
    }
    return @as(u32, @intCast(w.idx));
}

export fn run(input_size: u32) u32 {
    const bounded_input_size = @min(input_size, INPUT_CAP);
    const input = input_buf[0..@as(usize, @intCast(bounded_input_size))];
    resetError();

    if (step == 0) {
        if (!storeTitle(input)) return 0;
        step = 1;
        return 0;
    }
    if (step == 1) {
        if (!storeDate(input)) return 0;
        step = 2;
        return buildICS();
    }

    return buildICS();
}

fn resetState() void {
    step = 0;
    title_len = 0;
    error_len = 0;
}

test "successful flow outputs simple ical event" {
    resetState();

    const t = "Team Sync";
    @memcpy(input_buf[0..t.len], t);
    try std.testing.expectEqual(@as(u32, 0), run(@as(u32, @intCast(t.len))));
    try std.testing.expectEqual(@as(u32, @intCast(KEY_DATE.len)), input_key_len());

    const d = "2026-03-14";
    @memcpy(input_buf[0..d.len], d);
    const out_len = run(@as(u32, @intCast(d.len)));
    try std.testing.expect(out_len > 0);
    try std.testing.expectEqual(@as(u32, 0), input_key_len());

    const out = output_buf[0..@as(usize, @intCast(out_len))];
    try std.testing.expect(std.mem.indexOf(u8, out, "BEGIN:VCALENDAR\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SUMMARY:Team Sync\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "DTSTART;VALUE=DATE:20260314\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "DTEND;VALUE=DATE:20260315\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "END:VCALENDAR\r\n") != null);
}

test "invalid title keeps step and sets error" {
    resetState();
    const t = "   ";
    @memcpy(input_buf[0..t.len], t);
    try std.testing.expectEqual(@as(u32, 0), run(@as(u32, @intCast(t.len))));
    try std.testing.expectEqual(@as(u32, @intCast(KEY_TITLE.len)), input_key_len());
    try std.testing.expect(error_message_len() > 0);
}

test "invalid date keeps step and sets error" {
    resetState();

    const t = "Demo";
    @memcpy(input_buf[0..t.len], t);
    _ = run(@as(u32, @intCast(t.len)));
    try std.testing.expectEqual(@as(u32, @intCast(KEY_DATE.len)), input_key_len());

    const d = "2026-02-30";
    @memcpy(input_buf[0..d.len], d);
    try std.testing.expectEqual(@as(u32, 0), run(@as(u32, @intCast(d.len))));
    try std.testing.expectEqual(@as(u32, @intCast(KEY_DATE.len)), input_key_len());
    try std.testing.expect(error_message_len() > 0);
}
