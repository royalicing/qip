// utf8-must-be-valid.zig
// Traps on invalid UTF-8 input.

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

fn isContinuation(b: u8) bool {
    return (b & 0xC0) == 0x80;
}

export fn run(input_size_in: u32) u32 {
    var input_size: u32 = input_size_in;
    if (input_size > INPUT_CAP) {
        input_size = @intCast(INPUT_CAP);
    }

    var i: u32 = 0;
    while (i < input_size) {
        const b = input_buf[@intCast(i)];
        if (b <= 0x7F) {
            i += 1;
            continue;
        }
        if (b >= 0xC2 and b <= 0xDF) {
            if (i + 1 >= input_size) @trap();
            const b2 = input_buf[@intCast(i + 1)];
            if (!isContinuation(b2)) @trap();
            i += 2;
            continue;
        }
        if (b >= 0xE0 and b <= 0xEF) {
            if (i + 2 >= input_size) @trap();
            const b2 = input_buf[@intCast(i + 1)];
            const b3 = input_buf[@intCast(i + 2)];
            if (!isContinuation(b2) or !isContinuation(b3)) @trap();
            if (b == 0xE0 and b2 < 0xA0) @trap();
            if (b == 0xED and b2 >= 0xA0) @trap();
            i += 3;
            continue;
        }
        if (b >= 0xF0 and b <= 0xF4) {
            if (i + 3 >= input_size) @trap();
            const b2 = input_buf[@intCast(i + 1)];
            const b3 = input_buf[@intCast(i + 2)];
            const b4 = input_buf[@intCast(i + 3)];
            if (!isContinuation(b2) or !isContinuation(b3) or !isContinuation(b4)) @trap();
            if (b == 0xF0 and b2 < 0x90) @trap();
            if (b == 0xF4 and b2 >= 0x90) @trap();
            i += 4;
            continue;
        }
        @trap();
    }

    const out_len: usize = @intCast(input_size);
    @memcpy(output_buf[0..out_len], input_buf[0..out_len]);
    return input_size;
}
