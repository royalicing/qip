const std = @import("std");

const INPUT_CAP: u32 = 0x80000;
const OUTPUT_CAP: u32 = INPUT_CAP + @as(u32, @intCast(COPY_CODE_SNIPPET.len));
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "text/html";
const COPY_CODE_SNIPPET =
    \\<style>
    \\copy-code { display: block; margin-block-end: 1rlh; }
    \\copy-code > pre { margin-block-end: 0.5rlh; }
    \\copy-code > button { display: block; font: inherit; }
    \\</style>
    \\<script type="module" src="/copy-code.js"></script>
;

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

fn injectCopyCode(input: []const u8, output: []u8) usize {
    const required = input.len + COPY_CODE_SNIPPET.len;
    if (required > output.len) @panic("output buffer overflow");

    const insertion: ?usize = if (std.mem.indexOf(u8, input, "</head>")) |head_end|
        head_end
    else if (std.mem.indexOf(u8, input, "</style>")) |style_end|
        style_end + "</style>".len
    else
        null;
    if (insertion) |index| {
        @memcpy(output[0..index], input[0..index]);
        @memcpy(output[index..][0..COPY_CODE_SNIPPET.len], COPY_CODE_SNIPPET);
        @memcpy(output[index + COPY_CODE_SNIPPET.len .. required], input[index..]);
    } else {
        @memcpy(output[0..input.len], input);
        @memcpy(output[input.len..required], COPY_CODE_SNIPPET);
    }
    return required;
}

export fn render(input_size: u32) u32 {
    const size = @as(usize, @intCast(input_size));
    const written = injectCopyCode(input_buf[0..size], output_buf[0..]);
    return @as(u32, @intCast(written));
}

test "injects copy-code assets before the closing head tag" {
    const input = "<!doctype html><html><head><title>Example</title></head><body></body></html>";
    const expected = "<!doctype html><html><head><title>Example</title>" ++ COPY_CODE_SNIPPET ++ "</head><body></body></html>";
    var output: [expected.len]u8 = undefined;
    const written = injectCopyCode(input, output[0..]);
    try std.testing.expectEqualStrings(expected, output[0..written]);
}

test "injects after the page stylesheet when the wrapper omits a closing head tag" {
    const input = "<!doctype html><html><head><style>body { color: black; }</style><header></header><main></main>";
    const expected = "<!doctype html><html><head><style>body { color: black; }</style>" ++ COPY_CODE_SNIPPET ++ "<header></header><main></main>";
    var output: [expected.len]u8 = undefined;
    const written = injectCopyCode(input, output[0..]);
    try std.testing.expectEqualStrings(expected, output[0..written]);
}

test "appends copy-code assets when the input has no head tag" {
    const input = "<p>Fragment</p>";
    const expected = input ++ COPY_CODE_SNIPPET;
    var output: [expected.len]u8 = undefined;
    const written = injectCopyCode(input, output[0..]);
    try std.testing.expectEqualStrings(expected, output[0..written]);
}
