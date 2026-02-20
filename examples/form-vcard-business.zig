const std = @import("std");

const INPUT_CAP: u32 = 1024;
const OUTPUT_CAP: u32 = 8192;
const FIELD_CAP: usize = 256;

const KEY_BUSINESS_NAME = "business_name";
const KEY_CONTACT_NAME = "contact_name";
const KEY_JOB_TITLE = "job_title";
const KEY_EMAIL = "email";
const KEY_PHONE = "phone";
const KEY_WEBSITE = "website";

const LABEL_BUSINESS_NAME = "Business name";
const LABEL_CONTACT_NAME = "Contact full name";
const LABEL_JOB_TITLE = "Job title";
const LABEL_EMAIL = "Email address";
const LABEL_PHONE = "Phone number";
const LABEL_WEBSITE = "Website URL";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var error_buf: [256]u8 = undefined;
var error_size: u32 = 0;

var step: u32 = 0;
var business_name_buf: [FIELD_CAP]u8 = undefined;
var business_name_size: u32 = 0;
var contact_name_buf: [FIELD_CAP]u8 = undefined;
var contact_name_size: u32 = 0;
var job_title_buf: [FIELD_CAP]u8 = undefined;
var job_title_size: u32 = 0;
var email_buf: [FIELD_CAP]u8 = undefined;
var email_size: u32 = 0;
var phone_buf: [FIELD_CAP]u8 = undefined;
var phone_size: u32 = 0;
var website_buf: [FIELD_CAP]u8 = undefined;
var website_size: u32 = 0;

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
        0 => @as(u32, @intCast(@intFromPtr(KEY_BUSINESS_NAME.ptr))),
        1 => @as(u32, @intCast(@intFromPtr(KEY_CONTACT_NAME.ptr))),
        2 => @as(u32, @intCast(@intFromPtr(KEY_JOB_TITLE.ptr))),
        3 => @as(u32, @intCast(@intFromPtr(KEY_EMAIL.ptr))),
        4 => @as(u32, @intCast(@intFromPtr(KEY_PHONE.ptr))),
        5 => @as(u32, @intCast(@intFromPtr(KEY_WEBSITE.ptr))),
        else => 0,
    };
}

export fn input_key_size() u32 {
    return switch (step) {
        0 => @as(u32, @intCast(KEY_BUSINESS_NAME.len)),
        1 => @as(u32, @intCast(KEY_CONTACT_NAME.len)),
        2 => @as(u32, @intCast(KEY_JOB_TITLE.len)),
        3 => @as(u32, @intCast(KEY_EMAIL.len)),
        4 => @as(u32, @intCast(KEY_PHONE.len)),
        5 => @as(u32, @intCast(KEY_WEBSITE.len)),
        else => 0,
    };
}

export fn input_label_ptr() u32 {
    return switch (step) {
        0 => @as(u32, @intCast(@intFromPtr(LABEL_BUSINESS_NAME.ptr))),
        1 => @as(u32, @intCast(@intFromPtr(LABEL_CONTACT_NAME.ptr))),
        2 => @as(u32, @intCast(@intFromPtr(LABEL_JOB_TITLE.ptr))),
        3 => @as(u32, @intCast(@intFromPtr(LABEL_EMAIL.ptr))),
        4 => @as(u32, @intCast(@intFromPtr(LABEL_PHONE.ptr))),
        5 => @as(u32, @intCast(@intFromPtr(LABEL_WEBSITE.ptr))),
        else => 0,
    };
}

