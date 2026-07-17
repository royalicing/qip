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

fn continuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn utf8Length(bytes: []const u8, i: usize) ?usize {
    const first = bytes[i];
    if (first <= 0x7f) return if (first == 0) null else 1;
    if (first >= 0xc2 and first <= 0xdf and i + 1 < bytes.len and continuation(bytes[i + 1])) return 2;
    if (first == 0xe0 and i + 2 < bytes.len and bytes[i + 1] >= 0xa0 and bytes[i + 1] <= 0xbf and continuation(bytes[i + 2])) return 3;
    if (first >= 0xe1 and first <= 0xec and i + 2 < bytes.len and continuation(bytes[i + 1]) and continuation(bytes[i + 2])) return 3;
    if (first == 0xed and i + 2 < bytes.len and bytes[i + 1] >= 0x80 and bytes[i + 1] <= 0x9f and continuation(bytes[i + 2])) return 3;
    if (first >= 0xee and first <= 0xef and i + 2 < bytes.len and continuation(bytes[i + 1]) and continuation(bytes[i + 2])) return 3;
    if (first == 0xf0 and i + 3 < bytes.len and bytes[i + 1] >= 0x90 and bytes[i + 1] <= 0xbf and continuation(bytes[i + 2]) and continuation(bytes[i + 3])) return 4;
    if (first >= 0xf1 and first <= 0xf3 and i + 3 < bytes.len and continuation(bytes[i + 1]) and continuation(bytes[i + 2]) and continuation(bytes[i + 3])) return 4;
    if (first == 0xf4 and i + 3 < bytes.len and bytes[i + 1] >= 0x80 and bytes[i + 1] <= 0x8f and continuation(bytes[i + 2]) and continuation(bytes[i + 3])) return 4;
    return null;
}

export fn render(input_size: u32) u32 {
    const size: usize = @intCast(input_size);
    if (size == 0 or size > INPUT_CAP) @trap();
    const input = input_buf[0..size];

    var i: usize = 0;
    var steps: usize = 0;
    while (i < input.len and steps < INPUT_CAP) : (steps += 1) {
        i += utf8Length(input, i) orelse @trap();
    }
    if (i != input.len) @trap();
    @memcpy(output_buf[0..size], input);
    return @intCast(size);
}
