const std = @import("std");

const INPUT_CAP: u32 = 1024;
const OUTPUT_CAP: u32 = 8192;
const NAME_CAP: usize = 128;
const EMAIL_CAP: usize = 254;

const KEY_FIRST_NAME = "first_name";
const KEY_EMAIL = "email";
const LABEL_FIRST_NAME = "First name";
const LABEL_EMAIL = "Email address";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var error_buf: [256]u8 = undefined;
var error_size: u32 = 0;

const Step = enum(u2) {
    first_name = 0,
    email = 1,
    done = 2,
};

var step: Step = .first_name;
var first_name_buf: [NAME_CAP]u8 = undefined;
var first_name_size: u32 = 0;
var email_buf: [EMAIL_CAP]u8 = undefined;
var email_size: u32 = 0;

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

export fn input_key_ptr() u32 {
    return switch (step) {
        .first_name => @as(u32, @intCast(@intFromPtr(KEY_FIRST_NAME.ptr))),
        .email => @as(u32, @intCast(@intFromPtr(KEY_EMAIL.ptr))),
        .done => 0,
    };
}

export fn input_key_size() u32 {
    return switch (step) {
        .first_name => @as(u32, @intCast(KEY_FIRST_NAME.len)),
        .email => @as(u32, @intCast(KEY_EMAIL.len)),
        .done => 0,
    };
}

export fn input_label_ptr() u32 {
    return switch (step) {
        .first_name => @as(u32, @intCast(@intFromPtr(LABEL_FIRST_NAME.ptr))),
        .email => @as(u32, @intCast(@intFromPtr(LABEL_EMAIL.ptr))),
        .done => 0,
    };
}

export fn input_label_size() u32 {
    return switch (step) {
        .first_name => @as(u32, @intCast(LABEL_FIRST_NAME.len)),
        .email => @as(u32, @intCast(LABEL_EMAIL.len)),
        .done => 0,
    };
}

export fn error_message_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&error_buf)));
}

export fn error_message_size() u32 {
    return error_size;
}

const Writer = struct {
    idx: usize = 0,
    overflow: bool = false,

    fn writeSlice(self: *Writer, s: []const u8) void {
        if (self.overflow) return;
        if (self.idx + s.len > output_buf.len) {
            self.overflow = true;
            return;
        }
        @memcpy(output_buf[self.idx..][0..s.len], s);
        self.idx += s.len;
    }
};

fn resetError() void {
    error_size = 0;
}

fn setError(msg: []const u8) void {
    const n = @min(msg.len, error_buf.len);
    if (n > 0) @memcpy(error_buf[0..n], msg[0..n]);
    error_size = @as(u32, @intCast(n));
}