export fn input_label_size() u32 {
    return switch (step) {
        0 => @as(u32, @intCast(LABEL_BUSINESS_NAME.len)),
        1 => @as(u32, @intCast(LABEL_CONTACT_NAME.len)),
        2 => @as(u32, @intCast(LABEL_JOB_TITLE.len)),
        3 => @as(u32, @intCast(LABEL_EMAIL.len)),
        4 => @as(u32, @intCast(LABEL_PHONE.len)),
        5 => @as(u32, @intCast(LABEL_WEBSITE.len)),
        else => 0,
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

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

fn trimASCII(input: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = input.len;
    while (start < end and isSpace(input[start])) : (start += 1) {}
    while (end > start and isSpace(input[end - 1])) : (end -= 1) {}
    return input[start..end];
}

fn hasLineBreak(s: []const u8) bool {
    for (s) |ch| {
        if (ch == '\n' or ch == '\r') return true;
    }
    return false;
}

fn storeRequired(input: []const u8, buf: []u8, len_out: *u32, required_msg: []const u8, too_long_msg: []const u8, single_line_msg: []const u8) bool {
    const value = trimASCII(input);
    if (value.len == 0) {
        setError(required_msg);
        return false;
    }
    if (value.len > buf.len) {
        setError(too_long_msg);
        return false;
    }
    if (hasLineBreak(value)) {
        setError(single_line_msg);
        return false;
    }
    @memcpy(buf[0..value.len], value);
    len_out.* = @as(u32, @intCast(value.len));
    return true;
}

fn looksLikeEmail(value: []const u8) bool {
    var at_index: ?usize = null;
    for (value, 0..) |ch, i| {
        if (isSpace(ch)) return false;
        if (ch == '@') {
            if (at_index != null) return false;
            at_index = i;
        }
    }
    const at = at_index orelse return false;
    if (at == 0 or at + 1 >= value.len) return false;
    const domain = value[at + 1 ..];
    if (std.mem.indexOfScalar(u8, domain, '.')) |dot| {
        return dot > 0 and dot + 1 < domain.len;
    }
    return false;
}

fn storeEmail(input: []const u8) bool {
    const value = trimASCII(input);
    if (!storeRequired(value, email_buf[0..], &email_size, "Email address is required.", "Email address is too long.", "Email address must be a single line.")) return false;
    const email = email_buf[0..@as(usize, @intCast(email_size))];
    if (!looksLikeEmail(email)) {
        setError("Email address is invalid.");
        return false;
    }
    return true;
}

fn storeWebsite(input: []const u8) bool {
    const value = trimASCII(input);
    if (!storeRequired(value, website_buf[0..], &website_size, "Website URL is required.", "Website URL is too long.", "Website URL must be a single line.")) return false;
    const url = website_buf[0..@as(usize, @intCast(website_size))];
    if (!(std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://"))) {
        setError("Website URL must start with http:// or https://");
        return false;
    }
    return true;
}

fn writeEscapedVCardValue(w: *Writer, s: []const u8) void {
    for (s) |ch| {
        switch (ch) {
            ',', ';', '\\' => {
                w.writeSlice("\\");
                var one = [1]u8{ch};
                w.writeSlice(one[0..]);
            },
            else => {
                var one = [1]u8{ch};
                w.writeSlice(one[0..]);
            },
        }
    }
}

fn buildVCard() u32 {
    const business_name = business_name_buf[0..@as(usize, @intCast(business_name_size))];
    const contact_name = contact_name_buf[0..@as(usize, @intCast(contact_name_size))];
    const job_title = job_title_buf[0..@as(usize, @intCast(job_title_size))];
    const email = email_buf[0..@as(usize, @intCast(email_size))];
    const phone = phone_buf[0..@as(usize, @intCast(phone_size))];
    const website = website_buf[0..@as(usize, @intCast(website_size))];

    var w = Writer{};
    w.writeSlice("BEGIN:VCARD\r\n");
    w.writeSlice("VERSION:3.0\r\n");
    w.writeSlice("FN:");
    writeEscapedVCardValue(&w, contact_name);
    w.writeSlice("\r\n");
    w.writeSlice("ORG:");
    writeEscapedVCardValue(&w, business_name);
    w.writeSlice("\r\n");
    w.writeSlice("TITLE:");
    writeEscapedVCardValue(&w, job_title);
    w.writeSlice("\r\n");
    w.writeSlice("EMAIL;TYPE=INTERNET:");
    writeEscapedVCardValue(&w, email);
    w.writeSlice("\r\n");
    w.writeSlice("TEL;TYPE=WORK,VOICE:");
    writeEscapedVCardValue(&w, phone);
    w.writeSlice("\r\n");
    w.writeSlice("URL:");
    writeEscapedVCardValue(&w, website);
    w.writeSlice("\r\n");
    w.writeSlice("END:VCARD\r\n");

    if (w.overflow) {
        setError("Generated vCard exceeded output capacity.");
        return 0;
    }
    return @as(u32, @intCast(w.idx));
}

export fn run(input_size: u32) u32 {
    const bounded_input_size = @min(input_size, INPUT_CAP);
    const input = input_buf[0..@as(usize, @intCast(bounded_input_size))];
    resetError();

    if (step == 0) {
        if (!storeRequired(input, business_name_buf[0..], &business_name_size, "Business name is required.", "Business name is too long.", "Business name must be a single line.")) return 0;
        step = 1;
        return 0;
    }
    if (step == 1) {
        if (!storeRequired(input, contact_name_buf[0..], &contact_name_size, "Contact full name is required.", "Contact full name is too long.", "Contact full name must be a single line.")) return 0;
        step = 2;
        return 0;
    }
    if (step == 2) {
        if (!storeRequired(input, job_title_buf[0..], &job_title_size, "Job title is required.", "Job title is too long.", "Job title must be a single line.")) return 0;
        step = 3;
        return 0;
    }
    if (step == 3) {
        if (!storeEmail(input)) return 0;
        step = 4;
        return 0;
    }
    if (step == 4) {
        if (!storeRequired(input, phone_buf[0..], &phone_size, "Phone number is required.", "Phone number is too long.", "Phone number must be a single line.")) return 0;
        step = 5;
        return 0;
    }
    if (step == 5) {
        if (!storeWebsite(input)) return 0;
        step = 6;
        return buildVCard();
    }

    return buildVCard();
}

fn resetState() void {
    step = 0;
    business_name_size = 0;
    contact_name_size = 0;
    job_title_size = 0;
    email_size = 0;
    phone_size = 0;
    website_size = 0;
    error_size = 0;
}

fn feed(input: []const u8) u32 {
    @memcpy(input_buf[0..input.len], input);
    return run(@as(u32, @intCast(input.len)));
}

test "successful flow outputs business vcard" {
    resetState();
    try std.testing.expectEqual(@as(u32, 0), feed("Acme Co"));
    try std.testing.expectEqual(@as(u32, @intCast(KEY_CONTACT_NAME.len)), input_key_size());
    try std.testing.expectEqual(@as(u32, 0), feed("Ada Lovelace"));
    try std.testing.expectEqual(@as(u32, @intCast(KEY_JOB_TITLE.len)), input_key_size());
    try std.testing.expectEqual(@as(u32, 0), feed("Founder"));
    try std.testing.expectEqual(@as(u32, @intCast(KEY_EMAIL.len)), input_key_size());
    try std.testing.expectEqual(@as(u32, 0), feed("ada@acme.example"));
    try std.testing.expectEqual(@as(u32, @intCast(KEY_PHONE.len)), input_key_size());
    try std.testing.expectEqual(@as(u32, 0), feed("+1-212-555-0100"));
    try std.testing.expectEqual(@as(u32, @intCast(KEY_WEBSITE.len)), input_key_size());
    const out_size = feed("https://acme.example");
    try std.testing.expect(out_size > 0);
    try std.testing.expectEqual(@as(u32, 0), input_key_size());

    const out = output_buf[0..@as(usize, @intCast(out_size))];
    try std.testing.expect(std.mem.indexOf(u8, out, "BEGIN:VCARD\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FN:Ada Lovelace\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ORG:Acme Co\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "END:VCARD\r\n") != null);
}

test "invalid email keeps step and sets error" {
    resetState();
    _ = feed("Acme Co");
    _ = feed("Ada Lovelace");
    _ = feed("Founder");
    try std.testing.expectEqual(@as(u32, 0), feed("ada-at-acme.example"));
    try std.testing.expectEqual(@as(u32, @intCast(KEY_EMAIL.len)), input_key_size());
    try std.testing.expect(error_message_size() > 0);
}

test "invalid website keeps step and sets error" {
    resetState();
    _ = feed("Acme Co");
    _ = feed("Ada Lovelace");
    _ = feed("Founder");
    _ = feed("ada@acme.example");
    _ = feed("+1-212-555-0100");
    try std.testing.expectEqual(@as(u32, 0), feed("acme.example"));
    try std.testing.expectEqual(@as(u32, @intCast(KEY_WEBSITE.len)), input_key_size());
    try std.testing.expect(error_message_size() > 0);
}
