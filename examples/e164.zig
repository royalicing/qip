const INPUT_CAP: usize = 64 * 1024;
const OUTPUT_CAP: usize = 64 * 1024;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

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

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

export fn run(input_size_in: u32) u32 {
    const input_size: usize = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);

    // Emit '+' then append only digits.
    output_buf[0] = '+';
    var out: usize = 1;

    var i: usize = 0;
    while (i < input_size) : (i += 1) {
        const c = input_buf[i];
        if (!isDigit(c)) continue;

        if (out >= OUTPUT_CAP) return 0;
        output_buf[out] = c;
        out += 1;
    }

    // Invalid when no digits were present.
    if (out == 1) return 0;

    return @as(u32, @intCast(out));
}
