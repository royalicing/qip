const std = @import("std");

const INPUT_CAP: usize = 1024 * 1024;
const OUTPUT_CAP: usize = 4 * 1024 * 1024;
const INPUT_CONTENT_TYPE = "application/json";
const OUTPUT_CONTENT_TYPE = "application/json";
const MAX_DEPTH: usize = 512;

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

const JsonError = error{ InvalidJson, OutputOverflow };

const Writer = struct {
    buf: []u8,
    idx: usize = 0,

    fn writeByte(self: *Writer, b: u8) JsonError!void {
        if (self.idx >= self.buf.len) return error.OutputOverflow;
        self.buf[self.idx] = b;
        self.idx += 1;
    }

    fn writeSlice(self: *Writer, s: []const u8) JsonError!void {
        if (self.idx + s.len > self.buf.len) return error.OutputOverflow;
        @memcpy(self.buf[self.idx..][0..s.len], s);
        self.idx += s.len;
    }

    fn writeIndent(self: *Writer, depth: usize) JsonError!void {
        var i: usize = 0;
        while (i < depth * 2) : (i += 1) try self.writeByte(' ');
    }
};

const Parser = struct {
    input: []const u8,
    pos: usize = 0,
    out: Writer,

    fn skipWs(self: *Parser) void {
        while (self.pos < self.input.len) : (self.pos += 1) {
            switch (self.input[self.pos]) {
                ' ', '\n', '\r', '\t' => {},
                else => return,
            }
        }
    }

    fn parse(self: *Parser) JsonError!usize {
        self.skipWs();
        try self.value(0);
        self.skipWs();
        if (self.pos != self.input.len) return error.InvalidJson;
        return self.out.idx;
    }

    fn value(self: *Parser, depth: usize) JsonError!void {
        if (depth > MAX_DEPTH or self.pos >= self.input.len) return error.InvalidJson;
        return switch (self.input[self.pos]) {
            '{' => self.object(depth),
            '[' => self.array(depth),
            '"' => self.string(),
            't' => self.literal("true"),
            'f' => self.literal("false"),
            'n' => self.literal("null"),
            '-', '0'...'9' => self.number(),
            else => error.InvalidJson,
        };
    }

    fn literal(self: *Parser, text: []const u8) JsonError!void {
        if (self.pos + text.len > self.input.len) return error.InvalidJson;
        if (!std.mem.eql(u8, self.input[self.pos .. self.pos + text.len], text)) return error.InvalidJson;
        try self.out.writeSlice(text);
        self.pos += text.len;
    }

    fn string(self: *Parser) JsonError!void {
        try self.out.writeByte('"');
        self.pos += 1;
        while (self.pos < self.input.len) {
            const b = self.input[self.pos];
            if (b < 0x20) return error.InvalidJson;
            try self.out.writeByte(b);
            self.pos += 1;
            if (b == '"') return;
            if (b == '\\') {
                if (self.pos >= self.input.len) return error.InvalidJson;
                const esc = self.input[self.pos];
                switch (esc) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {
                        try self.out.writeByte(esc);
                        self.pos += 1;
                    },
                    'u' => {
                        try self.out.writeByte('u');
                        self.pos += 1;
                        var i: usize = 0;
                        while (i < 4) : (i += 1) {
                            if (self.pos >= self.input.len or !std.ascii.isHex(self.input[self.pos])) return error.InvalidJson;
                            try self.out.writeByte(self.input[self.pos]);
                            self.pos += 1;
                        }
                    },
                    else => return error.InvalidJson,
                }
            }
        }
        return error.InvalidJson;
    }

    fn number(self: *Parser) JsonError!void {
        const start = self.pos;
        if (self.input[self.pos] == '-') self.pos += 1;
        if (self.pos >= self.input.len) return error.InvalidJson;
        if (self.input[self.pos] == '0') {
            self.pos += 1;
        } else if (isDigit1to9(self.input[self.pos])) {
            self.pos += 1;
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) self.pos += 1;
        } else return error.InvalidJson;
        if (self.pos < self.input.len and self.input[self.pos] == '.') {
            self.pos += 1;
            if (self.pos >= self.input.len or !std.ascii.isDigit(self.input[self.pos])) return error.InvalidJson;
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) self.pos += 1;
        }
        if (self.pos < self.input.len and (self.input[self.pos] == 'e' or self.input[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < self.input.len and (self.input[self.pos] == '+' or self.input[self.pos] == '-')) self.pos += 1;
            if (self.pos >= self.input.len or !std.ascii.isDigit(self.input[self.pos])) return error.InvalidJson;
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) self.pos += 1;
        }
        try self.out.writeSlice(self.input[start..self.pos]);
    }

    fn object(self: *Parser, depth: usize) JsonError!void {
        self.pos += 1;
        try self.out.writeByte('{');
        self.skipWs();
        if (self.pos < self.input.len and self.input[self.pos] == '}') {
            self.pos += 1;
            try self.out.writeByte('}');
            return;
        }
        while (true) {
            try self.out.writeByte('\n');
            try self.out.writeIndent(depth + 1);
            self.skipWs();
            if (self.pos >= self.input.len or self.input[self.pos] != '"') return error.InvalidJson;
            try self.string();
            self.skipWs();
            if (self.pos >= self.input.len or self.input[self.pos] != ':') return error.InvalidJson;
            self.pos += 1;
            try self.out.writeSlice(": ");
            self.skipWs();
            try self.value(depth + 1);
            self.skipWs();
            if (self.pos >= self.input.len) return error.InvalidJson;
            if (self.input[self.pos] == '}') {
                self.pos += 1;
                try self.out.writeByte('\n');
                try self.out.writeIndent(depth);
                try self.out.writeByte('}');
                return;
            }
            if (self.input[self.pos] != ',') return error.InvalidJson;
            self.pos += 1;
            try self.out.writeByte(',');
        }
    }

    fn array(self: *Parser, depth: usize) JsonError!void {
        self.pos += 1;
        try self.out.writeByte('[');
        self.skipWs();
        if (self.pos < self.input.len and self.input[self.pos] == ']') {
            self.pos += 1;
            try self.out.writeByte(']');
            return;
        }
        while (true) {
            try self.out.writeByte('\n');
            try self.out.writeIndent(depth + 1);
            self.skipWs();
            try self.value(depth + 1);
            self.skipWs();
            if (self.pos >= self.input.len) return error.InvalidJson;
            if (self.input[self.pos] == ']') {
                self.pos += 1;
                try self.out.writeByte('\n');
                try self.out.writeIndent(depth);
                try self.out.writeByte(']');
                return;
            }
            if (self.input[self.pos] != ',') return error.InvalidJson;
            self.pos += 1;
            try self.out.writeByte(',');
        }
    }
};

