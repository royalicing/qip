const runner = @import("lib/syntax-highlight-comply.zig");

const fixtures = runner.parseFixtures(
    @embedFile("syntax-highlight-swift.fixtures.txt"),
);

export fn comply() i32 {
    return runner.runFixtures(fixtures);
}
