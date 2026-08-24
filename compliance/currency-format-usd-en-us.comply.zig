// Content Compliance oracle: en-US USD currency formatting.
//
// Input is one canonical ASCII decimal:
//
//     -?[0-9]+(\.[0-9]+)?
//
// The integer part is limited to 96 digits. Output uses the en-US USD
// currency pattern: a leading "$", groups of three separated by commas,
// and exactly two fractional digits. A third fractional digit of 5 or more
// rounds the magnitude up (half away from zero). The input sign is retained,
// including for negative zero. Invalid inputs must trap.
//
// This executable specification deliberately owns its parser and formatter;
// it does not import or share code with the implementation under test.
extern "qip" fn must_render_exactly(
    ordinal: u64,
    input_ptr: u32,
    input_len: u32,
    expected_ptr: u32,
    expected_len: u32,
) i32;
extern "qip" fn must_trap(ordinal: u64, input_ptr: u32, input_len: u32) i32;

const MAX_INTEGER_DIGITS: usize = 96;
const FUZZ_CASES: u32 = 64;
const MAX_INPUT: usize = 128;
const MAX_OUTPUT: usize = 140;

var input_buf: [MAX_INPUT]u8 = undefined;
var expected_buf: [MAX_OUTPUT]u8 = undefined;
var digits_buf: [MAX_INTEGER_DIGITS + 1]u8 = undefined;
var seed: u32 = 1;
var ordinal: u64 = 0;

export fn uniform_set_seed(value: i32) void {
    seed = @bitCast(value);
}

const Parsed = struct {
    negative: bool,
    integer: []const u8,
    fraction: []const u8,
};

fn parse(input: []const u8) ?Parsed {
    if (input.len == 0) return null;
    var i: usize = 0;
    const negative = input[0] == '-';
    if (negative) {
        i = 1;
        if (i == input.len) return null;
    }

    const integer_start = i;
    while (i < input.len and input[i] >= '0' and input[i] <= '9') : (i += 1) {}
    if (i == integer_start or i - integer_start > MAX_INTEGER_DIGITS) return null;
    const integer = input[integer_start..i];

    var fraction: []const u8 = "";
    if (i < input.len and input[i] == '.') {
        i += 1;
        const fraction_start = i;
        while (i < input.len and input[i] >= '0' and input[i] <= '9') : (i += 1) {}
        if (i == fraction_start) return null;
        fraction = input[fraction_start..i];
    }
    if (i != input.len) return null;
    return .{ .negative = negative, .integer = integer, .fraction = fraction };
}

fn oracle(input: []const u8, output: []u8) ?usize {
    const parsed = parse(input) orelse return null;

    var first: usize = 0;
    while (first + 1 < parsed.integer.len and parsed.integer[first] == '0') : (first += 1) {}
    const integer = parsed.integer[first..];
    for (integer, 0..) |digit, i| digits_buf[i] = digit;
    var digits_len = integer.len;

    var cents: u8 = 0;
    if (parsed.fraction.len > 0) cents = (parsed.fraction[0] - '0') * 10;
    if (parsed.fraction.len > 1) cents += parsed.fraction[1] - '0';
    if (parsed.fraction.len > 2 and parsed.fraction[2] >= '5') {
        cents += 1;
        if (cents == 100) {
            cents = 0;
            var pos = digits_len;
            while (pos > 0) {
                pos -= 1;
                if (digits_buf[pos] < '9') {
                    digits_buf[pos] += 1;
                    break;
                }
                digits_buf[pos] = '0';
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
    output[out] = '$';
    out += 1;
    for (digits_buf[0..digits_len], 0..) |digit, i| {
        if (i != 0 and (digits_len - i) % 3 == 0) {
            output[out] = ',';
            out += 1;
        }
        output[out] = digit;
        out += 1;
    }
    output[out] = '.';
    output[out + 1] = '0' + cents / 10;
    output[out + 2] = '0' + cents % 10;
    return out + 3;
}

fn declareValid(input: []const u8) void {
    const expected_len = oracle(input, expected_buf[0..]) orelse unreachable;
    _ = must_render_exactly(
        ordinal,
        @intCast(@intFromPtr(input.ptr)),
        @intCast(input.len),
        @intCast(@intFromPtr(&expected_buf)),
        @intCast(expected_len),
    );
    ordinal += 1;
}

fn declareInvalid(input: []const u8) void {
    _ = must_trap(ordinal, @intCast(@intFromPtr(input.ptr)), @intCast(input.len));
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
    if (nextRandom(rng) % 5 != 0) {
        input_buf[len] = '.';
        len += 1;
        const fraction_len = 1 + nextRandom(rng) % 8;
        i = 0;
        while (i < fraction_len) : (i += 1) {
            input_buf[len] = '0' + @as(u8, @intCast(nextRandom(rng) % 10));
            len += 1;
        }
    }
    return input_buf[0..len];
}

export fn comply() i32 {
    ordinal = 0;
    const valid = [_][]const u8{
        "0",     "-0",      "1",            "1.2",                          "1234.5", "-9876543.21", "0.004", "0.005",
        "1.999", "999.995", "000001234.50", "999999999999999999999999.995",
    };
    for (valid) |input| declareValid(input);

    const invalid = [_][]const u8{
        "", "-", ".", ".5", "1.", "+1", " 1", "1 ", "1e3", "1,000", "one", "1.2.3",
    };
    for (invalid) |input| declareInvalid(input);

    var rng: u32 = if (seed == 0) 0x9E3779B9 else seed;
    var i: u32 = 0;
    while (i < FUZZ_CASES) : (i += 1) declareValid(buildFuzzInput(&rng));
    return @intCast(ordinal);
}
