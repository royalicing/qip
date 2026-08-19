const std = @import("std");
const component = @import("component");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const memory = try allocator.alloc(u8, component.MEMORY_SIZE);
    defer allocator.free(memory);
    const dirty_pages = try allocator.alloc(u64, component.requiredDirtyWords(memory.len));
    defer allocator.free(dirty_pages);

    var workspace = try component.Workspace.init(memory, dirty_pages);
    var instance: component.Instance = undefined;
    if (component.init(&instance, &workspace, 0) != .ok) return error.InitFailed;
    var output_offset: u32 = 0;
    var output_size: u32 = 0;
    if (component.render(
        &instance,
        0,
        &output_offset,
        &output_size,
    ) != .trap_unreachable) return error.MissingTrap;
}
