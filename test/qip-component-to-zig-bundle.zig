const std = @import("std");
const first = @import("first");
const second = @import("second");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const memory_size = @max(first.MEMORY_SIZE, second.MEMORY_SIZE);
    const memory = try allocator.alloc(u8, memory_size);
    defer allocator.free(memory);
    const dirty_pages = try allocator.alloc(u64, first.requiredDirtyWords(memory.len));
    defer allocator.free(dirty_pages);

    var workspace = try first.Workspace.init(memory, dirty_pages);
    const input = "  Zig  ";
    @memcpy(workspace.memory[first.INPUT_OFFSET..][0..input.len], input);

    var a: first.Instance = undefined;
    var b: second.Instance = undefined;
    var output_offset: u32 = 0;
    var output_size: u32 = 0;
    if (first.init(&a, &workspace, input.len) != .ok) return error.FirstInitFailed;
    if (first.render(&a, input.len, &output_offset, &output_size) != .ok) {
        return error.FirstRenderFailed;
    }

    if (output_size > second.INPUT_CAPACITY) return error.IntermediateTooLarge;
    std.mem.copyForwards(
        u8,
        workspace.memory[second.INPUT_OFFSET..][0..output_size],
        workspace.memory[output_offset..][0..output_size],
    );
    if (second.init(&b, &workspace, output_size) != .ok) return error.SecondInitFailed;
    if (second.render(&b, output_size, &output_offset, &output_size) != .ok) {
        return error.SecondRenderFailed;
    }

    if (first.render(&a, input.len, &output_offset, &output_size) != .stale_instance) {
        return error.FirstInstanceNotStale;
    }
    const expected = "Hello,   Zig";
    if (!std.mem.eql(
        u8,
        workspace.memory[output_offset..][0..output_size],
        expected,
    )) return error.OutputMismatch;
}
