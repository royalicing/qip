const std = @import("std");

// Memory layout
const INPUT_CAP: u32 = 0x10000;
const OUTPUT_CAP: u32 = 0x10000;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&output_buf)));
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

// Get input/output slices
fn getInput(size: u32) []u8 {
    return input_buf[0..@as(usize, @intCast(size))];
}

fn getOutput() []u8 {
    return output_buf[0..];
}

// Main entry point
export fn run(input_size: u32) u32 {
    const input = getInput(input_size);
    const output = getOutput();
    const input_bytes_size: usize = @intCast(input_size);

    // Example: prepend "Hello, " to input
    const prefix = "Hello, ";
    @memcpy(output[0..prefix.len], prefix);

    if (input_size > 0) {
        // Copy input after prefix
        @memcpy(output[prefix.len..][0..input_bytes_size], input);
        return @intCast(prefix.len + input_bytes_size);
    } else {
        // Default to "World" if no input
        const default_name = "World";
        @memcpy(output[prefix.len..][0..default_name.len], default_name);
        return @intCast(prefix.len + default_name.len);
    }
}
