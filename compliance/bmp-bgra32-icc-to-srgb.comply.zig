// Content Compliance component: canonical 32-bit BGRA BMP output.
// The ICC conversion itself is exercised by the native/Node fixture tests;
// this checker keeps the reusable byte-level interchange contract independent
// of Little CMS so a future qcms implementation can use the same checker.
extern "qip" fn render_must_equal(
    ordinal: u64,
    input_ptr: u32,
    input_len: u32,
    expected_ptr: u32,
    expected_len: u32,
) i32;
const legacy_input = [_]u8{
    'B', 'M', 0x3A, 0, 0, 0, 0, 0, 0, 0, 0x36, 0, 0, 0,
    0x28, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 32, 0,
    0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0x1E, 0x14, 0x0A, 0xFF,
};

const v5_input = blk: {
    var bytes = [_]u8{0} ** 142;
    bytes[0] = 'B';
    bytes[1] = 'M';
    bytes[2] = 142;
    bytes[10] = 138;
    bytes[14] = 124;
    bytes[18] = 1;
    bytes[22] = 1;
    bytes[26] = 1;
    bytes[28] = 32;
    bytes[34] = 4;
    bytes[54] = 0x00;
    bytes[55] = 0x00;
    bytes[56] = 0xFF;
    bytes[58] = 0x00;
    bytes[59] = 0xFF;
    bytes[62] = 0xFF;
    bytes[66] = 0xFF;
    bytes[70] = 'B';
    bytes[71] = 'G';
    bytes[72] = 'R';
    bytes[73] = 's';
    bytes[138] = 0x1E;
    bytes[139] = 0x14;
    bytes[140] = 0x0A;
    bytes[141] = 0xFF;
    break :blk bytes;
};

const expected = [_]u8{
    'B', 'M', 0x3A, 0, 0, 0, 0, 0, 0, 0, 0x36, 0, 0, 0,
    0x28, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 32, 0,
    0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0x1E, 0x14, 0x0A, 0xFF,
};
const malformed = [_]u8{ 'B', 'M' };

export fn comply() i32 {
    _ = render_must_equal(
        0,
        @intCast(@intFromPtr(&legacy_input)),
        legacy_input.len,
        @intCast(@intFromPtr(&expected)),
        expected.len,
    );
    _ = render_must_equal(
        1,
        @intCast(@intFromPtr(&v5_input)),
        v5_input.len,
        @intCast(@intFromPtr(&expected)),
        expected.len,
    );
    _ = render_must_equal(
        2,
        @intCast(@intFromPtr(&malformed)),
        malformed.len,
        @intCast(@intFromPtr(&malformed)),
        0,
    );
    _ = render_must_equal(3, 0, 0, 0, 0);
    return 4;
}
