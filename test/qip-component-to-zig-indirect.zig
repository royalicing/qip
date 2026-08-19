const std = @import("std");
const component = @import("component");

fn expect(
    instance: *component.Instance,
    workspace: *component.Workspace,
    input: u8,
    expected: component.Status,
) !void {
    workspace.memory[component.INPUT_OFFSET] = input;
    var output_offset: u32 = 0;
    var output_size: u32 = 0;
    if (component.render(instance, 1, &output_offset, &output_size) != expected)
        return error.StatusMismatch;
    if (expected == .ok and
        !std.mem.eql(u8, workspace.memory[output_offset..][0..output_size], "ok"))
        return error.OutputMismatch;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const memory = try allocator.alloc(u8, component.MEMORY_SIZE);
    defer allocator.free(memory);
    const dirty_pages = try allocator.alloc(u64, component.requiredDirtyWords(memory.len));
    defer allocator.free(dirty_pages);

    var workspace = try component.Workspace.init(memory, dirty_pages);
    var instance: component.Instance = undefined;
    if (component.init(&instance, &workspace, 1) != .ok) return error.InitFailed;

    try expect(&instance, &workspace, 'v', .ok);
    try expect(&instance, &workspace, 'n', .trap_indirect_null);
    try expect(&instance, &workspace, 'v', .ok);
    try expect(&instance, &workspace, 'o', .trap_table_out_of_bounds);
    try expect(&instance, &workspace, 'v', .ok);
    try expect(&instance, &workspace, 't', .trap_indirect_type);
    try expect(&instance, &workspace, 'v', .ok);
    try expect(&instance, &workspace, 'r', .trap_call_depth);
    try expect(&instance, &workspace, 'v', .ok);
}
