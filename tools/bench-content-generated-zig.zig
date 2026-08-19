const std = @import("std");
const component = @import("component");

const max_samples: usize = 1_000_000;

fn renderOnce(
    instance: *component.Instance,
    workspace: *component.Workspace,
    input: []const u8,
    output: []u8,
    output_offset: *u32,
    output_size: *u32,
) !void {
    @memcpy(workspace.memory[component.INPUT_OFFSET..][0..input.len], input);
    if (component.render(instance, @intCast(input.len), output_offset, output_size) != .ok)
        return error.RenderFailed;
    @memcpy(output[0..output_size.*], workspace.memory[output_offset.*..][0..output_size.*]);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 3 and args.len != 4) {
        std.debug.print("usage: bench-content-generated-zig input duration-ms [output]\n", .{});
        return error.InvalidArguments;
    }

    const duration_ms = try std.fmt.parseInt(u64, args[2], 10);
    const input = try std.fs.cwd().readFileAlloc(allocator, args[1], component.INPUT_CAPACITY);
    defer allocator.free(input);
    const output = try allocator.alloc(u8, component.OUTPUT_CAPACITY);
    defer allocator.free(output);
    const memory = try allocator.alloc(u8, component.MEMORY_SIZE);
    defer allocator.free(memory);
    const dirty = try allocator.alloc(u64, component.requiredDirtyWords(memory.len));
    defer allocator.free(dirty);
    var workspace = try component.Workspace.init(memory, dirty);
    var instance: component.Instance = undefined;

    @memcpy(workspace.memory[component.INPUT_OFFSET..][0..input.len], input);
    if (component.init(&instance, &workspace, @intCast(input.len)) != .ok) return error.InitFailed;

    var output_offset: u32 = 0;
    var output_size: u32 = 0;
    var warmup: usize = 0;
    while (warmup < 20) : (warmup += 1)
        try renderOnce(&instance, &workspace, input, output, &output_offset, &output_size);

    const samples = try allocator.alloc(u64, max_samples);
    defer allocator.free(samples);
    const deadline = std.time.nanoTimestamp() + @as(i128, duration_ms) * std.time.ns_per_ms;
    var count: usize = 0;
    while (count < samples.len and std.time.nanoTimestamp() < deadline) : (count += 1) {
        const start = std.time.nanoTimestamp();
        try renderOnce(&instance, &workspace, input, output, &output_offset, &output_size);
        samples[count] = @intCast(std.time.nanoTimestamp() - start);
    }
    std.mem.sort(u64, samples[0..count], {}, std.sort.asc(u64));
    var total: u128 = 0;
    for (samples[0..count]) |sample| total += sample;

    if (args.len == 4) {
        const file = try std.fs.cwd().createFile(args[3], .{});
        defer file.close();
        try file.writeAll(output[0..output_size]);
    }
    const mean_ns: f64 = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(count));
    std.debug.print(
        "{s} samples={d} mean_ms={d:.6} p50_ms={d:.6} p95_ms={d:.6} max_ms={d:.6} output_size={d} output_hash={x}\n",
        .{
            args[0],
            count,
            mean_ns / std.time.ns_per_ms,
            @as(f64, @floatFromInt(samples[count / 2])) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(samples[(count * 95) / 100])) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(samples[count - 1])) / std.time.ns_per_ms,
            output_size,
            std.hash.Wyhash.hash(0, output[0..output_size]),
        },
    );
}
