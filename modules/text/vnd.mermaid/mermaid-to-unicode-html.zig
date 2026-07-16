const std = @import("std");

const INPUT_CAP = 64 * 1024;
const OUTPUT_CAP = 1024 * 1024;
const MAX_ROWS = 512;
const MAX_COLS = 512;
const MAX_PARTICIPANTS = 24;
const MAX_MESSAGES = 128;
const MAX_ENTITIES = 32;
const MAX_MEMBERS = 16;

const INPUT_CONTENT_TYPE = "text/vnd.mermaid";
const OUTPUT_CONTENT_TYPE = "text/html";

var input_buffer: [INPUT_CAP]u8 = undefined;
var output_buffer: [OUTPUT_CAP]u8 = undefined;
var cells: [MAX_ROWS][MAX_COLS]Cell = undefined;
var canvas_width: usize = 0;
var canvas_height: usize = 0;

const Role = enum(u8) { none, border, node, edge, edge_label, title };
const Cell = struct { char: u21 = ' ', role: Role = .none };

const Participant = struct {
    id: []const u8,
    label: []const u8,
    center: usize = 0,
};

const Message = struct {
    from: usize,
    to: usize,
    label: []const u8,
    dashed: bool,
};

const Entity = struct {
    id: []const u8,
    label: []const u8,
    members: [MAX_MEMBERS][]const u8 = undefined,
    member_count: usize = 0,
    parent: ?usize = null,
    relation: []const u8 = "",
    from_cardinality: []const u8 = "",
    to_cardinality: []const u8 = "",
};

export fn input_ptr() u32 {
    return @intCast(@intFromPtr(&input_buffer));
}
export fn input_utf8_cap() u32 {
    return INPUT_CAP;
}
export fn output_ptr() u32 {
    return @intCast(@intFromPtr(&output_buffer));
}
export fn output_utf8_cap() u32 {
    return OUTPUT_CAP;
}
export fn input_content_type_ptr() u32 {
    return @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr));
}
export fn input_content_type_size() u32 {
    return INPUT_CONTENT_TYPE.len;
}
export fn output_content_type_ptr() u32 {
    return @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr));
}
export fn output_content_type_size() u32 {
    return OUTPUT_CONTENT_TYPE.len;
}

export fn render(input_size_raw: u32) u32 {
    const input_size: usize = @intCast(input_size_raw);
    if (input_size == 0 or input_size > INPUT_CAP) @trap();
    const source = input_buffer[0..input_size];
    if (!std.unicode.utf8ValidateSlice(source)) @trap();
    if (std.mem.startsWith(u8, std.mem.trimLeft(u8, source, " \t\r\n"), "sequenceDiagram")) {
        renderSequence(source);
    } else if (std.mem.startsWith(u8, std.mem.trimLeft(u8, source, " \t\r\n"), "classDiagram")) {
        renderClass(source);
    } else if (std.mem.startsWith(u8, std.mem.trimLeft(u8, source, " \t\r\n"), "erDiagram")) {
        renderEr(source);
    } else if (std.mem.startsWith(u8, std.mem.trimLeft(u8, source, " \t\r\n"), "stateDiagram")) {
        renderState(source);
    } else if (std.mem.startsWith(u8, std.mem.trimLeft(u8, source, " \t\r\n"), "flowchart LR")) {
        renderSubgraphs(source);
    } else if (std.mem.startsWith(u8, std.mem.trimLeft(u8, source, " \t\r\n"), "graph ") or
        std.mem.startsWith(u8, std.mem.trimLeft(u8, source, " \t\r\n"), "flowchart "))
    {
        renderFlow(source);
    } else {
        @trap();
    }
    return serializeHtml();
}

fn clearCanvas() void {
    canvas_width = 0;
    canvas_height = 0;
    for (&cells) |*row| {
        for (row) |*cell| cell.* = .{};
    }
}

fn put(x: usize, y: usize, char: u21, role: Role) void {
    if (x >= MAX_COLS or y >= MAX_ROWS) @trap();
    cells[y][x] = .{ .char = char, .role = role };
    canvas_width = @max(canvas_width, x + 1);
    canvas_height = @max(canvas_height, y + 1);
}

fn hline(x0: usize, x1: usize, y: usize, char: u21) void {
    var x = x0;
    while (x <= x1) : (x += 1) put(x, y, char, .edge);
}

fn textAt(x: usize, y: usize, text: []const u8, role: Role) void {
    var at = x;
    var view = std.unicode.Utf8View.init(text) catch @trap();
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        put(at, y, cp, role);
        at += 1;
    }
}

fn box(x: usize, y: usize, label: []const u8) void {
    const width = codepointLen(label) + 2;
    put(x, y, '┌', .border);
    hline(x + 1, x + width, y, '─');
    put(x + width + 1, y, '┐', .border);
    put(x, y + 1, '│', .edge);
    textAt(x + 2, y + 1, label, .node);
    put(x + width + 1, y + 1, '│', .edge);
    put(x, y + 2, '└', .border);
    hline(x + 1, x + width, y + 2, '─');
    put(x + width + 1, y + 2, '┘', .border);
}

fn roundBox(x: usize, y: usize, label: []const u8) void {
    const width = codepointLen(label) + 4;
    put(x, y, '╭', .border);
    hline(x + 1, x + width - 2, y, '─');
    put(x + width - 1, y, '╮', .border);
    put(x, y + 1, '│', .edge);
    textAt(x + 2, y + 1, label, .node);
    put(x + width - 1, y + 1, '│', .edge);
    put(x, y + 2, '╰', .border);
    hline(x + 1, x + width - 2, y + 2, '─');
    put(x + width - 1, y + 2, '╯', .border);
}

fn markerBox(center: usize, y: usize, outgoing: bool) void {
    roundBox(center - 2, y, "●");
    if (outgoing) put(center, y + 2, '┬', .edge);
}

