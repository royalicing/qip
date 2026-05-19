const std = @import("std");

// CommonMark 0.31.2 compliance checker for qip render() markdown modules.
//
// This checker embeds compliance/commonmark-spec-0.31.2.txt and parses
// examples using the same state machine as the upstream spec_tests.py:
// - line with 32 backticks + " example" starts markdown input block
// - line with "." switches to expected html block
// - line with 32 backticks closes the example
// - heading lines ("#+ ") set section text
// - U+2192 (UTF-8 e2 86 92) is converted to tab in markdown and html
//
// Build note:
//   Zig currently imports linear memory as "env.memory" when --import-memory is used.
//   qip comply requires the check module to import "impl.memory".
//   Keep globals/stack low so checker state does not overlap impl input/output buffers.
//   Build + patch example:
//     zig build-exe compliance/commonmark-spec-0.31.2.zig \
//       -target wasm32-freestanding -O ReleaseSmall -fno-entry -rdynamic \
//       --import-memory --global-base=1024 --stack 32768 \
//       -femit-bin=/tmp/commonmark-spec-0.31.2.raw.wasm
//     wasm2wat /tmp/commonmark-spec-0.31.2.raw.wasm > /tmp/commonmark-spec-0.31.2.raw.wat
//     sed 's/(import "env" "memory"/(import "impl" "memory"/' \
//       /tmp/commonmark-spec-0.31.2.raw.wat > /tmp/commonmark-spec-0.31.2.wat
//     wat2wasm /tmp/commonmark-spec-0.31.2.wat -o compliance/commonmark-spec-0.31.2.wasm

extern "impl" fn input_ptr() u32;
extern "impl" fn input_utf8_cap() u32;
extern "impl" fn output_ptr() u32;
extern "impl" fn output_utf8_cap() u32;
extern "impl" fn render(input_size: u32) u32;

const SPEC_TEXT = @embedFile("commonmark-spec-0.31.2.txt");
const OPEN_FENCE = ("`" ** 32) ++ " example";
const CLOSE_FENCE = ("`" ** 32);

const TAB_ARROW_0: u8 = 0xE2;
const TAB_ARROW_1: u8 = 0x86;
const TAB_ARROW_2: u8 = 0x92;

const MAX_FAILURE_MESSAGE = 384;
const MAX_FAILURE_EXPECTED = 8192;

const Line = struct {
    number: u32,
    start: usize,
    end: usize,
    raw: []const u8,
};

const ParseState = enum {
    text,
    markdown,
    html,
};

var failure_message: []const u8 = "";
var failure_message_buf: [MAX_FAILURE_MESSAGE]u8 = undefined;

var failure_input_ptr_value: u32 = 0;
var failure_input_size_value: u32 = 0;

var failure_expected_output_len: u32 = 0;
var failure_expected_output_buf: [MAX_FAILURE_EXPECTED]u8 = undefined;

var failure_actual_output_ptr_value: u32 = 0;
var failure_actual_output_size_value: u32 = 0;

fn ptrOrZero(s: []const u8) u32 {
    if (s.len == 0) return 0;
    return @as(u32, @intCast(@intFromPtr(s.ptr)));
}

export fn failure_message_ptr() u32 {
    return ptrOrZero(failure_message);
}

export fn failure_message_size() u32 {
    return @as(u32, @intCast(failure_message.len));
}

export fn failure_input_ptr() u32 {
    return failure_input_ptr_value;
}

export fn failure_input_size() u32 {
    return failure_input_size_value;
}

export fn failure_expected_output_ptr() u32 {
    if (failure_expected_output_len == 0) return 0;
    return @as(u32, @intCast(@intFromPtr(&failure_expected_output_buf)));
}

export fn failure_expected_output_size() u32 {
    return failure_expected_output_len;
}

export fn failure_actual_output_ptr() u32 {
    return failure_actual_output_ptr_value;
}

export fn failure_actual_output_size() u32 {
    return failure_actual_output_size_value;
}

fn memorySliceMut(ptr: u32, len: usize) []u8 {
    const p: [*]u8 = @ptrFromInt(@as(usize, ptr));
    return p[0..len];
}

fn memorySliceConst(ptr: u32, len: usize) []const u8 {
    const p: [*]const u8 = @ptrFromInt(@as(usize, ptr));
    return p[0..len];
}

