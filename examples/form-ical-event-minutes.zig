const std = @import("std");

const INPUT_CAP: u32 = 1024;
const OUTPUT_CAP: u32 = 8192;
const TITLE_CAP: usize = 256;
const MAX_DURATION_MINUTES: u32 = 7 * 24 * 60;

const KEY_TITLE = "title";
const KEY_DATE = "date";
const KEY_START_TIME = "start_time";
const KEY_DURATION_MINUTES = "duration_minutes";

const LABEL_TITLE = "Event title";
const LABEL_DATE = "Event date (YYYY-MM-DD)";
const LABEL_START_TIME = "Start time (HH:MM)";
const LABEL_DURATION_MINUTES = "Duration in minutes";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var error_buf: [256]u8 = undefined;
var error_len: u32 = 0;

var step: u32 = 0;
var title_buf: [TITLE_CAP]u8 = undefined;
var title_len: u32 = 0;
var event_date: Date = .{ .year = 1970, .month = 1, .day = 1 };
var start_hour: u8 = 0;
var start_minute: u8 = 0;
var duration_minutes: u32 = 60;

const Date = struct {
    year: u16,
    month: u8,
    day: u8,
};

const DateTime = struct {
    date: Date,
    hour: u8,
    minute: u8,
};

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
        2 => @as(u32, @intCast(@intFromPtr(KEY_START_TIME.ptr))),
        3 => @as(u32, @intCast(@intFromPtr(KEY_DURATION_MINUTES.ptr))),
        else => 0,
    };
}

export fn input_key_len() u32 {
    return switch (step) {
        0 => @as(u32, @intCast(KEY_TITLE.len)),
        1 => @as(u32, @intCast(KEY_DATE.len)),
        2 => @as(u32, @intCast(KEY_START_TIME.len)),
        3 => @as(u32, @intCast(KEY_DURATION_MINUTES.len)),
        else => 0,
    };
}

export fn input_label_ptr() u32 {
    return switch (step) {
        0 => @as(u32, @intCast(@intFromPtr(LABEL_TITLE.ptr))),
        1 => @as(u32, @intCast(@intFromPtr(LABEL_DATE.ptr))),
        2 => @as(u32, @intCast(@intFromPtr(LABEL_START_TIME.ptr))),
        3 => @as(u32, @intCast(@intFromPtr(LABEL_DURATION_MINUTES.ptr))),
        else => 0,
    };
}

export fn input_label_len() u32 {
    return switch (step) {
        0 => @as(u32, @intCast(LABEL_TITLE.len)),
        1 => @as(u32, @intCast(LABEL_DATE.len)),
        2 => @as(u32, @intCast(LABEL_START_TIME.len)),
        3 => @as(u32, @intCast(LABEL_DURATION_MINUTES.len)),
        else => 0,
    };
}

export fn error_message_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&error_buf)));
}

export fn error_message_len() u32 {
    return error_len;
}

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

fn parseTimeHHMM(s: []const u8) ?struct { hour: u8, minute: u8 } {
    if (s.len != 5) return null;
    if (s[2] != ':') return null;
    const hour = parseAsciiInt(u8, s[0..2]) orelse return null;
    const minute = parseAsciiInt(u8, s[3..5]) orelse return null;
    if (hour > 23 or minute > 59) return null;
    return .{ .hour = hour, .minute = minute };
}

fn nextDay(date: Date) Date {
    const dim = daysInMonth(date.year, date.month);
    if (date.day < dim) return .{ .year = date.year, .month = date.month, .day = date.day + 1 };
    if (date.month < 12) return .{ .year = date.year, .month = date.month + 1, .day = 1 };
    return .{ .year = date.year + 1, .month = 1, .day = 1 };
}