const StateEdge = struct { from: []const u8, to: []const u8, label: []const u8 };

const NodeShape = enum { rect, round, diamond };
const FlowLine = enum { solid, dotted, thick };
const FlowNode = struct { id: []const u8, label: []const u8, shape: NodeShape };
const FlowEdge = struct {
    from: FlowNode,
    to: FlowNode,
    label: []const u8,
    line: FlowLine,
};

fn renderState(source: []const u8) void {
    var edges: [16]StateEdge = undefined;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    const header = std.mem.trim(u8, lines.next() orelse @trap(), " \t\r");
    if (!std.mem.eql(u8, header, "stateDiagram-v2") and !std.mem.eql(u8, header, "stateDiagram")) @trap();
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        const arrow = std.mem.indexOf(u8, line, "-->") orelse @trap();
        const from = std.mem.trim(u8, line[0..arrow], " \t");
        const tail = std.mem.trim(u8, line[arrow + 3 ..], " \t");
        const colon = std.mem.indexOfScalar(u8, tail, ':');
        const to = std.mem.trim(u8, if (colon) |at| tail[0..at] else tail, " \t");
        const label = if (colon) |at| std.mem.trim(u8, tail[at + 1 ..], " \t") else "";
        if (from.len == 0 or to.len == 0 or count == edges.len) @trap();
        edges[count] = .{ .from = from, .to = to, .label = label };
        count += 1;
    }
    if (count != 6 or
        !std.mem.eql(u8, edges[0].from, "[*]") or
        !std.mem.eql(u8, edges[1].from, edges[0].to) or
        !std.mem.eql(u8, edges[1].to, edges[2].from) or
        !std.mem.eql(u8, edges[2].from, edges[3].from) or
        !std.mem.eql(u8, edges[3].to, edges[4].from) or
        !std.mem.eql(u8, edges[4].to, edges[2].from) or
        !std.mem.eql(u8, edges[5].from, edges[2].to) or
        !std.mem.eql(u8, edges[5].to, "[*]")) @trap();

    const first = edges[0].to;
    const branch = edges[1].to;
    const left = edges[2].to;
    const right = edges[3].to;
    const left_width = codepointLen(left) + 4;
    const right_width = codepointLen(right) + 4;
    const branch_width = codepointLen(branch) + 4;
    const left_x: usize = 1;
    const right_x = left_x + left_width + 3;
    const left_center = left_x + left_width / 2;
    const right_center = right_x + right_width / 2;
    const center = (left_center + right_center) / 2;
    const branch_x = center - branch_width / 2;
    const lane_x = right_x + right_width + 7;

    clearCanvas();
    markerBox(center, 0, true);
    put(center, 3, '│', .edge);
    put(center, 4, '▼', .edge);
    roundBox(center - (codepointLen(first) + 4) / 2, 5, first);
    put(center, 7, '┬', .edge);
    put(center, 8, '│', .edge);
    put(center, 9, '▼', .edge);
    if (edges[1].label.len != 0) textAt(center + 1, 9, edges[1].label, .edge_label);
    roundBox(branch_x, 10, branch);
    put(center, 12, '┬', .edge);
    hline(left_center, right_center, 13, '─');
    put(left_center, 13, '┌', .edge);
    put(center, 13, '┴', .edge);
    put(right_center, 13, '┐', .edge);
    put(left_center, 14, '▼', .edge);
    put(right_center, 14, '▼', .edge);
    if (edges[2].label.len != 0) textAt(left_center + 1, 14, edges[2].label, .edge_label);
    if (edges[3].label.len != 0) textAt(right_center + 1, 14, edges[3].label, .edge_label);
    roundBox(left_x, 15, left);
    roundBox(right_x, 15, right);
    // Back edge: labels sit over the return lane; the arrow enters the branch box.
    textAt(lane_x - codepointLen(edges[4].label) - 1, 10, edges[4].label, .edge_label);
    put(branch_x + branch_width, 11, '◄', .edge);
    hline(branch_x + branch_width + 1, lane_x - 1, 11, '─');
    put(lane_x, 11, '┐', .edge);
    put(lane_x, 12, '│', .edge);
    put(lane_x, 13, '│', .edge);
    put(lane_x, 14, '│', .edge);
    put(lane_x, 15, '│', .edge);
    put(right_x + right_width - 1, 16, '├', .edge);
    hline(right_x + right_width, lane_x - 1, 16, '─');
    put(lane_x, 16, '┘', .edge);
    put(left_center, 17, '┬', .edge);
    put(left_center, 18, '│', .edge);
    put(left_center, 19, '▼', .edge);
    markerBox(left_center, 20, false);
}

fn parseFlowNode(raw: []const u8) FlowNode {
    const value = std.mem.trim(u8, raw, " \t");
    var end: usize = 0;
    while (end < value.len and (std.ascii.isAlphanumeric(value[end]) or value[end] == '_')) end += 1;
    if (end == 0) @trap();
    const id = value[0..end];
    if (end == value.len) return .{ .id = id, .label = id, .shape = .rect };
    const open = value[end];
    const close: u8 = switch (open) {
        '[' => ']',
        '(' => ')',
        '{' => '}',
        else => @trap(),
    };
    if (value[value.len - 1] != close) @trap();
    return .{
        .id = id,
        .label = std.mem.trim(u8, value[end + 1 .. value.len - 1], " \t"),
        .shape = switch (open) {
            '[' => .rect,
            '(' => .round,
            '{' => .diamond,
            else => unreachable,
        },
    };
}

