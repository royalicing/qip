extern "qip" fn render_must_equal(
    ordinal: u64,
    input_ptr: u32,
    input_len: u32,
    expected_ptr: u32,
    expected_len: u32,
) i32;

extern "qip" fn render_must_trap(
    ordinal: u64,
    input_ptr: u32,
    input_len: u32,
) i32;

const Fixture = struct {
    input: []const u8,
    expected: []const u8,
};

const corpus = @embedFile("mermaid-to-unicode-html.fixtures.txt");
const input_marker = "=== INPUT ===\n";
const output_marker = "\n=== OUTPUT ===\n";
const end_marker = "=== END ===\n";

comptime {
    @setEvalBranchQuota(1_000_000);
}

const fixtures = parseFixtures(corpus);

// Simon preserves a label row above horizontal edges, including its trailing
// spaces when the edge has no label. Keep that byte-level quirk explicit here
// rather than putting trailing whitespace in the text fixture file.
const literal_fixtures = [_]Fixture{
    .{
        .input = "flowchart LR\n A[Start] --> B[End]",
        .expected = "                    \n" ++
            "<span class=\"b\">┌</span><span class=\"e\">───────</span><span class=\"b\">┐</span>    <span class=\"b\">┌</span><span class=\"e\">─────</span><span class=\"b\">┐</span>\n" ++
            "<span class=\"e\">│</span> <span class=\"n\">Start</span> <span class=\"e\">├───▶│</span> <span class=\"n\">End</span> <span class=\"e\">│</span>\n" ++
            "<span class=\"b\">└</span><span class=\"e\">───────</span><span class=\"b\">┘</span>    <span class=\"b\">└</span><span class=\"e\">─────</span><span class=\"b\">┘</span>\n",
    },
};

const Variant = struct {
    input: []const u8,
    expected_fixture: usize,
};

// Syntax variations whose layout is intentionally identical to a canonical
// byte-for-byte fixture above. Keeping them compact lets the corpus cover
// parser behavior without copying the same large HTML fragment many times.
const variants = [_]Variant{
    .{ .input = "   \n\t", .expected_fixture = 28 },
    // Flowcharts: header aliases, comments, whitespace, and ignored styling.
    .{ .input = "flowchart TB\n A[Start] --> B{Choose}\n B -->|yes| C{Again}\n B -->|no| D[Stop]\n C -->|yes| E(Go)\n C -->|no| F[No way]\n E -.-> G[Log]\n E ==> H[Done]", .expected_fixture = 20 },
    .{ .input = "graph TB\n %% entry and decisions\n A[Start] --> B{Choose}\n B -->|yes| C{Again}\n B -->|no| D[Stop]\n %% second decision\n C -->|yes| E(Go)\n C -->|no| F[No way]\n E -.-> G[Log]\n E ==> H[Done]", .expected_fixture = 20 },
    .{ .input = "\n  graph TD\n\n A[Start] --> B{Choose}\n B -->|yes| C{Again}\n B -->|no| D[Stop]\n C -->|yes| E(Go)\n C -->|no| F[No way]\n E -.-> G[Log]\n E ==> H[Done]\n", .expected_fixture = 20 },
    .{ .input = "graph TD\n A[Start] --> B{Choose}\n B -->|yes| C{Again}\n B -->|no| D[Stop]\n C -->|yes| E(Go)\n C -->|no| F[No way]\n E -.-> G[Log]\n E ==> H[Done]\n classDef muted fill:#eee\n class A muted", .expected_fixture = 20 },

    // Sequence diagrams: declarations are optional; actor is a participant
    // alias; activation markers do not affect terminal layout.
    .{ .input = "sequenceDiagram\n Alice->>Bob: Hello\n Bob-->>Alice: Hi", .expected_fixture = 17 },
    .{ .input = "sequenceDiagram\n actor A as Alice\n actor B as Bob\n A->>B: Hello\n B-->>A: Hi", .expected_fixture = 17 },
    .{ .input = "sequenceDiagram\n participant A as Alice\n participant B as Bob\n %% request/reply\n A->>+B: Hello\n B-->>-A: Hi", .expected_fixture = 17 },
    .{ .input = "\n sequenceDiagram\n\n participant A as Alice\n participant B as Bob\n A->>B: Hello\n\n B-->>A: Hi\n", .expected_fixture = 17 },

    // State diagrams: v1/v2 headers, comments, indentation, and tail-statement
    // order all describe the same graph.
    .{ .input = "stateDiagram\n [*] --> A\n A --> B : go\n B --> C : yes\n B --> D : no\n D --> B : retry\n C --> [*]", .expected_fixture = 21 },
    .{ .input = "stateDiagram-v2\n %% start\n [*] --> A\n A --> B : go\n B --> C : yes\n B --> D : no\n C --> [*]\n D --> B : retry", .expected_fixture = 21 },
    .{ .input = "\n stateDiagram-v2\n\n\t[*] --> A\n\tA --> B : go\n\tB --> C : yes\n\tB --> D : no\n\tD --> B : retry\n\tC --> [*]\n", .expected_fixture = 21 },

    // Class and ER diagrams: comments and declaration placement are layout
    // neutral, as are Mermaid.js-only styling directives.
    .{ .input = "classDiagram\n %% domain model\n class Base {\n +field\n +method()\n }\n Base <|-- One\n Base <|-- Two\n One : +run()", .expected_fixture = 18 },
    .{ .input = "classDiagram\n class Base {\n +field\n +method()\n }\n Base <|-- One\n Base <|-- Two\n One : +run()\n classDef quiet fill:#fff\n style Base stroke:#000", .expected_fixture = 18 },
    .{ .input = "erDiagram\n %% authoring model\n USER ||--o{ POST : writes\n POST ||--|{ COMMENT : has\n USER {\n string id\n }", .expected_fixture = 19 },
    .{ .input = "erDiagram\n USER {\n string id\n }\n USER ||--o{ POST : writes\n POST ||--|{ COMMENT : has", .expected_fixture = 19 },

    // Grouped flowcharts ignore comments and styling just like plain graphs.
    .{ .input = "flowchart LR\n %% browser side\n subgraph Client\n UI[Browser UI] --> SW[Service worker]\n end\n %% server side\n subgraph Server\n API[API gateway] --> DB[Postgres]\n end\n SW -->|HTTPS| API", .expected_fixture = 23 },
};

