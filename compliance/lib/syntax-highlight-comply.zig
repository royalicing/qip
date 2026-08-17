const std = @import("std");

extern "qip" fn must_render_exactly(
    ordinal: u64,
    input_ptr: u32,
    input_len: u32,
    expected_ptr: u32,
    expected_len: u32,
) i32;

pub const Fixture = struct {
    input: []const u8,
    expected: []const u8,
};

const input_marker = "=== INPUT ===\n";
const output_marker = "\n=== OUTPUT ===\n";
const end_marker = "\n=== END ===\n";

pub fn parseFixtures(comptime source: []const u8) [countFixtures(source)]Fixture {
    @setEvalBranchQuota(1_000_000);
    comptime var result: [countFixtures(source)]Fixture = undefined;
    comptime var rest = source;
    comptime var index: usize = 0;

    inline while (rest.len != 0) {
        while (rest.len != 0 and rest[0] == '\n') rest = rest[1..];
        if (rest.len == 0) break;
        if (!std.mem.startsWith(u8, rest, input_marker))
            @compileError("fixture must start with an input marker");

        rest = rest[input_marker.len..];
        const output_at = std.mem.indexOf(u8, rest, output_marker) orelse
            @compileError("fixture is missing an output marker");
        const input = rest[0..output_at];

        rest = rest[output_at + output_marker.len ..];
        const end_at = std.mem.indexOf(u8, rest, end_marker) orelse
            @compileError("fixture is missing an end marker");
        result[index] = .{ .input = input, .expected = rest[0..end_at] };
        index += 1;
        rest = rest[end_at + end_marker.len ..];
    }

    return result;
}

fn countFixtures(comptime source: []const u8) usize {
    @setEvalBranchQuota(1_000_000);
    comptime var count: usize = 0;
    comptime var rest = source;
    inline while (std.mem.indexOf(u8, rest, input_marker)) |at| {
        count += 1;
        rest = rest[at + input_marker.len ..];
    }
    return count;
}

pub fn runFixtures(comptime fixtures: anytype) i32 {
    comptime var ordinal: u64 = 0;
    inline for (fixtures) |fixture| {
        _ = must_render_exactly(
            ordinal,
            @intCast(@intFromPtr(fixture.input.ptr)),
            @intCast(fixture.input.len),
            @intCast(@intFromPtr(fixture.expected.ptr)),
            @intCast(fixture.expected.len),
        );
        ordinal += 1;
    }
    return @intCast(ordinal);
}