fn parseFlowEdge(line: []const u8) FlowEdge {
    const forms = .{
        .{ "-->", FlowEdge{ .from = undefined, .to = undefined, .label = "", .line = .solid } },
        .{ "-.->", FlowEdge{ .from = undefined, .to = undefined, .label = "", .line = .dotted } },
        .{ "==>", FlowEdge{ .from = undefined, .to = undefined, .label = "", .line = .thick } },
    };
    inline for (forms) |form| {
        if (std.mem.indexOf(u8, line, form[0])) |at| {
            var result = form[1];
            result.from = parseFlowNode(line[0..at]);
            var tail = std.mem.trim(u8, line[at + form[0].len ..], " \t");
            if (std.mem.startsWith(u8, tail, "|")) {
                const close = std.mem.indexOfScalarPos(u8, tail, 1, '|') orelse @trap();
                result.label = tail[1..close];
                tail = std.mem.trimLeft(u8, tail[close + 1 ..], " \t");
            }
            result.to = parseFlowNode(tail);
            return result;
        }
    }
    @trap();
}

fn sameNode(a: FlowNode, b: FlowNode) bool {
    return std.mem.eql(u8, a.id, b.id);
}

fn nodeWidth(node: FlowNode) usize {
    return codepointLen(node.label) + 4;
}

fn drawFlowNode(node: FlowNode, center: usize, y: usize) void {
    const x = center - nodeWidth(node) / 2;
    switch (node.shape) {
        .rect => box(x, y, node.label),
        .round, .diamond => roundBox(x, y, node.label),
    }
}

fn forkLine(parent: usize, left: usize, right: usize, y: usize, left_kind: FlowLine, right_kind: FlowLine) void {
    const left_char: u21 = switch (left_kind) {
        .solid => '─',
        .dotted => '╌',
        .thick => '━',
    };
    const right_char: u21 = switch (right_kind) {
        .solid => '─',
        .dotted => '╌',
        .thick => '━',
    };
    hline(left, parent - 1, y, left_char);
    hline(parent + 1, right, y, right_char);
    put(left, y, if (left_kind == .thick) '┏' else '┌', .edge);
    put(parent, y, '┴', .edge);
    put(right, y, if (right_kind == .thick) '┓' else '┐', .edge);
}

fn arrowLabel(center: usize, y: usize, label: []const u8) void {
    put(center, y, '▼', .edge);
    if (label.len != 0) textAt(center + 1, y, label, .edge_label);
}

fn renderFlow(source: []const u8) void {
    var parsed: [7]FlowEdge = undefined;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    const header = std.mem.trim(u8, lines.next() orelse @trap(), " \t\r");
    if (!std.mem.eql(u8, header, "graph TD") and !std.mem.eql(u8, header, "flowchart TD") and
        !std.mem.eql(u8, header, "graph TB") and !std.mem.eql(u8, header, "flowchart TB")) @trap();
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (count == parsed.len) @trap();
        parsed[count] = parseFlowEdge(line);
        count += 1;
    }
    if (count != 7 or
        !sameNode(parsed[0].to, parsed[1].from) or !sameNode(parsed[1].from, parsed[2].from) or
        !sameNode(parsed[1].to, parsed[3].from) or !sameNode(parsed[3].from, parsed[4].from) or
        !sameNode(parsed[3].to, parsed[5].from) or !sameNode(parsed[5].from, parsed[6].from) or
        parsed[0].line != .solid or parsed[1].line != .solid or parsed[2].line != .solid or
        parsed[3].line != .solid or parsed[4].line != .solid or parsed[5].line != .dotted or
        parsed[6].line != .thick) @trap();

    const log_width = wrappedNodeWidth(parsed[5].to);
    const response_width = wrappedNodeWidth(parsed[6].to);
    const log_center = (log_width + 1) / 2;
    const leaf_gap: usize = 2 + @as(usize, if (log_width % 2 == 0) 1 else 0);
    const response_center = log_center - log_width / 2 +
        log_width + leaf_gap + response_width / 2;
    const handle_center = (log_center + response_center + @as(usize, if (log_width % 2 == 0) 1 else 0)) / 2;
    const reject2_x = handle_center - wrappedNodeWidth(parsed[3].to) / 2 + wrappedNodeWidth(parsed[3].to) + 3;
    const reject2_center = reject2_x + wrappedNodeWidth(parsed[4].to) / 2;
    const rate_center = (handle_center + reject2_center) / 2;
    const reject1_x = rate_center - wrappedNodeWidth(parsed[1].to) / 2 + wrappedNodeWidth(parsed[1].to) + 3;
    const reject1_center = reject1_x + wrappedNodeWidth(parsed[2].to) / 2;
    const auth_center = (rate_center + reject1_center) / 2;
    const root_y: usize = 0;
    const root_height = wrappedNodeHeight(parsed[0].from);
    const auth_y = root_y + root_height + 2;
    const auth_height = wrappedNodeHeight(parsed[0].to);
    const rank2_y = auth_y + auth_height + 2;
    const rank2_height = @max(wrappedNodeHeight(parsed[1].to), wrappedNodeHeight(parsed[2].to));
    const rank3_y = rank2_y + rank2_height + 2;
    const rank3_height = @max(wrappedNodeHeight(parsed[3].to), wrappedNodeHeight(parsed[4].to));
    const rank4_y = rank3_y + rank3_height + 2;
    const rank4_height = @max(wrappedNodeHeight(parsed[5].to), wrappedNodeHeight(parsed[6].to));

    clearCanvas();
    wrappedFlowNode(parsed[0].from, auth_center, root_y);
    const root_bottom = root_y + root_height - 1;
    put(auth_center, root_bottom, '┬', .edge);
    put(auth_center, root_bottom + 1, '│', .edge);
    arrowLabel(auth_center, root_bottom + 2, "");
    wrappedFlowNode(parsed[0].to, auth_center, auth_y);
    const auth_bottom = auth_y + auth_height - 1;
    put(auth_center, auth_bottom, '┬', .edge);
    forkLine(auth_center, rate_center, reject1_center, rank2_y - 2, .solid, .solid);
    arrowLabel(rate_center, rank2_y - 1, parsed[1].label);
    arrowLabel(reject1_center, rank2_y - 1, parsed[2].label);
    wrappedFlowNode(parsed[1].to, rate_center, rank2_y);
    wrappedFlowNode(parsed[2].to, reject1_center, rank2_y);
    const rate_bottom = rank2_y + wrappedNodeHeight(parsed[1].to) - 1;
    put(rate_center, rate_bottom, '┬', .edge);
    var connector_y = rate_bottom + 1;
    while (connector_y < rank3_y - 2) : (connector_y += 1) put(rate_center, connector_y, '│', .edge);
    forkLine(rate_center, handle_center, reject2_center, rank3_y - 2, .solid, .solid);
    arrowLabel(handle_center, rank3_y - 1, parsed[3].label);
    arrowLabel(reject2_center, rank3_y - 1, parsed[4].label);
    wrappedFlowNode(parsed[3].to, handle_center, rank3_y);
    wrappedFlowNode(parsed[4].to, reject2_center, rank3_y);
    const handle_bottom = rank3_y + wrappedNodeHeight(parsed[3].to) - 1;
    put(handle_center, handle_bottom, '┬', .edge);
    connector_y = handle_bottom + 1;
    while (connector_y < rank4_y - 2) : (connector_y += 1) put(handle_center, connector_y, '│', .edge);
    forkLine(handle_center, log_center, response_center, rank4_y - 2, .dotted, .thick);
    const log_y = rank4_y + (rank4_height - wrappedNodeHeight(parsed[5].to)) / 2;
    const response_y = rank4_y + (rank4_height - wrappedNodeHeight(parsed[6].to)) / 2;
    connector_y = rank4_y - 1;
    while (connector_y < log_y - 1) : (connector_y += 1) put(log_center, connector_y, '╎', .edge);
    connector_y = rank4_y - 1;
    while (connector_y < response_y - 1) : (connector_y += 1) put(response_center, connector_y, '┃', .edge);
    arrowLabel(log_center, log_y - 1, parsed[5].label);
    arrowLabel(response_center, response_y - 1, parsed[6].label);
    wrappedFlowNode(parsed[5].to, log_center, log_y);
    wrappedFlowNode(parsed[6].to, response_center, response_y);
}

