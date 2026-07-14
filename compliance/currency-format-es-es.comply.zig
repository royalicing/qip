// Content Compliance component: es-ES currency formatting selected by ISO
// 4217 numeric code. The component drives the implementation's currency
// uniform through qip.set_uniform_u32 and checks every supported currency in
// one comply() run; it does not expose a currency uniform of its own.
//
// Input is one exact ASCII decimal: -?[0-9]+(\.[0-9]+)? with at most 96
// integer digits. The selected country currency supplies a CLDR-48 es-ES
// suffix and fraction-digit count. Rounding is half away from zero. Invalid
// input traps.
const currency_data = @import("currency-format-es-es-table.zig");

extern "qip" fn render_must_equal(
    ordinal: u64,
    input_ptr: u32,
    input_len: u32,
    expected_ptr: u32,
    expected_len: u32,
) i32;
extern "qip" fn render_must_trap(ordinal: u64, input_ptr: u32, input_len: u32) i32;
extern "qip" fn set_uniform_u32(name_ptr: u32, name_len: u32, value: u32) u32;

const MAX_INTEGER_DIGITS: usize = 96;
const MAX_INPUT: usize = 128;
const MAX_OUTPUT: usize = 144;
const FUZZ_CASES: u32 = 32;

var input_buf: [MAX_INPUT]u8 = undefined;
var expected_buf: [MAX_OUTPUT]u8 = undefined;
var digits_buf: [MAX_INTEGER_DIGITS + 1]u8 = undefined;
var currency_numeric: u32 = 840;
var seed: u32 = 4217;
var ordinal: u64 = 0;

export fn uniform_set_seed(value: i32) void {
    seed = @bitCast(value);
}

fn selectedCurrency() ?currency_data.Currency {
    for (currency_data.currencies) |currency| {
        if (currency.numeric == currency_numeric) return currency;
    }
    return null;
}

fn selectCurrency(currency: currency_data.Currency) void {
    const name = "currency";
    currency_numeric = currency.numeric;
    const applied = set_uniform_u32(@intCast(@intFromPtr(name.ptr)), name.len, currency.numeric);
    if (applied != currency.numeric) @trap();
}

const Parsed = struct {
    negative: bool,
    integer: []const u8,
    fraction: []const u8,
};

fn parse(input: []const u8) ?Parsed {
    if (input.len == 0) return null;
    var cursor: usize = 0;
    const negative = input[0] == '-';
    if (negative) cursor = 1;
    if (cursor == input.len) return null;

    const integer_start = cursor;
    while (cursor < input.len and input[cursor] >= '0' and input[cursor] <= '9') : (cursor += 1) {}
    if (cursor == integer_start or cursor - integer_start > MAX_INTEGER_DIGITS) return null;
    const integer = input[integer_start..cursor];

    var fraction: []const u8 = "";
    if (cursor < input.len and input[cursor] == '.') {
        cursor += 1;
        const fraction_start = cursor;
        while (cursor < input.len and input[cursor] >= '0' and input[cursor] <= '9') : (cursor += 1) {}
        if (cursor == fraction_start) return null;
        fraction = input[fraction_start..cursor];
    }
    if (cursor != input.len) return null;
    return .{ .negative = negative, .integer = integer, .fraction = fraction };
}