fn resetFailure() void {
    failure_message = "";
    failure_input_ptr_value = 0;
    failure_input_size_value = 0;
    failure_expected_output_len = 0;
    failure_actual_output_ptr_value = 0;
    failure_actual_output_size_value = 0;
}

fn setFailureMessage(comptime fmt: []const u8, args: anytype) void {
    failure_message = std.fmt.bufPrint(&failure_message_buf, fmt, args) catch "compliance failure";
}

fn isTrimByte(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == '\r';
}

fn trimAscii(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and isTrimByte(s[start])) : (start += 1) {}
    while (end > start and isTrimByte(s[end - 1])) : (end -= 1) {}
    return s[start..end];
}

fn parseHeaderText(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len and line[i] == '#') : (i += 1) {}
    if (i == 0 or i >= line.len or line[i] != ' ') return null;
    return trimAscii(line[i + 1 ..]);
}

fn nextLine(text: []const u8, cursor: *usize, line_number: *u32) ?Line {
    if (cursor.* >= text.len) return null;
    const start = cursor.*;
    var end = start;
    while (end < text.len and text[end] != '\n') : (end += 1) {}
    if (end < text.len and text[end] == '\n') end += 1;
    cursor.* = end;
    line_number.* += 1;
    return .{
        .number = line_number.*,
        .start = start,
        .end = end,
        .raw = text[start..end],
    };
}

fn normalizedLen(src: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < src.len) {
        if (i + 2 < src.len and src[i] == TAB_ARROW_0 and src[i + 1] == TAB_ARROW_1 and src[i + 2] == TAB_ARROW_2) {
            i += 3;
            n += 1;
            continue;
        }
        i += 1;
        n += 1;
    }
    return n;
}

fn copyNormalized(dst: []u8, src: []const u8) usize {
    var i: usize = 0;
    var j: usize = 0;
    while (i < src.len and j < dst.len) {
        if (i + 2 < src.len and src[i] == TAB_ARROW_0 and src[i + 1] == TAB_ARROW_1 and src[i + 2] == TAB_ARROW_2) {
            dst[j] = '\t';
            i += 3;
            j += 1;
            continue;
        }
        dst[j] = src[i];
        i += 1;
        j += 1;
    }
    return j;
}

fn outputEqualsNormalized(expected_raw: []const u8, actual_size: u32) bool {
    const want = normalizedLen(expected_raw);
    if (actual_size != want) return false;

    const out = memorySliceConst(output_ptr(), want);
    var src_i: usize = 0;
    var out_i: usize = 0;
    while (src_i < expected_raw.len and out_i < out.len) {
        var expected_byte: u8 = expected_raw[src_i];
        if (src_i + 2 < expected_raw.len and expected_raw[src_i] == TAB_ARROW_0 and expected_raw[src_i + 1] == TAB_ARROW_1 and expected_raw[src_i + 2] == TAB_ARROW_2) {
            expected_byte = '\t';
            src_i += 3;
        } else {
            src_i += 1;
        }
        if (out[out_i] != expected_byte) return false;
        out_i += 1;
    }
    return src_i == expected_raw.len and out_i == out.len;
}

fn setFailureExpectedFromRaw(expected_raw: []const u8) void {
    const expected_len = normalizedLen(expected_raw);
    const to_copy = @min(expected_len, failure_expected_output_buf.len);
    failure_expected_output_len = @as(u32, @intCast(copyNormalized(failure_expected_output_buf[0..to_copy], expected_raw)));
}

fn setFailureDetail(
    section: []const u8,
    example_number: u32,
    start_line: u32,
    end_line: u32,
    reason: []const u8,
    input_size: u32,
    expected_raw: []const u8,
    actual_size: u32,
) void {
    setFailureMessage(
        "example {d} (lines {d}-{d}) [{s}]: {s}",
        .{ example_number, start_line, end_line, section, reason },
    );
    failure_input_ptr_value = input_ptr();
    failure_input_size_value = input_size;
    setFailureExpectedFromRaw(expected_raw);
    failure_actual_output_ptr_value = output_ptr();
    failure_actual_output_size_value = actual_size;
}