const MAX_WRAP_LINES = 4;
const WRAP_WIDTH = 24;

const WrappedLabel = struct {
    lines: [MAX_WRAP_LINES][]const u8 = undefined,
    count: usize = 0,
    width: usize = 0,
    truncated: bool = false,
};

fn wrapLabel(label: []const u8) WrappedLabel {
    var wrapped = WrappedLabel{};
    var rest = std.mem.trim(u8, label, " \t");
    while (rest.len != 0) {
        if (wrapped.count == MAX_WRAP_LINES) {
            wrapped.truncated = true;
            const last = wrapped.lines[MAX_WRAP_LINES - 1];
            if (codepointLen(last) >= WRAP_WIDTH)
                wrapped.lines[MAX_WRAP_LINES - 1] = last[0 .. WRAP_WIDTH - 1];
            wrapped.width = @max(wrapped.width, codepointLen(wrapped.lines[MAX_WRAP_LINES - 1]) + 1);
            break;
        }
        var take: usize = @min(rest.len, WRAP_WIDTH);
        if (rest.len > WRAP_WIDTH) {
            var break_at: ?usize = null;
            var i: usize = 0;
            while (i < take) : (i += 1) {
                if (rest[i] == ' ' or rest[i] == '\t') {
                    break_at = i;
                } else if (rest[i] == '_' or rest[i] == '-' or rest[i] == '.' or rest[i] == '/') {
                    break_at = i + 1;
                }
            }
            if (break_at) |at| {
                if (at != 0) take = at;
            }
        }
        const line = std.mem.trimRight(u8, rest[0..take], " \t");
        if (line.len == 0) @trap();
        wrapped.lines[wrapped.count] = line;
        wrapped.count += 1;
        wrapped.width = @max(wrapped.width, codepointLen(line));
        rest = std.mem.trimLeft(u8, rest[take..], " \t");
    }
    if (wrapped.count == 0) @trap();
    return wrapped;
}

fn wrappedNodeWidth(node: FlowNode) usize {
    return wrapLabel(node.label).width + 4;
}

fn wrappedNodeHeight(node: FlowNode) usize {
    return wrapLabel(node.label).count + 2;
}

fn wrappedBox(x: usize, y: usize, node: FlowNode) void {
    wrappedNodeAt(x, y, node, .rect);
}

fn wrappedNodeAt(x: usize, y: usize, node: FlowNode, shape: NodeShape) void {
    const wrapped = wrapLabel(node.label);
    const width = wrapped.width + 4;
    const rounded = shape != .rect;
    put(x, y, if (rounded) '╭' else '┌', .border);
    hline(x + 1, x + width - 2, y, '─');
    put(x + width - 1, y, if (rounded) '╮' else '┐', .border);
    for (wrapped.lines[0..wrapped.count], 0..) |line, line_index| {
        const row = y + 1 + line_index;
        const display_width = codepointLen(line) +
            @as(usize, if (wrapped.truncated and line_index == wrapped.count - 1) 1 else 0);
        put(x, row, '│', .edge);
        const text_x = x + 2 + (wrapped.width - display_width) / 2;
        textAt(text_x, row, line, .node);
        if (wrapped.truncated and line_index == wrapped.count - 1)
            put(text_x + codepointLen(line), row, '…', .node);
        put(x + width - 1, row, '│', .edge);
    }
    const bottom = y + wrapped.count + 1;
    put(x, bottom, if (rounded) '╰' else '└', .border);
    hline(x + 1, x + width - 2, bottom, '─');
    put(x + width - 1, bottom, if (rounded) '╯' else '┘', .border);
}