fn oracle(input: []const u8, output: []u8) ?usize {
    const currency = selectedCurrency() orelse return null;
    const parsed = parse(input) orelse return null;

    var first: usize = 0;
    while (first + 1 < parsed.integer.len and parsed.integer[first] == '0') : (first += 1) {}
    const integer = parsed.integer[first..];
    for (integer, 0..) |digit, i| digits_buf[i] = digit;
    var digits_len = integer.len;

    var fraction_value: u16 = 0;
    var position: usize = 0;
    while (position < currency.fraction_digits) : (position += 1) {
        fraction_value *= 10;
        if (position < parsed.fraction.len) fraction_value += parsed.fraction[position] - '0';
    }
    if (parsed.fraction.len > currency.fraction_digits and parsed.fraction[currency.fraction_digits] >= '5') {
        fraction_value += 1;
        var scale: u16 = 1;
        position = 0;
        while (position < currency.fraction_digits) : (position += 1) scale *= 10;
        if (fraction_value == scale) {
            fraction_value = 0;
            var digit_pos = digits_len;
            while (digit_pos > 0) {
                digit_pos -= 1;
                if (digits_buf[digit_pos] < '9') {
                    digits_buf[digit_pos] += 1;
                    break;
                }
                digits_buf[digit_pos] = '0';
            } else {
                var move = digits_len;
                while (move > 0) {
                    digits_buf[move] = digits_buf[move - 1];
                    move -= 1;
                }
                digits_buf[0] = '1';
                digits_len += 1;
            }
        }
    }

    var out: usize = 0;
    if (parsed.negative) {
        output[out] = '-';
        out += 1;
    }
    for (digits_buf[0..digits_len], 0..) |digit, i| {
        if (digits_len >= 5 and i != 0 and (digits_len - i) % 3 == 0) {
            output[out] = '.';
            out += 1;
        }
        output[out] = digit;
        out += 1;
    }
    if (currency.fraction_digits > 0) {
        output[out] = ',';
        out += 1;
        var divisor: u16 = 1;
        position = 1;
        while (position < currency.fraction_digits) : (position += 1) divisor *= 10;
        position = 0;
        while (position < currency.fraction_digits) : (position += 1) {
            output[out] = '0' + @as(u8, @intCast((fraction_value / divisor) % 10));
            out += 1;
            if (divisor > 1) divisor /= 10;
        }
    }
    for (currency.suffix) |byte| {
        output[out] = byte;
        out += 1;
    }
    return out;
}

fn declareValid(input: []const u8) void {
    const expected_len = oracle(input, expected_buf[0..]) orelse unreachable;
    _ = render_must_equal(ordinal, @intCast(@intFromPtr(input.ptr)), @intCast(input.len), @intCast(@intFromPtr(&expected_buf)), @intCast(expected_len));
    ordinal += 1;
}

fn declareInvalid(input: []const u8) void {
    _ = render_must_trap(ordinal, @intCast(@intFromPtr(input.ptr)), @intCast(input.len));
    ordinal += 1;
}

fn nextRandom(state: *u32) u32 {
    var x = state.*;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    state.* = x;
    return x;
}

fn buildFuzzInput(rng: *u32) []const u8 {
    var len: usize = 0;
    if (nextRandom(rng) % 4 == 0) {
        input_buf[len] = '-';
        len += 1;
    }
    const integer_len = 1 + nextRandom(rng) % 28;
    var i: usize = 0;
    while (i < integer_len) : (i += 1) {
        input_buf[len] = '0' + @as(u8, @intCast(nextRandom(rng) % 10));
        len += 1;
    }
    input_buf[len] = '.';
    len += 1;
    const fraction_len = 1 + nextRandom(rng) % 8;
    i = 0;
    while (i < fraction_len) : (i += 1) {
        input_buf[len] = '0' + @as(u8, @intCast(nextRandom(rng) % 10));
        len += 1;
    }
    return input_buf[0..len];
}

export fn comply() i32 {
    ordinal = 0;
    const valid = [_][]const u8{
        "0", "-0", "1", "1.2", "1234.5", "1234567.89", "-9876543.21", "0.004", "0.005",
        "0.5", "1.999", "999.995", "999.9995", "000001234.50", "999999999999999999999999.995",
    };
    const invalid = [_][]const u8{ "", "-", ".5", "1.", "+1", " 1", "1e3", "1,000", "one", "1.2.3" };

    for (currency_data.currencies) |currency| {
        selectCurrency(currency);
        for (valid) |input| declareValid(input);
        for (invalid) |input| declareInvalid(input);

        var rng: u32 = if (seed == 0) 0x9E3779B9 else seed;
        var i: u32 = 0;
        while (i < FUZZ_CASES) : (i += 1) declareValid(buildFuzzInput(&rng));
    }
    return @intCast(ordinal);
}
