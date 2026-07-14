const INPUT_CAP: usize = 64 * 1024;
const OUTPUT_CAP: usize = 64 * 1024;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buf));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_ptr() u32 {
    return @intCast(@intFromPtr(&output_buf));
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

fn isAsciiWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0c;
}

export fn render(input_size: u32) u32 {
    const size: usize = @intCast(input_size);
    if (size == 0 or size > INPUT_CAP) @trap();

    var i: usize = 0;
    while (i < size) : (i += 1) {
        if (isAsciiWhitespace(input_buf[i])) @trap();
    }
    @memcpy(output_buf[0..size], input_buf[0..size]);
    return @intCast(size);
}