fn trimmedASCII(input: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = input.len;
    while (start < end and isSpace(input[start])) : (start += 1) {}
    while (end > start and isSpace(input[end - 1])) : (end -= 1) {}
    return input[start..end];
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

fn storeFirstName(input: []const u8) bool {
    const name = trimmedASCII(input);
    if (name.len == 0) {
        setError("First name is required.");
        return false;
    }
    if (name.len > first_name_buf.len) {
        setError("First name is too long.");
        return false;
    }
    @memcpy(first_name_buf[0..name.len], name);
    first_name_size = @as(u32, @intCast(name.len));
    return true;
}

fn storeEmail(input: []const u8) bool {
    const email = trimmedASCII(input);
    if (email.len == 0) {
        setError("Email address is required.");
        return false;
    }
    if (email.len > email_buf.len) {
        setError("Email address is too long.");
        return false;
    }
    if (!isLikelyEmail(email)) {
        setError("Email address is invalid.");
        return false;
    }
    @memcpy(email_buf[0..email.len], email);
    email_size = @as(u32, @intCast(email.len));
    return true;
}

fn isLikelyEmail(email: []const u8) bool {
    var at_index: ?usize = null;
    for (email, 0..) |ch, i| {
        if (isSpace(ch)) return false;
        if (ch == '@') {
            if (at_index != null) return false;
            at_index = i;
        }
    }
    const at = at_index orelse return false;
    if (at == 0 or at + 1 >= email.len) return false;

    const domain = email[at + 1 ..];
    if (std.mem.indexOfScalar(u8, domain, '.')) |dot| {
        return dot > 0 and dot + 1 < domain.len;
    }
    return false;
}

fn buildMessage() u32 {
    var w = Writer{};
    const name = first_name_buf[0..@as(usize, @intCast(first_name_size))];
    const email = email_buf[0..@as(usize, @intCast(email_size))];

    w.writeSlice("From: no-reply@example.com\n");
    w.writeSlice("To: \"");
    w.writeSlice(name);
    w.writeSlice("\" <");
    w.writeSlice(email);
    w.writeSlice(">\n");
    w.writeSlice("Subject: Welcome, ");
    w.writeSlice(name);
    w.writeSlice("\n");
    w.writeSlice("\n");
    w.writeSlice("Hi ");
    w.writeSlice(name);
    w.writeSlice(",\n");
    w.writeSlice("\n");
    w.writeSlice("Thanks for trying qip form modules.\n");
    w.writeSlice("We will keep in touch at ");
    w.writeSlice(email);
    w.writeSlice(".\n");
    w.writeSlice("\n");
    w.writeSlice("Regards,\n");
    w.writeSlice("qip\n");

    if (w.overflow) {
        setError("Generated email exceeded output capacity.");
        return 0;
    }
    return @as(u32, @intCast(w.idx));
}

export fn run(input_size: u32) u32 {
    const bounded_input_size = @min(input_size, INPUT_CAP);
    const input = input_buf[0..@as(usize, @intCast(bounded_input_size))];
    resetError();

    return switch (step) {
        .first_name => blk: {
            if (!storeFirstName(input)) break :blk 0;
            step = .email;
            break :blk 0;
        },
        .email => blk: {
            if (!storeEmail(input)) break :blk 0;
            step = .done;
            break :blk buildMessage();
        },
        .done => buildMessage(),
    };
}

fn resetState() void {
    step = .first_name;
    first_name_size = 0;
    email_size = 0;
    error_size = 0;
}

test "success flow returns message with headers" {
    resetState();

    const n1 = "Ada";
    @memcpy(input_buf[0..n1.len], n1);
    try std.testing.expectEqual(@as(u32, 0), run(@as(u32, @intCast(n1.len))));
    try std.testing.expectEqual(@as(u32, @intCast(KEY_EMAIL.len)), input_key_size());

    const n2 = "ada@example.com";
    @memcpy(input_buf[0..n2.len], n2);
    const out_size = run(@as(u32, @intCast(n2.len)));
    try std.testing.expect(out_size > 0);
    try std.testing.expectEqual(@as(u32, 0), input_key_size());

    const out = output_buf[0..@as(usize, @intCast(out_size))];
    try std.testing.expect(std.mem.indexOf(u8, out, "From: no-reply@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "To: \"Ada\" <ada@example.com>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Subject: Welcome, Ada") != null);
}

test "invalid first name keeps current step and sets error" {
    resetState();
    const input = "   ";
    @memcpy(input_buf[0..input.len], input);
    try std.testing.expectEqual(@as(u32, 0), run(@as(u32, @intCast(input.len))));
    try std.testing.expectEqual(@as(u32, @intCast(KEY_FIRST_NAME.len)), input_key_size());
    try std.testing.expect(error_message_size() > 0);
}

test "invalid email keeps step and sets error" {
    resetState();

    const n1 = "Ada";
    @memcpy(input_buf[0..n1.len], n1);
    _ = run(@as(u32, @intCast(n1.len)));
    try std.testing.expectEqual(@as(u32, @intCast(KEY_EMAIL.len)), input_key_size());

    const n2 = "ada-at-example.com";
    @memcpy(input_buf[0..n2.len], n2);
    try std.testing.expectEqual(@as(u32, 0), run(@as(u32, @intCast(n2.len))));
    try std.testing.expectEqual(@as(u32, @intCast(KEY_EMAIL.len)), input_key_size());
    try std.testing.expect(error_message_size() > 0);
}
