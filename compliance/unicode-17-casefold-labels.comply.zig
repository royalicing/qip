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
const missing_label_message = "rendered output did not contain expected folded label link";

// Verifies that a markdown-family Content component matches reference labels
// under full Unicode case folding, as CommonMark 0.31.2 requires. Cases are
// generated at comptime from compliance/unicode-17-casefold-tables.zig —
// Unicode 17.0.0 UCD CaseFolding.txt statuses C and F, non-Turkic; see that
// file's header and tools/generate-markdown-tables.py for the pinned source
// and regeneration command.
//
// Label folding is a cross-cutting concern, so this oracle uses must_render_into rather
// than byte-compares: for every fold entry it renders a shortcut reference
// link whose label is the unfolded code point against a definition whose
// label is the folded expansion, and asserts only that the output CONTAINS
// the resolved anchor — ignoring surrounding markup, so unrelated rendering
// changes don't invalidate the suite.
const casefold = @import("unicode-17-casefold-tables.zig");

fn utf8(comptime cp: u21) []const u8 {
    comptime {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        var out: []const u8 = "";
        for (buf[0..n]) |b| out = out ++ &[1]u8{b};
        return out;
    }
}

const Case = struct {
    input: []const u8,
    must_contain: []const u8,
};

fn makeCase(comptime orig: []const u8, comptime folded: []const u8) Case {
    return .{
        .input = "[" ++ orig ++ "]\n\n[" ++ folded ++ "]: /u\n",
        .must_contain = "<a href=\"/u\">" ++ orig ++ "</a>",
    };
}

const CASES = build: {
    @setEvalBranchQuota(4_000_000);
    var cases: [casefold.fold_map_keys.len + casefold.fold_multi_keys.len]Case = undefined;
    var n: usize = 0;
    for (casefold.fold_map_keys, casefold.fold_map_values) |key, value| {
        cases[n] = makeCase(utf8(@intCast(key)), utf8(@intCast(value)));
        n += 1;
    }
    for (casefold.fold_multi_keys, casefold.fold_multi_values) |key, value| {
        var folded: []const u8 = "";
        for (value) |cp| {
            if (cp != 0) folded = folded ++ utf8(@intCast(cp));
        }
        cases[n] = makeCase(utf8(@intCast(key)), folded);
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
            _ = must_render_into_emit_error(ordinal, @intCast(@intFromPtr(missing_label_message.ptr)), missing_label_message.len);
            _ = must_render_into_finish(ordinal, 1);
        }
    }
    return @intCast(CASES.len);
}