fn parseFixtures(comptime source: []const u8) [countFixtures(source)]Fixture {
    @setEvalBranchQuota(1_000_000);
    comptime var result: [countFixtures(source)]Fixture = undefined;
    comptime var rest = source;
    comptime var index: usize = 0;
    inline while (rest.len != 0) {
        if (rest[0] == '\n') {
            rest = rest[1..];
            if (rest.len == 0) break;
        }
        if (!@import("std").mem.startsWith(u8, rest, input_marker))
            @compileError("fixture must start with an input marker");
        rest = rest[input_marker.len..];
        const output_at = @import("std").mem.indexOf(u8, rest, output_marker) orelse
            @compileError("fixture is missing an output marker");
        const input = rest[0..output_at];
        rest = rest[output_at + output_marker.len ..];
        const end_at = @import("std").mem.indexOf(u8, rest, end_marker) orelse
            @compileError("fixture is missing an end marker");
        result[index] = .{ .input = input, .expected = rest[0..end_at] };
        index += 1;
        rest = rest[end_at + end_marker.len ..];
    }
    return result;
}

fn countFixtures(comptime source: []const u8) usize {
    @setEvalBranchQuota(1_000_000);
    comptime var count: usize = 0;
    comptime var rest = source;
    inline while (@import("std").mem.indexOf(u8, rest, input_marker)) |at| {
        count += 1;
        rest = rest[at + input_marker.len ..];
    }
    return count;
}

const invalid = [_][]const u8{
    "pie title Pets\n  \"Dogs\" : 386\n  \"Cats\" : 85",
    "journey\n  title Unsupported",
    "sequenceDiagram\n  ->>B: orphan",
    "stateDiagram-v2\n  A --> B\n  some garbage line",
    "classDiagram\n  Animal <|--",
    "erDiagram\n  CUSTOMER ||-- ORDER",
};

export fn comply() i32 {
    comptime var ordinal: u64 = 0;
    inline for (fixtures) |fixture| {
        _ = render_must_equal(
            ordinal,
            @intCast(@intFromPtr(fixture.input.ptr)),
            @intCast(fixture.input.len),
            @intCast(@intFromPtr(fixture.expected.ptr)),
            @intCast(fixture.expected.len),
        );
        ordinal += 1;
    }
    inline for (literal_fixtures) |fixture| {
        _ = render_must_equal(
            ordinal,
            @intCast(@intFromPtr(fixture.input.ptr)),
            @intCast(fixture.input.len),
            @intCast(@intFromPtr(fixture.expected.ptr)),
            @intCast(fixture.expected.len),
        );
        ordinal += 1;
    }
    inline for (variants) |variant| {
        const expected = fixtures[variant.expected_fixture].expected;
        _ = render_must_equal(
            ordinal,
            @intCast(@intFromPtr(variant.input.ptr)),
            @intCast(variant.input.len),
            @intCast(@intFromPtr(expected.ptr)),
            @intCast(expected.len),
        );
        ordinal += 1;
    }
    inline for (invalid) |input| {
        _ = render_must_trap(
            ordinal,
            @intCast(@intFromPtr(input.ptr)),
            @intCast(input.len),
        );
        ordinal += 1;
    }
    return @intCast(ordinal);
}
