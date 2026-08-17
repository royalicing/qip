extern "qip" fn must_render_exactly(
    ordinal: u64,
    input_ptr: u32,
    input_len: u32,
    expected_ptr: u32,
    expected_len: u32,
) i32;
extern "qip" fn must_trap(ordinal: u64, input_ptr: u32, input_len: u32) i32;

const Case = struct {
    input: []const u8,
    expected: []const u8,
};

const cases = [_]Case{
    .{
        .input = "data:image/svg+xml,%3Csvg/%3E",
        .expected = "url(\"data:image/svg+xml,%3Csvg/%3E\")",
    },
    .{ .input = "data:,hello", .expected = "url(\"data:,hello\")" },
    .{ .input = "data:,a\"b'c", .expected = "url(\"data:,a%22b%27c\")" },
    .{ .input = "data:,a\\b", .expected = "url(\"data:,a%5Cb\")" },
    .{ .input = "data:,line\nfeed", .expected = "url(\"data:,line%0Afeed\")" },
    .{ .input = "data:,100%25", .expected = "url(\"data:,100%25\")" },
};

const invalid = [_][]const u8{
    "",
    "data:",
    "data:image/svg+xml",
    "http://example.com",
    "DATA:,hello",
    " data:,hello",
};
var ordinal: u64 = 0;

export fn uniform_set_seed(_: i32) void {}

export fn comply() i32 {
    ordinal = 0;
    for (cases) |case| {
        _ = must_render_exactly(
            ordinal,
            @intCast(@intFromPtr(case.input.ptr)),
            @intCast(case.input.len),
            @intCast(@intFromPtr(case.expected.ptr)),
            @intCast(case.expected.len),
        );
        ordinal += 1;
    }
    for (invalid) |input| {
        _ = must_trap(ordinal, @intCast(@intFromPtr(input.ptr)), @intCast(input.len));
        ordinal += 1;
    }
    return @intCast(ordinal);
}
