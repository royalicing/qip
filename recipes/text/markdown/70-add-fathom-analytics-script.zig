const std = @import("std");

const INPUT_CAP: u32 = 0x80000;
const OUTPUT_CAP: u32 = INPUT_CAP + @as(u32, @intCast(FATHOM_SNIPPET.len));
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "text/html";
const FATHOM_SNIPPET =
    "<script src=\"https://cdn.usefathom.com/script.js\" data-site=\"WSANBNEG\" defer></script>\n";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

export fn input_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr)));
}

export fn input_content_type_size() u32 {
    return @as(u32, @intCast(INPUT_CONTENT_TYPE.len));
}

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(OUTPUT_CONTENT_TYPE.len));
}

fn injectFathom(input: []const u8, output: []u8) usize {
    const required = input.len + FATHOM_SNIPPET.len;
    if (required > output.len) @panic("output buffer overflow");

    @memcpy(output[0..FATHOM_SNIPPET.len], FATHOM_SNIPPET);
    @memcpy(output[FATHOM_SNIPPET.len..required], input);
    return required;
}

fn renderImpl(input_size: u32) u32 {
    const size = @as(usize, @intCast(input_size));
    const input = input_buf[0..size];
    const output = output_buf[0..];
    const written = injectFathom(input, output);
    return @as(u32, @intCast(written));
}

export fn render(input_size: u32) packed struct(u64) {
    output_size: u32,
    output_ptr: u31,
    failed: u1,
} {
    return .{
        .output_size = renderImpl(input_size),
        .output_ptr = @intCast(@intFromPtr(&output_buf)),
        .failed = 0,
    };
}

test "prepends snippet to html" {
    const input = "<!doctype html><html><head><meta charset=\"utf-8\"></head><body>ok</body></html>";
    const expected = FATHOM_SNIPPET ++ input;
    var out: [expected.len]u8 = undefined;
    const written = injectFathom(input, out[0..]);
    try std.testing.expectEqualStrings(expected, out[0..written]);
}
