const std = @import("std");
const accessibility = @import("lib/html-accessibility.zig");

const INPUT_CAP: usize = 256 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP;
const CONTENT_TYPE = "text/html";

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&accessibility.input_buf));
}

export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}

export fn output_ptr() u32 {
    return input_ptr();
}

export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}

export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(CONTENT_TYPE.ptr));
}

export fn input_content_type_size() u32 {
    return CONTENT_TYPE.len;
}

export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(CONTENT_TYPE.ptr));
}

export fn output_content_type_size() u32 {
    return CONTENT_TYPE.len;
}

export fn render(input_size_in: u32) u32 {
    const input_size: usize = @intCast(input_size_in);
    if (input_size > INPUT_CAP) @trap();
    if (!accessibility.accessibleNamesAreUnique(accessibility.input_buf[0..input_size])) @trap();
    return input_size_in;
}

fn validate(input: []const u8) bool {
    return accessibility.accessibleNamesAreUnique(input);
}

test "accepts distinct computed accessible names" {
    try std.testing.expect(validate("<main><button>Save</button><button>Cancel</button><img alt=Logo></main>"));
}

test "rejects duplicate names from different naming mechanisms" {
    try std.testing.expect(!validate("<button>Save</button><button aria-label=Save>Icon</button>"));
    try std.testing.expect(!validate("<span id=label>Account</span><input aria-labelledby=label><input aria-label=Account>"));
    try std.testing.expect(!validate("<label for=one>Email</label><input id=one><input title=Email>"));
}

test "ignores empty names and hidden accessible objects" {
    try std.testing.expect(validate("<main><p>One</p><p>Two</p><button></button><button hidden>Save</button><button>Save</button></main>"));
}
