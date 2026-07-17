const std = @import("std");
const core = @import("wordcount_core.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input = try std.fs.File.stdin().readToEndAlloc(allocator, 512 * 1024 * 1024);
    defer allocator.free(input);

    const result = try core.countWords(allocator, input);
    defer allocator.free(result.output);

    try std.fs.File.stdout().writeAll(result.output);
}
