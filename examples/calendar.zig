const std = @import("std");

// Memory layout
const INPUT_CAP: u32 = 0x10000;
const OUTPUT_CAP: u32 = 0x10000;

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

fn getInput(size: u32) []u8 {
    return input_buf[0..@as(usize, @intCast(size))];
}

fn getOutput() []u8 {
    return output_buf[0..];
}

// Parse yyyy-mm format (e.g., "2024-03")
fn parseYearMonth(input: []const u8) !struct { year: u16, month: u8 } {
    if (input.len != 7) return error.InvalidFormat;
    if (input[4] != '-') return error.InvalidFormat;

    const year = try parseU16(input[0..4]);
    const month = try parseU8(input[5..7]);

    if (month < 1 or month > 12) return error.InvalidMonth;

    return .{ .year = year, .month = month };
}

fn parseU16(s: []const u8) !u16 {
    var result: u16 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return error.InvalidDigit;
        result = result * 10 + (c - '0');
    }
    return result;
}

fn parseU8(s: []const u8) !u8 {
    var result: u8 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return error.InvalidDigit;
        result = result * 10 + (c - '0');
    }
    return result;
}

// Check if a year is a leap year
fn isLeapYear(year: u16) bool {
    if (year % 400 == 0) return true;
    if (year % 100 == 0) return false;
    if (year % 4 == 0) return true;
    return false;
}

// Get number of days in a month
fn getDaysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

// Calculate day of week using Zeller's congruence (0=Monday, 1=Tuesday, ..., 6=Sunday)
fn getDayOfWeek(year: u16, month: u8, day: u8) u8 {
    var y: i32 = @as(i32, year);
    var m: i32 = @as(i32, month);

    // Adjust for Zeller's congruence (January and February are months 13 and 14 of previous year)
    if (m < 3) {
        m += 12;
        y -= 1;
    }

    const q: i32 = @as(i32, day);
    const k: i32 = @mod(y, 100);
    const j: i32 = @divFloor(y, 100);

    // Zeller's congruence formula
    var h: i32 = q + @divFloor(13 * (m + 1), 5) + k + @divFloor(k, 4) + @divFloor(j, 4) - 2 * j;
    h = @mod(h, 7);

    // Convert from Zeller's (0=Saturday) to our convention (0=Monday)
    // Zeller: 0=Sat, 1=Sun, 2=Mon, 3=Tue, 4=Wed, 5=Thu, 6=Fri
    // Target: 0=Mon, 1=Tue, 2=Wed, 3=Thu, 4=Fri, 5=Sat, 6=Sun
    const adjusted = @mod((h + 5), 7);
    return @as(u8, @intCast(adjusted));
}

// Write helpers
fn writeStr(buf: []u8, offset: *usize, s: []const u8) void {
    for (s) |c| {
        if (offset.* >= buf.len) return;
        buf[offset.*] = c;
        offset.* += 1;
    }
}

fn writeU8(buf: []u8, offset: *usize, n: u8) void {
    if (n >= 10) {
        if (offset.* >= buf.len) return;
        buf[offset.*] = '0' + (n / 10);
        offset.* += 1;
    }
    if (offset.* >= buf.len) return;
    buf[offset.*] = '0' + (n % 10);
    offset.* += 1;
}

fn writeU16(buf: []u8, offset: *usize, n: u16) void {
    var num = n;
    var divisor: u16 = 1000;
    var started = false;

    while (divisor > 0) : (divisor /= 10) {
        const digit = @as(u8, @intCast(num / divisor));
        if (digit > 0 or started or divisor == 1) {
            if (offset.* >= buf.len) return;
            buf[offset.*] = '0' + digit;
            offset.* += 1;
            started = true;
        }
        num = num % divisor;
    }
}

fn renderCalendar(output: []u8, year: u16, month: u8) u32 {
    var offset: usize = 0;

    // Write month and year header
    const month_names = [_][]const u8{
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    };

    const month_name = month_names[month - 1];
    writeStr(output, &offset, month_name);
    writeStr(output, &offset, " ");
    writeU16(output, &offset, year);
    writeStr(output, &offset, "\n");

    // Write weekday headers (starting Monday)
    writeStr(output, &offset, "Mo Tu We Th Fr Sa Su\n");

    // Calculate first day of month
    const first_day_of_week = getDayOfWeek(year, month, 1);
    const days_in_month = getDaysInMonth(year, month);

    // Write leading spaces for days before the first of the month
    var i: u8 = 0;
    while (i < first_day_of_week) : (i += 1) {
        writeStr(output, &offset, "   ");
    }

    // Write days of the month
    var day: u8 = 1;
    var current_day_of_week = first_day_of_week;

    while (day <= days_in_month) : (day += 1) {
        // Pad single-digit days with a space
        if (day < 10) {
            writeStr(output, &offset, " ");
        }
        writeU8(output, &offset, day);

        current_day_of_week += 1;

        // Add space after day or newline at end of week
        if (current_day_of_week == 7) {
            writeStr(output, &offset, "\n");
            current_day_of_week = 0;
        } else if (day < days_in_month) {
            writeStr(output, &offset, " ");
        }
    }

    // Add final newline if we didn't end on Sunday
    if (current_day_of_week != 0) {
        writeStr(output, &offset, "\n");
    }

    return @as(u32, @intCast(offset));
}

// Main entry point
export fn run(input_size: u32) u32 {
    const input = getInput(input_size);
    const output = getOutput();

    // Parse input
    const parsed = parseYearMonth(input) catch {
        // Return error message on invalid input
        var offset: usize = 0;
        writeStr(output, &offset, "Error: Expected format yyyy-mm (e.g., 2024-03)\n");
        return @as(u32, @intCast(offset));
    };

    // Render calendar
    return renderCalendar(output, parsed.year, parsed.month);
}

// Tests
test "parseYearMonth" {
    const result = try parseYearMonth("2024-03");
    try std.testing.expectEqual(@as(u16, 2024), result.year);
    try std.testing.expectEqual(@as(u8, 3), result.month);
}

test "isLeapYear" {
    try std.testing.expect(isLeapYear(2000));
    try std.testing.expect(!isLeapYear(1900));
    try std.testing.expect(isLeapYear(2024));
    try std.testing.expect(!isLeapYear(2023));
}

test "getDaysInMonth" {
    try std.testing.expectEqual(@as(u8, 31), getDaysInMonth(2024, 1));
    try std.testing.expectEqual(@as(u8, 29), getDaysInMonth(2024, 2));
    try std.testing.expectEqual(@as(u8, 28), getDaysInMonth(2023, 2));
    try std.testing.expectEqual(@as(u8, 30), getDaysInMonth(2024, 4));
}

test "getDayOfWeek" {
    // 2024-01-01 is a Monday (0)
    try std.testing.expectEqual(@as(u8, 0), getDayOfWeek(2024, 1, 1));
    // 2024-03-01 is a Friday (4)
    try std.testing.expectEqual(@as(u8, 4), getDayOfWeek(2024, 3, 1));
    // 2024-12-25 is a Wednesday (2)
    try std.testing.expectEqual(@as(u8, 2), getDayOfWeek(2024, 12, 25));
}
