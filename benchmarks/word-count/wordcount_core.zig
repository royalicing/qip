const std = @import("std");

pub const Result = struct {
    output: []u8,
    total_words: usize,
    unique_words: usize,
};

pub const Entry = struct {
    word: []const u8,
    count: usize,
};

fn isLetter(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn lowerAscii(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn entryLess(_: void, a: Entry, b: Entry) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.word, b.word);
}

pub fn countWords(allocator: std.mem.Allocator, input: []const u8) !Result {
    var map = std.StringHashMap(usize).init(allocator);
    defer map.deinit();

    var total_words: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        while (i < input.len and !isLetter(input[i])) : (i += 1) {}
        const start = i;
        while (i < input.len and isLetter(input[i])) : (i += 1) {}
        const end = i;
        if (end <= start) continue;

        const word_len = end - start;
        var lower = try allocator.alloc(u8, word_len);
        errdefer allocator.free(lower);
        for (input[start..end], 0..) |ch, j| lower[j] = lowerAscii(ch);

        const key = try allocator.dupe(u8, lower);
        allocator.free(lower);

        const gop = try map.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = 1;
        } else {
            allocator.free(key);
            gop.value_ptr.* += 1;
        }
        total_words += 1;
    }

    var entries = try allocator.alloc(Entry, map.count());
    defer allocator.free(entries);

    var it = map.iterator();
    var idx: usize = 0;
    while (it.next()) |kv| {
        entries[idx] = .{ .word = kv.key_ptr.*, .count = kv.value_ptr.* };
        idx += 1;
    }

    std.sort.block(Entry, entries, {}, entryLess);

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    const top_n = @min(entries.len, 10);
    for (entries[0..top_n]) |e| {
        try out.writer().print("{}\t{s}\n", .{ e.count, e.word });
    }
    try out.writer().writeAll("--\n");
    try out.writer().print("total\t{}\n", .{total_words});
    try out.writer().print("unique\t{}\n", .{entries.len});

    // Free map keys after output is built.
    var it_free = map.iterator();
    while (it_free.next()) |kv| allocator.free(kv.key_ptr.*);

    return .{
        .output = try out.toOwnedSlice(),
        .total_words = total_words,
        .unique_words = entries.len,
    };
}

pub fn countWordsOptimized(allocator: std.mem.Allocator, input: []const u8) !Result {
    var map = std.StringHashMap(usize).init(allocator);
    defer map.deinit();

    var total_words: usize = 0;
    var token = std.array_list.Managed(u8).init(allocator);
    defer token.deinit();

    var i: usize = 0;
    while (i <= input.len) : (i += 1) {
        const c: u8 = if (i < input.len) input[i] else 0;
        if (i < input.len and isLetter(c)) {
            try token.append(lowerAscii(c));
            continue;
        }

        if (token.items.len == 0) continue;

        const word = token.items;
        const key = try allocator.dupe(u8, word);
        const gop = try map.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = 1;
        } else {
            allocator.free(key);
            gop.value_ptr.* += 1;
        }
        total_words += 1;
        token.clearRetainingCapacity();
    }

    var entries = try allocator.alloc(Entry, map.count());
    defer allocator.free(entries);

    var it = map.iterator();
    var idx: usize = 0;
    while (it.next()) |kv| {
        entries[idx] = .{ .word = kv.key_ptr.*, .count = kv.value_ptr.* };
        idx += 1;
    }

    std.sort.block(Entry, entries, {}, entryLess);

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    const top_n = @min(entries.len, 10);
    for (entries[0..top_n]) |e| {
        try out.writer().print("{}\t{s}\n", .{ e.count, e.word });
    }
    try out.writer().writeAll("--\n");
    try out.writer().print("total\t{}\n", .{total_words});
    try out.writer().print("unique\t{}\n", .{entries.len});

    var it_free = map.iterator();
    while (it_free.next()) |kv| allocator.free(kv.key_ptr.*);

    return .{
        .output = try out.toOwnedSlice(),
        .total_words = total_words,
        .unique_words = entries.len,
    };
}
