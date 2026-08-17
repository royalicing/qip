const std = @import("std");

extern "qip" fn must_render_exactly(
    ordinal: u64,
    input_ptr: u32,
    input_len: u32,
    expected_ptr: u32,
    expected_len: u32,
) i32;

const Case = struct {
    input: []const u8,
    expected: []const u8,
};

fn response(
    comptime target_uri: []const u8,
    comptime content_type: []const u8,
    comptime body: []const u8,
) []const u8 {
    const http = std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ content_type, body.len, body },
    );
    return std.fmt.comptimePrint(
        "WARC/1.1\r\n" ++
            "WARC-Type: response\r\n" ++
            "WARC-Target-URI: {s}\r\n" ++
            "WARC-Date: 2000-01-01T00:00:00Z\r\n" ++
            "WARC-Record-ID: <urn:uuid:00000000-0000-4000-8000-000000000001>\r\n" ++
            "Content-Type: application/http; msgtype=response\r\n" ++
            "Content-Length: {d}\r\n\r\n" ++
            "{s}\r\n\r\n",
        .{ target_uri, http.len, http },
    );
}

fn htmlCase(
    comptime target_uri: []const u8,
    comptime input_body: []const u8,
    comptime expected_body: []const u8,
) Case {
    return .{
        .input = response(target_uri, "text/html; charset=utf-8", input_body),
        .expected = response(target_uri, "text/html; charset=utf-8", expected_body),
    };
}

const cases = [_]Case{
    htmlCase(
        "https://example.test/page?language=fr",
        "<qip-connect-search-params><input type=\"hidden\" name=\"language\" value=\"en\"></qip-connect-search-params>",
        "<qip-connect-search-params><input type=\"hidden\" name=\"language\" value=\"fr\" data-qip-fallback=\"en\"></qip-connect-search-params>",
    ),
    htmlCase(
        "https://example.test/page",
        "<qip-connect-search-params><input type=\"hidden\" name=\"language\" value=\"en\"></qip-connect-search-params>",
        "<qip-connect-search-params><input type=\"hidden\" name=\"language\" value=\"en\" data-qip-fallback=\"en\"></qip-connect-search-params>",
    ),
    htmlCase(
        "https://example.test/page?language=",
        "<qip-connect-search-params><input type=\"hidden\" name=\"language\" value=\"en\"></qip-connect-search-params>",
        "<qip-connect-search-params><input type=\"hidden\" name=\"language\" value=\"\" data-qip-fallback=\"en\"></qip-connect-search-params>",
    ),
    htmlCase(
        "https://example.test/page?language=fr&currency=EUR&ignored=x",
        "<qip-connect-search-params><input type=\"hidden\" name=\"language\" value=\"en\"><input type=\"hidden\" name=\"currency\" value=\"AUD\"></qip-connect-search-params>",
        "<qip-connect-search-params><input type=\"hidden\" name=\"language\" value=\"fr\" data-qip-fallback=\"en\"><input type=\"hidden\" name=\"currency\" value=\"EUR\" data-qip-fallback=\"AUD\"></qip-connect-search-params>",
    ),
    htmlCase(
        "https://example.test/page?name=Tom+%26+%22T%22",
        "<qip-connect-search-params><input type=\"hidden\" name=\"name\" value=\"World\"></qip-connect-search-params>",
        "<qip-connect-search-params><input type=\"hidden\" name=\"name\" value=\"Tom &amp; &quot;T&quot;\" data-qip-fallback=\"World\"></qip-connect-search-params>",
    ),
    htmlCase(
        "https://example.test/page?language=fr&language=de",
        "<qip-connect-search-params><input type=\"hidden\" name=\"language\" value=\"en\"></qip-connect-search-params>",
        "<qip-connect-search-params><input type=\"hidden\" name=\"language\" value=\"fr\" data-qip-fallback=\"en\"></qip-connect-search-params>",
    ),
    htmlCase(
        "https://example.test/page?language=de",
        "<qip-connect-search-params><input type=\"hidden\" name=\"language\" value=\"fr\" data-qip-fallback=\"en\"></qip-connect-search-params>",
        "<qip-connect-search-params><input type=\"hidden\" name=\"language\" value=\"de\" data-qip-fallback=\"en\"></qip-connect-search-params>",
    ),
    htmlCase(
        "https://example.test/page",
        "<qip-connect-search-params><input type=\"hidden\" name=\"language\" value=\"fr\" data-qip-fallback=\"en\"></qip-connect-search-params>",
        "<qip-connect-search-params><input type=\"hidden\" name=\"language\" value=\"en\" data-qip-fallback=\"en\"></qip-connect-search-params>",
    ),
    htmlCase(
        "https://example.test/page?language=fr",
        "<p><input type=\"hidden\" name=\"language\" value=\"en\"></p>",
        "<p><input type=\"hidden\" name=\"language\" value=\"en\"></p>",
    ),
    .{
        .input = response(
            "https://example.test/page?language=fr",
            "text/plain",
            "<qip-connect-search-params><input type=\"hidden\" name=\"language\" value=\"en\"></qip-connect-search-params>",
        ),
        .expected = response(
            "https://example.test/page?language=fr",
            "text/plain",
            "<qip-connect-search-params><input type=\"hidden\" name=\"language\" value=\"en\"></qip-connect-search-params>",
        ),
    },
};

export fn uniform_set_seed(_: i32) void {}

export fn comply() i32 {
    inline for (cases, 0..) |case, ordinal| {
        _ = must_render_exactly(
            ordinal,
            @intCast(@intFromPtr(case.input.ptr)),
            @intCast(case.input.len),
            @intCast(@intFromPtr(case.expected.ptr)),
            @intCast(case.expected.len),
        );
    }
    return cases.len;
}
