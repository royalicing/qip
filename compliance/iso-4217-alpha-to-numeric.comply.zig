// Content Compliance oracle: ISO 4217 alphabetic code to numeric code.
// Every current List One mapping is declared. Input must be exactly three
// uppercase ASCII letters; output is exactly three ASCII digits.
const table = @import("iso-4217-alpha-numeric-table.zig");

extern "qip" fn must_render_exactly(
    ordinal: u64,
    input_ptr: u32,
    input_len: u32,
    expected_ptr: u32,
    expected_len: u32,
) i32;
extern "qip" fn must_trap(ordinal: u64, input_ptr: u32, input_len: u32) i32;

var input_buf: [3]u8 = undefined;
var expected_buf: [3]u8 = undefined;
var ordinal: u64 = 0;

// The corpus is exhaustive, so seed deliberately has no effect.
export fn uniform_set_seed(_: i32) void {}

fn unpackAlpha(value: u32) void {
    input_buf[0] = @intCast((value >> 16) & 0xFF);
    input_buf[1] = @intCast((value >> 8) & 0xFF);
    input_buf[2] = @intCast(value & 0xFF);
}

fn unpackNumeric(numeric: u16) void {
    expected_buf[0] = '0' + @as(u8, @intCast(numeric / 100));
    expected_buf[1] = '0' + @as(u8, @intCast((numeric / 10) % 10));
    expected_buf[2] = '0' + @as(u8, @intCast(numeric % 10));
}

fn declareMapping(entry: table.Entry) void {
    unpackAlpha(entry.alpha);
    unpackNumeric(entry.numeric);
    _ = must_render_exactly(
        ordinal,
        @intCast(@intFromPtr(&input_buf)),
        input_buf.len,
        @intCast(@intFromPtr(&expected_buf)),
        expected_buf.len,
    );
    ordinal += 1;
}

fn declareInvalid(input: []const u8) void {
    _ = must_trap(ordinal, @intCast(@intFromPtr(input.ptr)), @intCast(input.len));
    ordinal += 1;
}

export fn comply() i32 {
    ordinal = 0;
    for (table.entries) |entry| declareMapping(entry);
    const invalid = [_][]const u8{ "", "US", "USDD", "usd", "123", "U$D", " USD", "ZZZ" };
    for (invalid) |input| declareInvalid(input);
    return @intCast(ordinal);
}
