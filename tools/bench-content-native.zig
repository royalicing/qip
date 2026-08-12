const std = @import("std");
const builtin = @import("builtin");
const component = @import("component");

const max_samples = 1_000_000;

fn lessThan(_: void, a: f64, b: f64) bool {
    return a < b;
}

fn printSummary(writer: *std.Io.Writer, name: []const u8, samples: []f64) !void {
    var sum: f64 = 0;
    for (samples) |sample| sum += sample;
    std.mem.sort(f64, samples, {}, lessThan);
    try writer.print(
        "\"{s}\":{{\"samples\":{d},\"mean_ms\":{d:.9},\"p50_ms\":{d:.9}," ++
            "\"p95_ms\":{d:.9},\"max_ms\":{d:.9}}}",
        .{
            name,
            samples.len,
            sum / @as(f64, @floatFromInt(samples.len)),
            samples[samples.len / 2],
            samples[(samples.len * 95) / 100],
            samples[samples.len - 1],
        },
    );
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    if (args.len < 3) {
        std.debug.print("usage: bench-content-native input duration-ms [output]\n", .{});
        return error.InvalidArguments;
    }

    const input = try std.fs.cwd().readFileAlloc(allocator, args[1], 512 * 1024 * 1024);
    const duration_ms = try std.fmt.parseFloat(f64, args[2]);
    const output = try allocator.alloc(u8, component.native_output_capacity);
    const samples = try allocator.alloc(f64, max_samples);
    var output_size: u32 = 0;

    for (0..20) |_| output_size = component.nativeRender(input, output);

    var timer = try std.time.Timer.start();
    const deadline_ns: u64 = @intFromFloat(duration_ms * std.time.ns_per_ms);
    var count: usize = 0;
    while (count < samples.len and timer.read() < deadline_ns) : (count += 1) {
        const start = timer.read();
        output_size = component.nativeRender(input, output);
        samples[count] = @as(f64, @floatFromInt(timer.read() - start)) / std.time.ns_per_ms;
    }

    if (args.len > 3) {
        const file = try std.fs.cwd().createFile(args[3], .{});
        defer file.close();
        try file.writeAll(output[0..output_size]);
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;
    const usage = std.posix.getrusage(0);
    const max_rss_bytes: u64 = if (builtin.os.tag == .linux)
        @intCast(usage.maxrss * 1024)
    else
        @intCast(usage.maxrss);
    try writer.print(
        "{{\"runtime\":\"zig-native\",\"input_bytes\":{d},\"output_bytes\":{d}," ++
            "\"max_rss_bytes\":{d},",
        .{ input.len, output_size, max_rss_bytes },
    );
    try printSummary(writer, "warm_full", samples[0..count]);
    try writer.writeAll("}\n");
    try writer.flush();
}
