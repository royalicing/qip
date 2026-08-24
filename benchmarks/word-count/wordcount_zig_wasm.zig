const std = @import("std");
const core = @import("wordcount_core.zig");

const INPUT_CAP: usize = 8 * 1024 * 1024;
const OUTPUT_CAP: usize = 2 * 1024 * 1024;
const SCRATCH_CAP: usize = 8 * 1024 * 1024;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var scratch_buf: [SCRATCH_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

fn renderImpl(input_size_u32: u32) u32 {
    const input_size: usize = @intCast(input_size_u32);
    if (input_size > INPUT_CAP) @trap();

    var fixed = std.heap.FixedBufferAllocator.init(scratch_buf[0..]);
    const allocator = fixed.allocator();

    const result = core.countWordsOptimized(allocator, input_buf[0..input_size]) catch @trap();
    const out = result.output;
    if (out.len > OUTPUT_CAP) @trap();
    @memcpy(output_buf[0..out.len], out);
    return @intCast(out.len);
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
