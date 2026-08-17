extern "qip" fn must_render_exactly(
    ordinal: u64,
    input_ptr: u32,
    input_len: u32,
    expected_ptr: u32,
    expected_len: u32,
) i32;

const Case = struct {
    input: []const u8,
    expected: []const u8,
};

const cases = [_]Case{
    .{ .input = "", .expected = "data:image/svg+xml," },
    .{ .input = "<svg/>", .expected = "data:image/svg+xml,%3Csvg/%3E" },
    .{
        .input = "<svg xmlns=\"http://www.w3.org/2000/svg\" fill='none'>",
        .expected = "data:image/svg+xml,%3Csvg%20xmlns=%22http://www.w3.org/2000/svg%22%20fill=%27none%27%3E",
    },
    .{ .input = "# %", .expected = "data:image/svg+xml,%23%20%25" },
    .{ .input = "line\nfeed\ttab", .expected = "data:image/svg+xml,line%0Afeed%09tab" },
    .{ .input = "caf\xC3\xA9", .expected = "data:image/svg+xml,caf%C3%A9" },
    .{ .input = "-._~!$()*+,;=:@/?", .expected = "data:image/svg+xml,-._~!$()*+,;=:@/?" },
    .{ .input = "&\\[]{}|^`", .expected = "data:image/svg+xml,%26%5C%5B%5D%7B%7D%7C%5E%60" },
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
    return @intCast(ordinal);
}
