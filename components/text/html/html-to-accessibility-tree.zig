const accessibility = @import("lib/html-accessibility.zig");

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&accessibility.input_buf));
}

export fn input_utf8_cap() u32 {
    return accessibility.INPUT_CAP;
}

export fn output_ptr() u32 {
    return @intCast(@intFromPtr(&accessibility.output_buf));
}

export fn output_utf8_cap() u32 {
    return accessibility.OUTPUT_CAP;
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(accessibility.INPUT_CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return accessibility.INPUT_CONTENT_TYPE.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(accessibility.OUTPUT_CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return accessibility.OUTPUT_CONTENT_TYPE.len;
}

export fn render(input_size: u32) u32 {
    return accessibility.render(input_size);
}
