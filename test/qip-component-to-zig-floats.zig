const std = @import("std");
const component = @import("component");

fn expectU32(memory: []const u8, offset: usize, expected: u32) !void {
    if (std.mem.readInt(u32, memory[offset..][0..4], .little) != expected)
        return error.OutputMismatch;
}

fn expectU64(memory: []const u8, offset: usize, expected: u64) !void {
    if (std.mem.readInt(u64, memory[offset..][0..8], .little) != expected)
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
    if (component.init(&instance, &workspace, 0) != .ok) return error.InitFailed;
    var output_offset: u32 = 0;
    var output_size: u32 = 0;
    if (component.render(&instance, 0, &output_offset, &output_size) != .ok)
        return error.RenderFailed;
    if (output_offset != 64 or output_size != 88) return error.OutputContractMismatch;

    try expectU32(memory, 64, 0x40000000); // nearest(2.5) = 2, ties to even
    try expectU32(memory, 68, 0x80000000); // nearest(-0.5) preserves -0
    try expectU32(memory, 72, 0x80000000); // min(+0, -0) = -0
    try expectU32(memory, 76, 0x00000000); // max(+0, -0) = +0
    try expectU32(memory, 80, 0x40400000); // abs(-3) = 3
    try expectU32(memory, 84, 0xbf800000); // copysign(1, -2) = -1
    try expectU32(memory, 88, 0xfffffffd); // trunc(-3.75) = -3
    try expectU32(memory, 92, 0xc0e00000); // convert(-7) = -7.0
    try expectU64(memory, 96, 0x4000000000000000);
    try expectU64(memory, 104, 0x8000000000000000);
    try expectU64(memory, 112, 0x8000000000000000);
    try expectU64(memory, 120, 0x0000000000000000);
    try expectU64(memory, 128, 0x400e000000000000);
    try expectU64(memory, 136, 0xc01c000000000000);
    try expectU64(memory, 144, 0x3ff8000000000000);
}
