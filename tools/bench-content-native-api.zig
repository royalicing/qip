const component = @import("component");

export fn qip_native_output_capacity() usize {
    return component.native_output_capacity;
}

export fn qip_native_render(
    input_ptr: [*]const u8,
    input_size: usize,
    output_ptr: [*]u8,
    output_capacity: usize,
) callconv(.c) u32 {
    return component.nativeRender(
        input_ptr[0..input_size],
        output_ptr[0..output_capacity],
    );
}