fn isDigit1to9(b: u8) bool {
    return b >= '1' and b <= '9';
}

fn prettifyJson(input: []const u8, output: []u8) JsonError!usize {
    var parser = Parser{ .input = input, .out = .{ .buf = output } };
    return parser.parse();
}

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_utf8_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&output_buf)));
}

export fn output_utf8_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

export fn input_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr)));
}

export fn input_content_type_size() u32 {
    return @as(u32, @intCast(INPUT_CONTENT_TYPE.len));
}

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(OUTPUT_CONTENT_TYPE.len));
}

export fn render(input_size_in: u32) u32 {
    const input_size = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    const output_size = prettifyJson(input_buf[0..input_size], output_buf[0..]) catch @trap();
    return @as(u32, @intCast(output_size));
}

test "prettifies object" {
    var out: [256]u8 = undefined;
    const len = try prettifyJson("{\"b\":[1,true,null],\"a\":{\"x\":\"y\"}}", out[0..]);
    try std.testing.expectEqualStrings(
        "{\n  \"b\": [\n    1,\n    true,\n    null\n  ],\n  \"a\": {\n    \"x\": \"y\"\n  }\n}",
        out[0..len],
    );
}

test "rejects trailing input" {
    var out: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidJson, prettifyJson("{}x", out[0..]));
}
