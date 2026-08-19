const std = @import("std");
const component = @import("component");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const memory = try allocator.alloc(u8, component.MEMORY_SIZE);
    defer allocator.free(memory);
    const dirty_pages = try allocator.alloc(u64, component.requiredDirtyWords(memory.len));
    defer allocator.free(dirty_pages);

    var workspace = try component.Workspace.init(memory, dirty_pages);
    const input = "direct";
    @memcpy(workspace.memory[component.INPUT_OFFSET..][0..input.len], input);
    var instance: component.Instance = undefined;
    if (component.init(&instance, &workspace, input.len) != .ok) return error.InitFailed;
    var output_offset: u32 = 0;
    var output_size: u32 = 0;
    if (component.render(
        &instance,
        input.len,
        &output_offset,
        &output_size,
    ) != .ok) return error.RenderFailed;
    const expected = "didire";
    if (!std.mem.eql(
        u8,
        workspace.memory[output_offset..][0..output_size],
        expected,
    )) return error.OutputMismatch;
}
