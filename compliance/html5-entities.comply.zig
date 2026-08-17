const std = @import("std");

extern "qip" fn must_render_into(
    ordinal: u64,
    input_ptr: u32,
    input_len: u32,
    output_ptr: u32,
    output_cap: u32,
) i32;
extern "qip" fn must_render_into_emit_error(ordinal: u64, message_ptr: u32, message_len: u32) i32;
extern "qip" fn must_render_into_finish(ordinal: u64, error_count: u32) i32;

const render_failed_message = "render failed or output did not fit";
const missing_entity_message = "rendered output did not contain expected entity replacement";

// Verifies that a markdown-family Content component decodes every HTML5 named
// character reference CommonMark 0.31.2 recognizes — the semicolon-terminated
// names from WHATWG entities.json — plus the numeric character reference
// rules. Cases are generated at comptime from compliance/html5-entities-table.zig;
// see that file's header and tools/generate-markdown-tables.py for the pinned
// source and regeneration command.
//
// Entity decoding is a cross-cutting concern, so this oracle uses must_render_into rather
// than byte-compares: each case renders "x&name;y" and asserts only that the
// output CONTAINS the decoded (HTML-escaped) replacement between the x/y
// markers, ignoring surrounding markup. The oracle therefore keeps passing
// when unrelated rendering details change, and can run against any component
// that is expected to decode entity references in flowing text.
const entity_table = @import("html5-entities-table.zig");

fn htmlEscape(comptime value: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (value) |b| {
            out = out ++ switch (b) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                else => &[1]u8{b},
            };
        }
        return out;
    }
}

const Case = struct {
    input: []const u8,
    must_contain: []const u8,
};

// Numeric character references are spec-mechanical: decimal and hex forms
// decode to the code point; NUL, out-of-range, and surrogate values decode to
// U+FFFD; missing digits or a missing semicolon leave the text literal.
const NUMERIC_CASES = [_]Case{
    .{ .input = "x&#35;y", .must_contain = "x#y" },
    .{ .input = "x&#1234;y", .must_contain = "x\u{4D2}y" },
    .{ .input = "x&#992;y", .must_contain = "x\u{3E0}y" },
    .{ .input = "x&#X22;y", .must_contain = "x&quot;y" },
    .{ .input = "x&#XD06;y", .must_contain = "x\u{D06}y" },
    .{ .input = "x&#xcab;y", .must_contain = "x\u{CAB}y" },
    .{ .input = "x&#0;y", .must_contain = "x\u{FFFD}y" },
    .{ .input = "x&#1114112;y", .must_contain = "x\u{FFFD}y" },
    .{ .input = "x&#xD800;y", .must_contain = "x\u{FFFD}y" },
    .{ .input = "x&#xDFFF;y", .must_contain = "x\u{FFFD}y" },
    .{ .input = "x&#;y", .must_contain = "x&amp;#;y" },
    .{ .input = "x&#x;y", .must_contain = "x&amp;#x;y" },
    .{ .input = "x&#abcdef0;y", .must_contain = "x&amp;#abcdef0;y" },
    .{ .input = "x&#35y", .must_contain = "x&amp;#35y" },
};

const NEGATIVE_CASES = [_]Case{
    .{ .input = "x&nosuchentity;y", .must_contain = "x&amp;nosuchentity;y" },
    .{ .input = "x&ndash y", .must_contain = "x&amp;ndash y" },
    .{ .input = "x&NDASH;y", .must_contain = "x&amp;NDASH;y" },
    .{ .input = "x&copy&copy;y", .must_contain = "x&amp;copy\u{A9}y" },
};

const CASES = build: {
    @setEvalBranchQuota(4_000_000);
    var cases: [entity_table.count + NUMERIC_CASES.len + NEGATIVE_CASES.len]Case = undefined;
    var n: usize = 0;
    for (0..entity_table.count) |i| {
        const name_start = if (i == 0) 0 else entity_table.name_ends[i - 1];
        const name = entity_table.names_blob[name_start..entity_table.name_ends[i]];
        const value_start = if (i == 0) 0 else entity_table.value_ends[i - 1];
        const value = entity_table.values_blob[value_start..entity_table.value_ends[i]];
        cases[n] = .{
            .input = "x&" ++ name ++ ";y",
            .must_contain = "x" ++ htmlEscape(value) ++ "y",
        };
        n += 1;
    }
    for (NUMERIC_CASES) |case| {
        cases[n] = case;
        n += 1;
    }
    for (NEGATIVE_CASES) |case| {
        cases[n] = case;
        n += 1;
    }
    break :build cases;
};

var output_buf: [4096]u8 = undefined;

export fn comply() i32 {
    for (CASES, 0..) |case, ordinal| {
        const status = must_render_into(
            ordinal,
            @intCast(@intFromPtr(case.input.ptr)),
            @intCast(case.input.len),
            @intCast(@intFromPtr(&output_buf)),
            output_buf.len,
        );
        if (status < 0) {
            _ = must_render_into_emit_error(ordinal, @intCast(@intFromPtr(render_failed_message.ptr)), render_failed_message.len);
            _ = must_render_into_finish(ordinal, 1);
            continue;
        }
        const output = output_buf[0..@as(usize, @intCast(status))];
        if (std.mem.indexOf(u8, output, case.must_contain) != null) {
            _ = must_render_into_finish(ordinal, 0);
        } else {
            _ = must_render_into_emit_error(ordinal, @intCast(@intFromPtr(missing_entity_message.ptr)), missing_entity_message.len);
            _ = must_render_into_finish(ordinal, 1);
        }
    }
    return @intCast(CASES.len);
}