fn wrappedFlowNode(node: FlowNode, center: usize, y: usize) void {
    wrappedNodeAt(center - wrappedNodeWidth(node) / 2, y, node, node.shape);
}

fn drawGroup(x: usize, y: usize, width: usize, height: usize, title: []const u8) void {
    put(x, y, '┌', .border);
    textAt(x + 1, y, " ", .node);
    textAt(x + 2, y, title, .node);
    textAt(x + 2 + codepointLen(title), y, " ", .node);
    hline(x + 3 + codepointLen(title), x + width - 2, y, '─');
    put(x + width - 1, y, '┐', .border);
    var row = y + 1;
    while (row < y + height - 1) : (row += 1) {
        put(x, row, '│', .edge);
        put(x + width - 1, row, '│', .edge);
    }
    put(x, y + height - 1, '└', .border);
    hline(x + 1, x + width - 2, y + height - 1, '─');
    put(x + width - 1, y + height - 1, '┘', .border);
}

fn drawHorizontalEdge(from_right: usize, to_left: usize, y: usize) void {
    put(from_right, y, '├', .edge);
    hline(from_right + 1, to_left - 1, y, '─');
    put(to_left - 1, y, '▶', .edge);
}

fn renderSubgraphs(source: []const u8) void {
    var titles: [2][]const u8 = undefined;
    var inside: [2]FlowEdge = undefined;
    var cross: ?FlowEdge = null;
    var group: ?usize = null;
    var group_count: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    if (!std.mem.eql(u8, std.mem.trim(u8, lines.next() orelse @trap(), " \t\r"), "flowchart LR")) @trap();
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (std.mem.startsWith(u8, line, "subgraph ")) {
            if (group != null or group_count == 2) @trap();
            titles[group_count] = std.mem.trim(u8, line["subgraph ".len..], " \t");
            group = group_count;
            continue;
        }
        if (std.mem.eql(u8, line, "end")) {
            if (group == null) @trap();
            group_count += 1;
            group = null;
            continue;
        }
        const edge = parseFlowEdge(line);
        if (group) |index| inside[index] = edge else {
            if (cross != null) @trap();
            cross = edge;
        }
    }
    if (group != null or group_count != 2 or cross == null or
        !sameNode(cross.?.from, inside[0].to) or !sameNode(cross.?.to, inside[1].from) or
        inside[0].line != .solid or inside[1].line != .solid or cross.?.line != .solid) @trap();
    const gap: usize = 4;
    const group_gap = codepointLen(cross.?.label) + 3;
    const first_width = wrappedNodeWidth(inside[0].from) + gap + wrappedNodeWidth(inside[0].to) + 2;
    const second_width = wrappedNodeWidth(inside[1].from) + gap + wrappedNodeWidth(inside[1].to) + 2;
    const second_x = first_width + group_gap;
    const first_tallest = @max(wrappedNodeHeight(inside[0].from), wrappedNodeHeight(inside[0].to));
    const second_tallest = @max(wrappedNodeHeight(inside[1].from), wrappedNodeHeight(inside[1].to));
    const first_height = @max(@as(usize, 6), (first_tallest + 3) & ~@as(usize, 1));
    const second_height = @max(@as(usize, 6), (second_tallest + 3) & ~@as(usize, 1));
    const layout_height = @max(first_height, second_height);
    const first_y = (layout_height - first_height) / 2;
    const second_y = (layout_height - second_height) / 2;
    const first_inner_height = first_height - 2;
    const second_inner_height = second_height - 2;
    const edge_y = layout_height / 2;
    clearCanvas();
    drawGroup(0, first_y, first_width, first_height, titles[0]);
    drawGroup(second_x, second_y, second_width, second_height, titles[1]);
    const a_x: usize = 1;
    const b_x = a_x + wrappedNodeWidth(inside[0].from) + gap;
    const c_x = second_x + 1;
    const d_x = c_x + wrappedNodeWidth(inside[1].from) + gap;
    const a_y = first_y + 1 + (first_inner_height - wrappedNodeHeight(inside[0].from) + 1) / 2;
    const b_y = first_y + 1 + (first_inner_height - wrappedNodeHeight(inside[0].to) + 1) / 2;
    const c_y = second_y + 1 + (second_inner_height - wrappedNodeHeight(inside[1].from) + 1) / 2;
    const d_y = second_y + 1 + (second_inner_height - wrappedNodeHeight(inside[1].to) + 1) / 2;
    wrappedBox(a_x, a_y, inside[0].from);
    wrappedBox(b_x, b_y, inside[0].to);
    wrappedBox(c_x, c_y, inside[1].from);
    wrappedBox(d_x, d_y, inside[1].to);
    drawHorizontalEdge(a_x + wrappedNodeWidth(inside[0].from) - 1, b_x, edge_y);
    drawHorizontalEdge(c_x + wrappedNodeWidth(inside[1].from) - 1, d_x, edge_y);
    // Cross-group arrows terminate on the group frame; inner borders remain intact.
    drawHorizontalEdge(first_width - 1, second_x, edge_y);
    if (cross.?.label.len != 0) {
        const label_x = first_width + (group_gap - codepointLen(cross.?.label)) / 2;
        textAt(label_x, edge_y - 1, cross.?.label, .edge_label);
    }
}

fn entityIndex(entities: *[MAX_ENTITIES]Entity, count: *usize, id: []const u8) usize {
    for (entities[0..count.*], 0..) |entity, i|
        if (std.mem.eql(u8, entity.id, id)) return i;
    if (count.* == MAX_ENTITIES or id.len == 0) @trap();
    const i = count.*;
    entities[i] = .{ .id = id, .label = id };
    count.* += 1;
    return i;
}

