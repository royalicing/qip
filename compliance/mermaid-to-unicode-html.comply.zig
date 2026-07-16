extern "qip" fn render_must_equal(
    ordinal: u64,
    input_ptr: u32,
    input_len: u32,
    expected_ptr: u32,
    expected_len: u32,
) i32;

extern "qip" fn render_must_trap(
    ordinal: u64,
    input_ptr: u32,
    input_len: u32,
) i32;

const Fixture = struct {
    input: []const u8,
    expected: []const u8,
};

const corpus = @embedFile("mermaid-to-unicode-html.fixtures.txt");
const input_marker = "=== INPUT ===\n";
const output_marker = "\n=== OUTPUT ===\n";
const end_marker = "=== END ===\n";

comptime {
    @setEvalBranchQuota(1_000_000);
}

const fixtures = parseFixtures(corpus);

fn parseFixtures(comptime source: []const u8) [countFixtures(source)]Fixture {
    @setEvalBranchQuota(1_000_000);
    comptime var result: [countFixtures(source)]Fixture = undefined;
    comptime var rest = source;
    comptime var index: usize = 0;
    inline while (rest.len != 0) {
        if (rest[0] == '\n') {
            rest = rest[1..];
            if (rest.len == 0) break;
        }
        if (!@import("std").mem.startsWith(u8, rest, input_marker))
            @compileError("fixture must start with an input marker");
        rest = rest[input_marker.len..];
        const output_at = @import("std").mem.indexOf(u8, rest, output_marker) orelse
            @compileError("fixture is missing an output marker");
        const input = rest[0..output_at];
        rest = rest[output_at + output_marker.len ..];
        const end_at = @import("std").mem.indexOf(u8, rest, end_marker) orelse
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
    inline while (@import("std").mem.indexOf(u8, rest, input_marker)) |at| {
        count += 1;
        rest = rest[at + input_marker.len ..];
    }
    return count;
}

const invalid = [_][]const u8{
    "",
    "   \n",
    "pie title Pets\n  \"Dogs\" : 386\n  \"Cats\" : 85",
    "journey\n  title Unsupported",
    "graph TD\n  A -->",
    "sequenceDiagram\n  ->>B: orphan",
    "stateDiagram-v2\n  A --> B\n  some garbage line",
    "classDiagram\n  Animal <|--",
    "erDiagram\n  CUSTOMER ||-- ORDER",
};

export fn comply() i32 {
    comptime var ordinal: u64 = 0;
    inline for (fixtures) |fixture| {
        _ = render_must_equal(
            ordinal,
            @intCast(@intFromPtr(fixture.input.ptr)),
            @intCast(fixture.input.len),
            @intCast(@intFromPtr(fixture.expected.ptr)),
            @intCast(fixture.expected.len),
        );
        ordinal += 1;
    }
    inline for (invalid) |input| {
        _ = render_must_trap(
            ordinal,
            @intCast(@intFromPtr(input.ptr)),
            @intCast(input.len),
        );
        ordinal += 1;
    }
    return @intCast(ordinal);
}