fn runExample(
    section: []const u8,
    example_number: u32,
    start_line: u32,
    end_line: u32,
    markdown_raw: []const u8,
    html_raw: []const u8,
    in_cap: u32,
    out_cap: u32,
) i32 {
    const in_len = normalizedLen(markdown_raw);
    const expected_len = normalizedLen(html_raw);

    if (in_len > in_cap) {
        setFailureDetail(
            section,
            example_number,
            start_line,
            end_line,
            "input exceeds input_utf8_cap",
            0,
            html_raw,
            0,
        );
        return -@as(i32, @intCast(example_number));
    }

    if (expected_len > out_cap) {
        setFailureDetail(
            section,
            example_number,
            start_line,
            end_line,
            "expected output exceeds output_utf8_cap",
            @as(u32, @intCast(in_len)),
            html_raw,
            0,
        );
        return -@as(i32, @intCast(example_number));
    }

    const dst = memorySliceMut(input_ptr(), in_len);
    const copied = copyNormalized(dst, markdown_raw);
    if (copied != in_len) {
        setFailureDetail(
            section,
            example_number,
            start_line,
            end_line,
            "failed to prepare normalized markdown input",
            @as(u32, @intCast(copied)),
            html_raw,
            0,
        );
        return -@as(i32, @intCast(example_number));
    }

    const actual_size = render(@as(u32, @intCast(in_len)));
    if (actual_size > out_cap) {
        setFailureDetail(
            section,
            example_number,
            start_line,
            end_line,
            "render returned output larger than output_utf8_cap",
            @as(u32, @intCast(in_len)),
            html_raw,
            actual_size,
        );
        return -@as(i32, @intCast(example_number));
    }

    if (!outputEqualsNormalized(html_raw, actual_size)) {
        setFailureDetail(
            section,
            example_number,
            start_line,
            end_line,
            "html mismatch",
            @as(u32, @intCast(in_len)),
            html_raw,
            actual_size,
        );
        return -@as(i32, @intCast(example_number));
    }

    return 1;
}

// Returns >0 on pass, <=0 on failure.
// On failure, returns negative example number.
export fn positive() i32 {
    resetFailure();

    const in_cap = input_utf8_cap();
    const out_cap = output_utf8_cap();
    if (in_cap == 0 or out_cap == 0) {
        setFailureMessage("impl module reported zero utf8 capacity", .{});
        return -1000;
    }

    var cursor: usize = 0;
    var line_number: u32 = 0;
    var state: ParseState = .text;

    var section: []const u8 = "";
    var start_line: u32 = 0;
    var markdown_start: usize = 0;
    var markdown_end: usize = 0;
    var html_start: usize = 0;
    var html_end: usize = 0;
    var have_markdown: bool = false;
    var have_html: bool = false;

    var pass_count: i32 = 0;
    var example_number: u32 = 0;

    while (nextLine(SPEC_TEXT, &cursor, &line_number)) |line| {
        const trimmed = trimAscii(line.raw);

        if (std.mem.eql(u8, trimmed, OPEN_FENCE)) {
            state = .markdown;
            start_line = 0;
            have_markdown = false;
            have_html = false;
            continue;
        }

        if (state == .html and std.mem.eql(u8, trimmed, CLOSE_FENCE)) {
            example_number += 1;
            const markdown_raw = if (have_markdown) SPEC_TEXT[markdown_start..markdown_end] else "";
            const html_raw = if (have_html) SPEC_TEXT[html_start..html_end] else "";
            const end_line = line.number;
            const result = runExample(
                section,
                example_number,
                start_line,
                end_line,
                markdown_raw,
                html_raw,
                in_cap,
                out_cap,
            );
            if (result <= 0) return result;
            pass_count += result;
            state = .text;
            continue;
        }

        if (std.mem.eql(u8, trimmed, ".")) {
            state = .html;
            continue;
        }

        if (state == .markdown) {
            if (start_line == 0) start_line = line.number - 1;
            if (!have_markdown) {
                markdown_start = line.start;
                have_markdown = true;
            }
            markdown_end = line.end;
            continue;
        }

        if (state == .html) {
            if (!have_html) {
                html_start = line.start;
                have_html = true;
            }
            html_end = line.end;
            continue;
        }

        if (parseHeaderText(line.raw)) |header| {
            section = header;
        }
    }

    if (state != .text) {
        setFailureMessage("spec parse ended inside unfinished example", .{});
        return -2000;
    }

    if (example_number == 0) {
        setFailureMessage("no examples parsed from embedded spec", .{});
        return -2001;
    }

    return pass_count;
}