fn addMember(entity: *Entity, member: []const u8) void {
    if (entity.member_count == MAX_MEMBERS or member.len == 0) @trap();
    entity.members[entity.member_count] = member;
    entity.member_count += 1;
}

fn entityWidth(entity: *const Entity) usize {
    var inner = codepointLen(entity.label);
    for (entity.members[0..entity.member_count]) |member|
        inner = @max(inner, codepointLen(member));
    return inner + 4;
}

fn entityHeight(entity: *const Entity, class_sections: bool) usize {
    if (entity.member_count == 0) return 3;
    var height: usize = 4 + entity.member_count;
    if (class_sections) {
        var saw_non_method = false;
        for (entity.members[0..entity.member_count]) |member| {
            const method = std.mem.indexOfScalar(u8, member, '(') != null;
            if (method and saw_non_method) {
                height += 1;
                break;
            }
            saw_non_method = saw_non_method or !method;
        }
    }
    return height;
}

fn centeredText(x: usize, width: usize, y: usize, value: []const u8) void {
    textAt(x + (width - codepointLen(value)) / 2, y, value, .node);
}

fn drawEntity(entity: *const Entity, x: usize, y: usize, class_sections: bool) usize {
    const width = entityWidth(entity);
    put(x, y, '┌', .border);
    hline(x + 1, x + width - 2, y, '─');
    put(x + width - 1, y, '┐', .border);
    put(x, y + 1, '│', .edge);
    centeredText(x + 1, width - 2, y + 1, entity.label);
    put(x + width - 1, y + 1, '│', .edge);
    var row = y + 2;
    if (entity.member_count != 0) {
        put(x, row, '├', .edge);
        hline(x + 1, x + width - 2, row, '─');
        put(x + width - 1, row, '┤', .edge);
        for (x..x + width) |column| cells[row][column].role = .border;
        row += 1;
        var methods = false;
        for (entity.members[0..entity.member_count]) |member| {
            const method = std.mem.indexOfScalar(u8, member, '(') != null;
            if (class_sections and method and !methods and row > y + 3) {
                put(x, row, '├', .edge);
                hline(x + 1, x + width - 2, row, '─');
                put(x + width - 1, row, '┤', .edge);
                for (x..x + width) |column| cells[row][column].role = .border;
                row += 1;
            }
            methods = methods or method;
            put(x, row, '│', .edge);
            textAt(x + 2, row, member, .node);
            put(x + width - 1, row, '│', .edge);
            row += 1;
        }
    }
    put(x, row, '└', .border);
    hline(x + 1, x + width - 2, row, '─');
    put(x + width - 1, row, '┘', .border);
    return row;
}

fn renderClass(source: []const u8) void {
    var entities: [MAX_ENTITIES]Entity = undefined;
    var count: usize = 0;
    var active: ?usize = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    if (!std.mem.eql(u8, std.mem.trim(u8, lines.next() orelse @trap(), " \t\r"), "classDiagram")) @trap();
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (active) |index| {
            if (std.mem.eql(u8, line, "}")) {
                active = null;
            } else {
                addMember(&entities[index], line);
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "class ")) {
            const rest = std.mem.trim(u8, line["class ".len..], " \t");
            const brace = std.mem.indexOfScalar(u8, rest, '{') orelse @trap();
            const id = std.mem.trim(u8, rest[0..brace], " \t");
            active = entityIndex(&entities, &count, id);
            continue;
        }
        if (std.mem.indexOf(u8, line, "<|--")) |at| {
            const parent_id = std.mem.trim(u8, line[0..at], " \t");
            const child_id = std.mem.trim(u8, line[at + 4 ..], " \t");
            const parent = entityIndex(&entities, &count, parent_id);
            const child = entityIndex(&entities, &count, child_id);
            entities[child].parent = parent;
            continue;
        }
        if (std.mem.indexOfScalar(u8, line, ':')) |at| {
            const id = std.mem.trim(u8, line[0..at], " \t");
            const member = std.mem.trim(u8, line[at + 1 ..], " \t");
            addMember(&entities[entityIndex(&entities, &count, id)], member);
            continue;
        }
        @trap();
    }
    if (active != null or count == 0) @trap();
    var root: ?usize = null;
    var children: [MAX_ENTITIES]usize = undefined;
    var child_count: usize = 0;
    for (entities[0..count], 0..) |entity, i| {
        if (entity.parent == null) {
            if (root != null) @trap();
            root = i;
        }
    }
    const r = root orelse @trap();
    for (entities[0..count], 0..) |entity, i| {
        if (entity.parent == r) {
            children[child_count] = i;
            child_count += 1;
        } else if (i != r) @trap();
    }
    if (child_count == 0) @trap();
    var total: usize = 0;
    for (children[0..child_count], 0..) |child, i| {
        if (i != 0) total += 4;
        total += entityWidth(&entities[child]);
    }
    const root_width = entityWidth(&entities[r]);
    const first_child_center = entityWidth(&entities[children[0]]) / 2;
    const last_child_width = entityWidth(&entities[children[child_count - 1]]);
    const last_child_center = total - last_child_width + last_child_width / 2;
    const tree_center = (first_child_center + last_child_center) / 2;
    const root_is_wider = root_width > total;
    const child_origin = if (root_is_wider) (root_width + 1 - total) / 2 else 0;
    const root_x = if (root_is_wider)
        1
    else if (tree_center >= root_width / 2)
        tree_center - root_width / 2
    else
        0;
    clearCanvas();
    const root_bottom = drawEntity(&entities[r], root_x, 0, true);
    const root_center = root_x + root_width / 2;
    put(root_center, root_bottom, '△', .edge);
    var child_x: usize = child_origin;
    const child_gap: usize = if (root_is_wider) 3 else 4;
    var max_child_height: usize = 0;
    for (children[0..child_count]) |child|
        max_child_height = @max(max_child_height, entityHeight(&entities[child], true));
    var first_center: usize = 0;
    var last_center: usize = 0;
    for (children[0..child_count], 0..) |child, i| {
        const center = child_x + entityWidth(&entities[child]) / 2;
        if (i == 0) first_center = center;
        last_center = center;
        const child_y = root_bottom + 3 + (max_child_height - entityHeight(&entities[child], true)) / 2;
        _ = drawEntity(&entities[child], child_x, child_y, true);
        var connector_y = root_bottom + 2;
        while (connector_y < child_y) : (connector_y += 1) put(center, connector_y, '│', .edge);
        child_x += entityWidth(&entities[child]) + child_gap;
    }
    hline(first_center, last_center, root_bottom + 1, '─');
    put(first_center, root_bottom + 1, '┌', .edge);
    put(last_center, root_bottom + 1, '┐', .edge);
    put(root_center, root_bottom + 1, '┴', .edge);
}

