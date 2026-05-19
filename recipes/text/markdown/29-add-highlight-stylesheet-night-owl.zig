const std = @import("std");

const INPUT_CAP: u32 = 0x80000;
const NIGHT_OWL_CSS = @embedFile("highlight-night-owl.css");
const STYLE_PREFIX = "<style>\n";
const STYLE_SUFFIX = "\n</style>\n";
const OUTPUT_CAP: u32 = INPUT_CAP + @as(u32, @intCast(STYLE_PREFIX.len + NIGHT_OWL_CSS.len + STYLE_SUFFIX.len));
const INPUT_CONTENT_TYPE = "text/html";
const OUTPUT_CONTENT_TYPE = "text/html";

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

fn prependHighlightStyles(input: []const u8, output: []u8) usize {
    const total = STYLE_PREFIX.len + NIGHT_OWL_CSS.len + STYLE_SUFFIX.len + input.len;
    if (total > output.len) @panic("output buffer overflow");

    var idx: usize = 0;
    @memcpy(output[idx .. idx + STYLE_PREFIX.len], STYLE_PREFIX);
    idx += STYLE_PREFIX.len;
    @memcpy(output[idx .. idx + NIGHT_OWL_CSS.len], NIGHT_OWL_CSS);
    idx += NIGHT_OWL_CSS.len;
    @memcpy(output[idx .. idx + STYLE_SUFFIX.len], STYLE_SUFFIX);
    idx += STYLE_SUFFIX.len;
    @memcpy(output[idx .. idx + input.len], input);
    idx += input.len;

    return idx;
}

export fn render(input_size: u32) u32 {
    const size = @as(usize, @intCast(input_size));
    const input = input_buf[0..size];
    const output = output_buf[0..];
    const written = prependHighlightStyles(input, output);
    return @as(u32, @intCast(written));
}

test "prepends night owl highlight stylesheet" {
    const input = "<!doctype html><html><body><pre><code class=\"language-zig hljs\">...</code></pre></body></html>";
    const expected = STYLE_PREFIX ++ NIGHT_OWL_CSS ++ STYLE_SUFFIX ++ input;
    var out: [expected.len]u8 = undefined;
    const written = prependHighlightStyles(input, out[0..]);
    try std.testing.expectEqualStrings(expected, out[0..written]);
}

