// Traps on any byte > 0x7F (must be pure ASCII).

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP;

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

export fn render(input_size_in: u32) u32 {
    var input_size: u32 = input_size_in;
    if (input_size > INPUT_CAP) {
        input_size = @intCast(INPUT_CAP);
    }

    var i: u32 = 0;
    while (i < input_size) {
        const b = input_buf[@intCast(i)];
        if (b > 0x7F) {
            @trap();
        }
        i += 1;
    }

    const out_len: usize = @intCast(input_size);
    @memcpy(output_buf[0..out_len], input_buf[0..out_len]);
    return input_size;
}