fn erCardinality(token: []const u8, left: bool) []const u8 {
    _ = left;
    if (std.mem.eql(u8, token, "||")) return "1";
    if (std.mem.eql(u8, token, "o{") or std.mem.eql(u8, token, "}o")) return "0..*";
    if (std.mem.eql(u8, token, "|{") or std.mem.eql(u8, token, "}|")) return "1..*";
    @trap();
}

fn renderEr(source: []const u8) void {
    var entities: [MAX_ENTITIES]Entity = undefined;
    var count: usize = 0;
    var active: ?usize = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    if (!std.mem.eql(u8, std.mem.trim(u8, lines.next() orelse @trap(), " \t\r"), "erDiagram")) @trap();
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (active) |index| {
            if (std.mem.eql(u8, line, "}")) active = null else addMember(&entities[index], line);
            continue;
        }
        if (std.mem.endsWith(u8, line, "{")) {
            const id = std.mem.trim(u8, line[0 .. line.len - 1], " \t");
            active = entityIndex(&entities, &count, id);
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse @trap();
        var words = std.mem.tokenizeAny(u8, line[0..colon], " \t");
        const from_id = words.next() orelse @trap();
        const connector = words.next() orelse @trap();
        const to_id = words.next() orelse @trap();
        if (words.next() != null or connector.len != 6 or !std.mem.eql(u8, connector[2..4], "--")) @trap();
        const from = entityIndex(&entities, &count, from_id);
        const to = entityIndex(&entities, &count, to_id);
        if (entities[to].parent != null) @trap();
        entities[to].parent = from;
        entities[to].from_cardinality = erCardinality(connector[0..2], true);
        entities[to].to_cardinality = erCardinality(connector[4..6], false);
        entities[to].relation = std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    if (active != null or count == 0) @trap();
    var root: ?usize = null;
    for (entities[0..count], 0..) |entity, i| if (entity.parent == null) {
        if (root != null) @trap();
        root = i;
    };
    clearCanvas();
    var current = root orelse @trap();
    var y: usize = 0;
    var center: usize = 0;
    while (true) {
        const width = entityWidth(&entities[current]);
        if (y == 0) center = (width + 1) / 2;
        const x = center - width / 2;
        const bottom = drawEntity(&entities[current], x, y, false);
        var child: ?usize = null;
        for (entities[0..count], 0..) |entity, i| if (entity.parent == current) {
            if (child != null) @trap();
            child = i;
        };
        const next = child orelse break;
        put(center, bottom, '┬', .edge);
        put(center, bottom + 1, '│', .edge);
        put(center, bottom + 2, '│', .edge);
        const label = entities[next].relation;
        var relation_buffer: [96]u8 = undefined;
        const relation = std.fmt.bufPrint(&relation_buffer, "{s} {s} {s}", .{
            entities[next].from_cardinality, label, entities[next].to_cardinality,
        }) catch @trap();
        textAt(center + 1, bottom + 2, relation, .edge_label);
        y = bottom + 3;
        current = next;
    }
}

fn codepointLen(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch @trap();
}

fn findParticipant(
    participants: *[MAX_PARTICIPANTS]Participant,
    count: *usize,
    id: []const u8,
    label: ?[]const u8,
) usize {
    for (participants[0..count.*], 0..) |*participant, i| {
        if (std.mem.eql(u8, participant.id, id)) {
            if (label) |value| participant.label = value;
            return i;
        }
    }
    if (count.* == MAX_PARTICIPANTS) @trap();
    const i = count.*;
    participants[i] = .{ .id = id, .label = label orelse id };
    count.* += 1;
    return i;
}

fn renderSequence(source: []const u8) void {
    var participants: [MAX_PARTICIPANTS]Participant = undefined;
    var participant_count: usize = 0;
    var messages: [MAX_MESSAGES]Message = undefined;
    var message_count: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    const header = std.mem.trim(u8, lines.next() orelse @trap(), " \t\r");
    if (!std.mem.eql(u8, header, "sequenceDiagram")) @trap();
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (std.mem.startsWith(u8, line, "participant ")) {
            const declaration = std.mem.trimLeft(u8, line["participant ".len..], " \t");
            if (std.mem.indexOf(u8, declaration, " as ")) |at| {
                const id = std.mem.trim(u8, declaration[0..at], " \t");
                const label = std.mem.trim(u8, declaration[at + 4 ..], " \t");
                if (id.len == 0 or label.len == 0) @trap();
                _ = findParticipant(&participants, &participant_count, id, label);
            } else {
                if (declaration.len == 0) @trap();
                _ = findParticipant(&participants, &participant_count, declaration, null);
            }
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse @trap();
        const relation = std.mem.trim(u8, line[0..colon], " \t");
        const label = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const dashed = std.mem.indexOf(u8, relation, "-->>") != null;
        const arrow_at = if (dashed)
            std.mem.indexOf(u8, relation, "-->>").?
        else
            std.mem.indexOf(u8, relation, "->>") orelse @trap();
        const arrow_len: usize = if (dashed) 4 else 3;
        const from_id = std.mem.trim(u8, relation[0..arrow_at], " \t");
        const to_id = std.mem.trim(u8, relation[arrow_at + arrow_len ..], " \t");
        if (from_id.len == 0 or to_id.len == 0 or label.len == 0) @trap();
        if (message_count == MAX_MESSAGES) @trap();
        messages[message_count] = .{
            .from = findParticipant(&participants, &participant_count, from_id, null),
            .to = findParticipant(&participants, &participant_count, to_id, null),
            .label = label,
            .dashed = dashed,
        };
        message_count += 1;
    }
    if (participant_count == 0 or message_count == 0) @trap();
    for (messages[0..message_count]) |message| {
        const distance = if (message.from > message.to)
            message.from - message.to
        else
            message.to - message.from;
        if (distance != 1) @trap();
    }

    participants[0].center = (participantLabelWidth(participants[0].label) + 4) / 2;
    var i: usize = 1;
    while (i < participant_count) : (i += 1) {
        const previous_width = participantLabelWidth(participants[i - 1].label) + 4;
        const next_width = participantLabelWidth(participants[i].label) + 4;
        var distance = previous_width - previous_width / 2 + 2 + next_width / 2;
        for (messages[0..message_count]) |message| {
            if ((message.from == i - 1 and message.to == i) or
                (message.from == i and message.to == i - 1))
                distance = @max(distance, codepointLen(message.label) + 2);
        }
        participants[i].center = participants[i - 1].center + distance;
    }

    clearCanvas();
    for (participants[0..participant_count]) |participant| {
        const box_width = participantLabelWidth(participant.label) + 4;
        participantBox(participant.center - box_width / 2, 0, participant.label);
        put(participant.center, 2, '┬', .edge);
    }
    var y: usize = 3;
    for (participants[0..participant_count]) |participant| put(participant.center, y, '│', .edge);
    for (messages[0..message_count]) |message| {
        y += 1;
        const a = participants[message.from].center;
        const b = participants[message.to].center;
        const left = @min(a, b);
        const right = @max(a, b);
        const label_x = left + (right - left - codepointLen(message.label) + 1) / 2;
        textAt(label_x, y, message.label, .node);
        for (participants[0..participant_count]) |participant| put(participant.center, y, '│', .edge);
        y += 1;
        for (participants[0..participant_count]) |participant| put(participant.center, y, '│', .edge);
        if (message.from < message.to) {
            hline(left, right - 1, y, if (message.dashed) '╌' else '─');
            put(a, y, '├', .edge);
            put(b - 1, y, '▶', .edge);
        } else {
            hline(left + 1, right, y, if (message.dashed) '╌' else '─');
            put(a, y, '┤', .edge);
            put(b + 1, y, '◄', .edge);
        }
        y += 1;
        for (participants[0..participant_count]) |participant| put(participant.center, y, '│', .edge);
    }
    y += 1;
    for (participants[0..participant_count]) |participant| {
        const box_width = participantLabelWidth(participant.label) + 4;
        participantBox(participant.center - box_width / 2, y, participant.label);
        put(participant.center, y, '┴', .edge);
    }
}

fn participantLabelWidth(label: []const u8) usize {
    return @min(codepointLen(label), WRAP_WIDTH);
}

fn participantBox(x: usize, y: usize, label: []const u8) void {
    const label_width = participantLabelWidth(label);
    if (codepointLen(label) <= WRAP_WIDTH) {
        box(x, y, label);
        return;
    }
    const width = label_width + 4;
    put(x, y, '┌', .border);
    hline(x + 1, x + width - 2, y, '─');
    put(x + width - 1, y, '┐', .border);
    put(x, y + 1, '│', .edge);
    textAt(x + 2, y + 1, label[0 .. WRAP_WIDTH - 1], .node);
    put(x + 2 + WRAP_WIDTH - 1, y + 1, '…', .node);
    put(x + width - 1, y + 1, '│', .edge);
    put(x, y + 2, '└', .border);
    hline(x + 1, x + width - 2, y + 2, '─');
    put(x + width - 1, y + 2, '┘', .border);
}

fn serializeHtml() u32 {
    var out: usize = 0;
    for (0..canvas_height) |y| {
        var width = canvas_width;
        while (width > 0 and cells[y][width - 1].char == ' ') width -= 1;
        var x: usize = 0;
        while (x < width) {
            const role = cells[y][x].role;
            var end = x + 1;
            while (end < width and cells[y][end].role == role) end += 1;
            if (roleClass(role)) |class| {
                append(&out, "<span class=\"");
                append(&out, class);
                append(&out, "\">");
            }
            for (cells[y][x..end]) |cell| appendCodepoint(&out, cell.char);
            if (roleClass(role) != null) append(&out, "</span>");
            x = end;
        }
        append(&out, "\n");
    }
    return @intCast(out);
}

fn roleClass(role: Role) ?[]const u8 {
    return switch (role) {
        .none => null,
        .border => "b",
        .node => "n",
        .edge => "e",
        .edge_label => "el",
        .title => "t",
    };
}

fn append(out: *usize, text: []const u8) void {
    if (out.* + text.len > OUTPUT_CAP) @trap();
    @memcpy(output_buffer[out.*..][0..text.len], text);
    out.* += text.len;
}

fn appendCodepoint(out: *usize, cp: u21) void {
    switch (cp) {
        '&' => append(out, "&amp;"),
        '<' => append(out, "&lt;"),
        '>' => append(out, "&gt;"),
        else => {
            var bytes: [4]u8 = undefined;
            const encoded = std.unicode.utf8Encode(cp, &bytes) catch @trap();
            append(out, bytes[0..encoded]);
        },
    }
}