fn addMinutes(start: DateTime, minutes: u32) DateTime {
    var total: u32 = @as(u32, start.hour) * 60 + @as(u32, start.minute) + minutes;
    var date = start.date;
    while (total >= 24 * 60) {
        total -= 24 * 60;
        date = nextDay(date);
    }
    return .{
        .date = date,
        .hour = @as(u8, @intCast(total / 60)),
        .minute = @as(u8, @intCast(total % 60)),
    };
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

fn writeTimeCompact(out: *[6]u8, hour: u8, minute: u8) void {
    out[0] = @as(u8, @intCast('0' + (hour / 10) % 10));
    out[1] = @as(u8, @intCast('0' + hour % 10));
    out[2] = @as(u8, @intCast('0' + (minute / 10) % 10));
    out[3] = @as(u8, @intCast('0' + minute % 10));
    out[4] = '0';
    out[5] = '0';
}

fn storeTitle(input: []const u8) bool {
    const t = trimASCII(input);
    if (t.len == 0) {
        setError("Event title is required.");
        return false;
    }
    if (t.len > title_buf.len) {
        setError("Event title is too long.");
        return false;
    }
    for (t) |ch| {
        if (ch == '\n' or ch == '\r') {
            setError("Event title must be a single line.");
            return false;
        }
    }
    @memcpy(title_buf[0..t.len], t);
    title_len = @as(u32, @intCast(t.len));
    return true;
}

fn storeDate(input: []const u8) bool {
    const t = trimASCII(input);
    const parsed = parseDateYYYYMMDD(t) orelse {
        setError("Date must be a valid YYYY-MM-DD value.");
        return false;
    };
    event_date = parsed;
    return true;
}

fn storeStartTime(input: []const u8) bool {
    const t = trimASCII(input);
    const parsed = parseTimeHHMM(t) orelse {
        setError("Start time must be a valid HH:MM value.");
        return false;
    };
    start_hour = parsed.hour;
    start_minute = parsed.minute;
    return true;
}

fn storeDurationMinutes(input: []const u8) bool {
    const t = trimASCII(input);
    if (t.len == 0) {
        setError("Duration is required.");
        return false;
    }
    const parsed = parseAsciiInt(u32, t) orelse {
        setError("Duration must be an integer number of minutes.");
        return false;
    };
    if (parsed == 0) {
        setError("Duration must be at least 1 minute.");
        return false;
    }
    if (parsed > MAX_DURATION_MINUTES) {
        setError("Duration is too large.");
        return false;
    }
    duration_minutes = parsed;
    return true;
}

fn buildICS() u32 {
    const start = DateTime{
        .date = event_date,
        .hour = start_hour,
        .minute = start_minute,
    };
    const end = addMinutes(start, duration_minutes);

    var start_date_compact: [8]u8 = undefined;
    var end_date_compact: [8]u8 = undefined;
    var start_time_compact: [6]u8 = undefined;
    var end_time_compact: [6]u8 = undefined;
    writeDateCompact(&start_date_compact, start.date);
    writeDateCompact(&end_date_compact, end.date);
    writeTimeCompact(&start_time_compact, start.hour, start.minute);
    writeTimeCompact(&end_time_compact, end.hour, end.minute);

    const title = title_buf[0..@as(usize, @intCast(title_len))];

    var w = Writer{};
    w.writeSlice("BEGIN:VCALENDAR\r\n");
    w.writeSlice("VERSION:2.0\r\n");
    w.writeSlice("PRODID:-//qip//Form Calendar//EN\r\n");
    w.writeSlice("CALSCALE:GREGORIAN\r\n");
    w.writeSlice("BEGIN:VEVENT\r\n");
    w.writeSlice("UID:qip-form-");
    w.writeSlice(start_date_compact[0..]);
    w.writeSlice("T");
    w.writeSlice(start_time_compact[0..]);
    w.writeSlice("@example.com\r\n");
    w.writeSlice("DTSTAMP:");
    w.writeSlice(start_date_compact[0..]);
    w.writeSlice("T000000Z\r\n");
    w.writeSlice("SUMMARY:");
    w.writeSlice(title);
    w.writeSlice("\r\n");
    w.writeSlice("DTSTART:");
    w.writeSlice(start_date_compact[0..]);
    w.writeSlice("T");
    w.writeSlice(start_time_compact[0..]);
    w.writeSlice("\r\n");
    w.writeSlice("DTEND:");
    w.writeSlice(end_date_compact[0..]);
    w.writeSlice("T");
    w.writeSlice(end_time_compact[0..]);
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
        return 0;
    }
    if (step == 2) {
        if (!storeStartTime(input)) return 0;
        step = 3;
        return 0;
    }
    if (step == 3) {
        if (!storeDurationMinutes(input)) return 0;
        step = 4;
        return buildICS();
    }
    return buildICS();
}

fn resetState() void {
    step = 0;
    title_len = 0;
    error_len = 0;
    event_date = .{ .year = 1970, .month = 1, .day = 1 };
    start_hour = 0;
    start_minute = 0;
    duration_minutes = 60;
}

fn feed(input: []const u8) u32 {
    @memcpy(input_buf[0..input.len], input);
    return run(@as(u32, @intCast(input.len)));
}

test "successful flow outputs timed event with duration" {
    resetState();
    try std.testing.expectEqual(@as(u32, 0), feed("Team Sync"));
    try std.testing.expectEqual(@as(u32, @intCast(KEY_DATE.len)), input_key_len());
    try std.testing.expectEqual(@as(u32, 0), feed("2026-03-14"));
    try std.testing.expectEqual(@as(u32, @intCast(KEY_START_TIME.len)), input_key_len());
    try std.testing.expectEqual(@as(u32, 0), feed("09:30"));
    try std.testing.expectEqual(@as(u32, @intCast(KEY_DURATION_MINUTES.len)), input_key_len());
    const out_len = feed("90");
    try std.testing.expect(out_len > 0);
    try std.testing.expectEqual(@as(u32, 0), input_key_len());

    const out = output_buf[0..@as(usize, @intCast(out_len))];
    try std.testing.expect(std.mem.indexOf(u8, out, "SUMMARY:Team Sync\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "DTSTART:20260314T093000\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "DTEND:20260314T110000\r\n") != null);
}

test "duration can roll to next day" {
    resetState();
    _ = feed("Overnight");
    _ = feed("2026-03-14");
    _ = feed("23:30");
    const out_len = feed("120");
    const out = output_buf[0..@as(usize, @intCast(out_len))];
    try std.testing.expect(std.mem.indexOf(u8, out, "DTEND:20260315T013000\r\n") != null);
}

test "invalid duration keeps step and sets error" {
    resetState();
    _ = feed("Demo");
    _ = feed("2026-03-14");
    _ = feed("10:00");
    try std.testing.expectEqual(@as(u32, 0), feed("0"));
    try std.testing.expectEqual(@as(u32, @intCast(KEY_DURATION_MINUTES.len)), input_key_len());
    try std.testing.expect(error_message_len() > 0);
}
