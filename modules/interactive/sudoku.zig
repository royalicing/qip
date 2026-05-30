const GRID: usize = 9;
const CELLS: usize = GRID * GRID;
const BOX: usize = 3;

const CELL_PX: usize = 56;
const BOARD_PX: usize = GRID * CELL_PX;

const PAD_X: usize = 18;
const PAD_TOP: usize = 18;
const PAD_BOTTOM: usize = 18;

const BOARD_X: usize = PAD_X;
const BOARD_Y: usize = PAD_TOP;

const RENDER_W: usize = PAD_X * 2 + BOARD_PX;
const RENDER_H: usize = PAD_TOP + BOARD_PX + PAD_BOTTOM;
const OUTPUT_BYTES: usize = RENDER_W * RENDER_H * 4;

const BTN_PRIMARY: i32 = 1 << 0;
const BTN_SECONDARY: i32 = 1 << 2;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const FLAG_SHIFT: i32 = 1 << 2;
const FLAG_CTRL: i32 = 1 << 3;
const FLAG_ALT: i32 = 1 << 4;
const FLAG_META: i32 = 1 << 5;

const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;
const XK_RETURN: i32 = 0xFF0D;
const XK_BACKSPACE: i32 = 0xFF08;
const XK_DELETE: i32 = 0xFFFF;

const XK_KP_0: i32 = 0xFFB0;
const XK_KP_1: i32 = 0xFFB1;
const XK_KP_9: i32 = 0xFFB9;

const LARGE_SCALE: usize = 6;
const SMALL_SCALE: usize = 2;

const Color = [4]u8;

const COLOR_BG: Color = .{ 0xE9, 0xEE, 0xF5, 0xFF };
const COLOR_BOARD: Color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
const COLOR_BOX_ODD: Color = .{ 0xF5, 0xF8, 0xFC, 0xFF };
const COLOR_BOX_EVEN: Color = COLOR_BOARD;
const COLOR_GRID_THIN: Color = .{ 0x9A, 0xA9, 0xBC, 0xFF };
const COLOR_GRID_BOLD: Color = .{ 0x2F, 0x3B, 0x4A, 0xFF };
const COLOR_SELECTED: Color = .{ 0xC7, 0xDD, 0xFF, 0xFF };
const COLOR_SELECTED_LOCKED: Color = .{ 0xDE, 0xE5, 0xEE, 0xFF };
const COLOR_GIVEN: Color = .{ 0x16, 0x23, 0x32, 0xFF };
const COLOR_VALUE: Color = .{ 0x1A, 0x5C, 0xB8, 0xFF };
const COLOR_CONFLICT: Color = .{ 0xBE, 0x2B, 0x2B, 0xFF };
const COLOR_CAND: Color = .{ 0x5F, 0x6D, 0x80, 0xFF };

const DIGIT_BITMAPS = [10][7]u8{
    .{ 0b11111, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b11111 },
    .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
    .{ 0b11111, 0b00001, 0b00001, 0b11111, 0b10000, 0b10000, 0b11111 },
    .{ 0b11111, 0b00001, 0b00001, 0b01111, 0b00001, 0b00001, 0b11111 },
    .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b00001, 0b00001, 0b00001 },
    .{ 0b11111, 0b10000, 0b10000, 0b11111, 0b00001, 0b00001, 0b11111 },
    .{ 0b11111, 0b10000, 0b10000, 0b11111, 0b10001, 0b10001, 0b11111 },
    .{ 0b11111, 0b00001, 0b00001, 0b00010, 0b00100, 0b00100, 0b00100 },
    .{ 0b11111, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b11111 },
    .{ 0b11111, 0b10001, 0b10001, 0b11111, 0b00001, 0b00001, 0b11111 },
};

var output_buf: [OUTPUT_BYTES]u8 = undefined;

var givens: [CELLS]u8 = [_]u8{0} ** CELLS;
var values: [CELLS]u8 = [_]u8{0} ** CELLS;
var cands: [CELLS]u16 = [_]u16{0} ** CELLS;

var selected_idx: usize = 0;

var rng_state: u32 = 0xC13FA9A9;
var game_counter: u32 = 0;

var primary_down: bool = false;
var secondary_down: bool = false;
var initialized: bool = false;
var needs_redraw: bool = true;

export fn output_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&output_buf[0])));
}

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_BYTES));
}

export fn render_width_px() i32 {
    return @as(i32, @intCast(RENDER_W));
}

export fn render_height_px() i32 {
    return @as(i32, @intCast(RENDER_H));
}

export fn key_event(x11_key: i32, flags: i32, _: i64) i32 {
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;

    if (!initialized) resetPuzzle();

    const has_shortcut_modifier = (flags & (FLAG_CTRL | FLAG_ALT | FLAG_META)) != 0;

    if (!has_shortcut_modifier and (x11_key == 0x72 or x11_key == 0x52 or x11_key == 0x6E or x11_key == 0x4E or x11_key == XK_RETURN)) {
        resetPuzzle();
        return 1;
    }

    switch (x11_key) {
        XK_LEFT => {
            moveSelection(-1, 0);
            return 1;
        },
        XK_RIGHT => {
            moveSelection(1, 0);
            return 1;
        },
        XK_UP => {
            moveSelection(0, -1);
            return 1;
        },
        XK_DOWN => {
            moveSelection(0, 1);
            return 1;
        },
        XK_BACKSPACE, XK_DELETE, 0x30, XK_KP_0 => {
            if (clearSelectedCell()) return 1;
            return 0;
        },
        else => {},
    }

    const digit = decodeDigitKey(x11_key);
    if (digit != 0) {
        const candidate_mode = (flags & (FLAG_SHIFT | FLAG_CTRL)) != 0;
        if (candidate_mode) {
            if (toggleCandidateSelectedCell(digit)) return 1;
            return 0;
        }
        if (setSelectedCellValue(digit)) return 1;
        return 0;
    }

    return 0;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32, _: i64) i32 {
    if (!initialized) resetPuzzle();

    const is_primary = (button_mask & BTN_PRIMARY) != 0;
    const is_secondary = (button_mask & BTN_SECONDARY) != 0;

    var changed = false;

    if (is_primary and !primary_down) {
        changed = handlePrimaryPress(x_px, y_px) or changed;
    }

    if (is_secondary and !secondary_down) {
        changed = handleSecondaryPress(x_px, y_px) or changed;
    }

    primary_down = is_primary;
    secondary_down = is_secondary;

    return if (changed) 1 else 0;
}

export fn tick(_: i64) i64 {
    if (!initialized) resetPuzzle();
    return 0;
}

export fn render_output() i32 {
    if (!initialized) resetPuzzle();
    drawFrame();
    needs_redraw = false;
    return @as(i32, @intCast(OUTPUT_BYTES));
}

fn resetPuzzle() void {
    initialized = true;
    primary_down = false;
    secondary_down = false;
    selected_idx = 0;
    game_counter +%= 1;
    rng_state +%= 0x9E3779B9 + game_counter *% 0x85EBCA6B;

    generatePuzzle();
    needs_redraw = true;
}

fn generatePuzzle() void {
    var solved: [CELLS]u8 = [_]u8{0} ** CELLS;
    buildSolvedGrid(&solved);

    values = solved;
    cands = [_]u16{0} ** CELLS;

    var indices: [CELLS]u8 = undefined;
    var i: usize = 0;
    while (i < CELLS) : (i += 1) {
        indices[i] = @as(u8, @intCast(i));
    }
    shuffleU8(&indices);

    const clue_target: usize = 30 + @as(usize, @intCast(rngNext() % 9)); // 30..38 clues
    var clues_remaining: usize = CELLS;

    i = 0;
    while (i < CELLS and clues_remaining > clue_target) : (i += 1) {
        const idx: usize = @intCast(indices[i]);
        const prev = values[idx];
        values[idx] = 0;

        // Keep this removal only when the puzzle still has exactly one solution.
        if (solutionCountUpTo(values, 2) != 1) {
            values[idx] = prev;
        } else {
            clues_remaining -= 1;
        }
    }

    givens = values;
}

fn buildSolvedGrid(out: *[CELLS]u8) void {
    var digit_map: [9]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    shuffleU8(&digit_map);

    var band_order: [3]u8 = .{ 0, 1, 2 };
    var stack_order: [3]u8 = .{ 0, 1, 2 };
    shuffleU8(&band_order);
    shuffleU8(&stack_order);

    var row_order: [9]u8 = undefined;
    var col_order: [9]u8 = undefined;

    var b: usize = 0;
    while (b < 3) : (b += 1) {
        var rows_local: [3]u8 = .{ 0, 1, 2 };
        var cols_local: [3]u8 = .{ 0, 1, 2 };
        shuffleU8(&rows_local);
        shuffleU8(&cols_local);

        var k: usize = 0;
        while (k < 3) : (k += 1) {
            row_order[b * 3 + k] = band_order[b] * 3 + rows_local[k];
            col_order[b * 3 + k] = stack_order[b] * 3 + cols_local[k];
        }
    }

    var r: usize = 0;
    while (r < GRID) : (r += 1) {
        var c: usize = 0;
        while (c < GRID) : (c += 1) {
            const rr = row_order[r];
            const cc = col_order[c];
            const idx = (@as(usize, rr) * 3 + @divFloor(@as(usize, rr), 3) + @as(usize, cc)) % 9;
            out[r * GRID + c] = digit_map[idx];
        }
    }
}

fn decodeDigitKey(key: i32) u8 {
    if (key >= 0x31 and key <= 0x39) {
        return @as(u8, @intCast(key - 0x30));
    }
    if (key >= XK_KP_1 and key <= XK_KP_9) {
        return @as(u8, @intCast(key - XK_KP_0));
    }
    return 0;
}

fn moveSelection(dx: i32, dy: i32) void {
    const x0: i32 = @intCast(selected_idx % GRID);
    const y0: i32 = @intCast(selected_idx / GRID);

    var x = x0 + dx;
    var y = y0 + dy;

    if (x < 0) x = 0;
    if (x >= GRID) x = GRID - 1;
    if (y < 0) y = 0;
    if (y >= GRID) y = GRID - 1;

    const xu: usize = @intCast(x);
    const yu: usize = @intCast(y);
    const next_idx: usize = yu * GRID + xu;
    if (next_idx != selected_idx) {
        selected_idx = next_idx;
        needs_redraw = true;
    }
}

fn clearSelectedCell() bool {
    if (givens[selected_idx] != 0) return false;
    const had_value = values[selected_idx] != 0;
    const had_cands = cands[selected_idx] != 0;
    values[selected_idx] = 0;
    cands[selected_idx] = 0;
    if (had_value or had_cands) {
        needs_redraw = true;
        return true;
    }
    return false;
}

fn setSelectedCellValue(digit: u8) bool {
    if (digit < 1 or digit > 9) return false;
    if (givens[selected_idx] != 0) return false;

    if (values[selected_idx] == digit and cands[selected_idx] == 0) return false;

    values[selected_idx] = digit;
    cands[selected_idx] = 0;
    needs_redraw = true;
    return true;
}

fn toggleCandidateSelectedCell(digit: u8) bool {
    if (digit < 1 or digit > 9) return false;
    if (givens[selected_idx] != 0) return false;

    values[selected_idx] = 0;

    const bit: u16 = @as(u16, 1) << @as(u4, @intCast(digit - 1));
    cands[selected_idx] ^= bit;
    needs_redraw = true;
    return true;
}

fn handlePrimaryPress(x_px: i32, y_px: i32) bool {
    const maybe_hit = locateCell(x_px, y_px);
    if (maybe_hit == null) return false;

    const hit = maybe_hit.?;
    const idx = hit.idx;

    if (idx != selected_idx) {
        selected_idx = idx;
        needs_redraw = true;
        return true;
    }

    if (givens[idx] != 0) return false;
    if (values[idx] != 0) return false;

    const maybe_digit = candidateAtLocalPoint(hit.local_x, hit.local_y);
    if (maybe_digit == 0) return false;

    return toggleCandidateAtCell(idx, maybe_digit);
}

fn handleSecondaryPress(x_px: i32, y_px: i32) bool {
    const maybe_hit = locateCell(x_px, y_px);
    if (maybe_hit == null) return false;

    const hit = maybe_hit.?;
    const idx = hit.idx;

    if (givens[idx] != 0) {
        if (idx != selected_idx) {
            selected_idx = idx;
            needs_redraw = true;
            return true;
        }
        return false;
    }

    selected_idx = idx;

    const maybe_digit = candidateAtLocalPoint(hit.local_x, hit.local_y);
    if (maybe_digit == 0) {
        needs_redraw = true;
        return true;
    }

    return toggleCandidateAtCell(idx, maybe_digit);
}

fn toggleCandidateAtCell(idx: usize, digit: u8) bool {
    if (digit < 1 or digit > 9) return false;
    if (givens[idx] != 0) return false;

    values[idx] = 0;
    const bit: u16 = @as(u16, 1) << @as(u4, @intCast(digit - 1));
    cands[idx] ^= bit;
    needs_redraw = true;
    return true;
}

const CellHit = struct {
    idx: usize,
    local_x: usize,
    local_y: usize,
};

fn locateCell(x_px: i32, y_px: i32) ?CellHit {
    const bx: i32 = @intCast(BOARD_X);
    const by: i32 = @intCast(BOARD_Y);
    const board_px_i32: i32 = @intCast(BOARD_PX);

    if (x_px < bx or y_px < by) return null;
    if (x_px >= bx + board_px_i32 or y_px >= by + board_px_i32) return null;

    const lx_i32 = x_px - bx;
    const ly_i32 = y_px - by;

    const lx: usize = @intCast(lx_i32);
    const ly: usize = @intCast(ly_i32);

    const cx = lx / CELL_PX;
    const cy = ly / CELL_PX;

    return CellHit{
        .idx = cy * GRID + cx,
        .local_x = lx % CELL_PX,
        .local_y = ly % CELL_PX,
    };
}

fn candidateAtLocalPoint(local_x: usize, local_y: usize) u8 {
    // Map click position proportionally across the full cell instead of
    // using CELL_PX/3 buckets. This avoids rounding drift when CELL_PX
    // is not divisible by 3 and keeps all 9 candidate hit targets stable.
    const sx = @min((local_x * 3) / CELL_PX, 2);
    const sy = @min((local_y * 3) / CELL_PX, 2);

    return @as(u8, @intCast(sy * 3 + sx + 1));
}

fn solutionCountUpTo(puzzle: [CELLS]u8, limit: u8) u8 {
    var grid = puzzle;
    var count: u8 = 0;
    solveCountRecursive(&grid, limit, &count);
    return count;
}

fn solveCountRecursive(grid: *[CELLS]u8, limit: u8, count: *u8) void {
    if (count.* >= limit) return;

    var best_idx: usize = 0;
    var best_mask: u16 = 0;
    var best_count: u8 = 10;
    var found_empty = false;

    var idx: usize = 0;
    while (idx < CELLS) : (idx += 1) {
        if (grid.*[idx] != 0) continue;
        found_empty = true;
        const mask = candidateMask(grid.*, idx);
        const n: u8 = @intCast(@popCount(mask));
        if (n == 0) return; // dead end
        if (n < best_count) {
            best_count = n;
            best_idx = idx;
            best_mask = mask;
            if (n == 1) break;
        }
    }

    if (!found_empty) {
        count.* += 1;
        return;
    }

    var mask = best_mask;
    while (mask != 0 and count.* < limit) {
        const bit: u16 = mask & (~mask +% 1);
        mask ^= bit;

        const digit_idx: u4 = @intCast(@ctz(bit));
        const digit: u8 = @as(u8, digit_idx) + 1;

        grid.*[best_idx] = digit;
        solveCountRecursive(grid, limit, count);
        grid.*[best_idx] = 0;
    }
}

fn candidateMask(grid: [CELLS]u8, idx: usize) u16 {
    if (grid[idx] != 0) return 0;

    const row = idx / GRID;
    const col = idx % GRID;
    var used: u16 = 0;

    var c: usize = 0;
    while (c < GRID) : (c += 1) {
        const v = grid[row * GRID + c];
        if (v != 0) {
            used |= @as(u16, 1) << @as(u4, @intCast(v - 1));
        }
    }

    var r: usize = 0;
    while (r < GRID) : (r += 1) {
        const v = grid[r * GRID + col];
        if (v != 0) {
            used |= @as(u16, 1) << @as(u4, @intCast(v - 1));
        }
    }

    const box_row = (row / BOX) * BOX;
    const box_col = (col / BOX) * BOX;
    r = 0;
    while (r < BOX) : (r += 1) {
        c = 0;
        while (c < BOX) : (c += 1) {
            const v = grid[(box_row + r) * GRID + (box_col + c)];
            if (v != 0) {
                used |= @as(u16, 1) << @as(u4, @intCast(v - 1));
            }
        }
    }

    return @as(u16, 0x01FF) & ~used;
}

fn drawFrame() void {
    fillRect(0, 0, RENDER_W, RENDER_H, COLOR_BG);
    drawBoardBackground();
    drawSelection();
    drawGrid();
    drawValuesAndCandidates();
}

fn drawBoardBackground() void {
    fillRect(BOARD_X, BOARD_Y, BOARD_PX, BOARD_PX, COLOR_BOARD);

    var by: usize = 0;
    while (by < BOX) : (by += 1) {
        var bx: usize = 0;
        while (bx < BOX) : (bx += 1) {
            const color = if (((bx + by) & 1) == 0) COLOR_BOX_EVEN else COLOR_BOX_ODD;
            fillRect(
                BOARD_X + bx * CELL_PX * BOX,
                BOARD_Y + by * CELL_PX * BOX,
                CELL_PX * BOX,
                CELL_PX * BOX,
                color,
            );
        }
    }
}

fn drawSelection() void {
    const sx = selected_idx % GRID;
    const sy = selected_idx / GRID;
    const px = BOARD_X + sx * CELL_PX;
    const py = BOARD_Y + sy * CELL_PX;
    const color = if (givens[selected_idx] == 0) COLOR_SELECTED else COLOR_SELECTED_LOCKED;
    fillRect(px + 1, py + 1, CELL_PX - 2, CELL_PX - 2, color);
}

fn drawGrid() void {
    var i: usize = 0;
    while (i <= GRID) : (i += 1) {
        const is_bold = (i % BOX) == 0;
        const color = if (is_bold) COLOR_GRID_BOLD else COLOR_GRID_THIN;

        const x = BOARD_X + i * CELL_PX;
        const y = BOARD_Y + i * CELL_PX;

        const thickness: usize = if (is_bold) 2 else 1;
        fillRect(x, BOARD_Y, thickness, BOARD_PX + 1, color);
        fillRect(BOARD_X, y, BOARD_PX + 1, thickness, color);
    }
}

fn drawValuesAndCandidates() void {
    var idx: usize = 0;
    while (idx < CELLS) : (idx += 1) {
        const v = values[idx];
        const x = idx % GRID;
        const y = idx / GRID;
        const px = BOARD_X + x * CELL_PX;
        const py = BOARD_Y + y * CELL_PX;

        if (v != 0) {
            const is_given = givens[idx] != 0;
            const color = if (isConflictAt(idx)) COLOR_CONFLICT else if (is_given) COLOR_GIVEN else COLOR_VALUE;
            drawLargeDigit(v, px, py, color);
        } else {
            drawCandidateDigits(cands[idx], px, py);
        }
    }
}

fn drawLargeDigit(digit: u8, cell_x: usize, cell_y: usize, color: Color) void {
    const gw = 5 * LARGE_SCALE;
    const gh = 7 * LARGE_SCALE;
    const x = cell_x + (CELL_PX - gw) / 2;
    const y = cell_y + (CELL_PX - gh) / 2;
    drawDigitGlyph(digit, x, y, LARGE_SCALE, color);
}

fn drawCandidateDigits(mask: u16, cell_x: usize, cell_y: usize) void {
    if (mask == 0) return;

    const gw = 5 * SMALL_SCALE;
    const gh = 7 * SMALL_SCALE;
    const sub_w = CELL_PX / 3;
    const sub_h = CELL_PX / 3;

    var d: u8 = 1;
    while (d <= 9) : (d += 1) {
        const bit: u16 = @as(u16, 1) << @as(u4, @intCast(d - 1));
        if ((mask & bit) == 0) continue;

        const pos: usize = d - 1;
        const sx = pos % 3;
        const sy = pos / 3;

        const x = cell_x + sx * sub_w + (sub_w - gw) / 2;
        const y = cell_y + sy * sub_h + (sub_h - gh) / 2;

        drawDigitGlyph(d, x, y, SMALL_SCALE, COLOR_CAND);
    }
}

fn drawDigitGlyph(digit: u8, x0: usize, y0: usize, scale: usize, color: Color) void {
    if (digit < 1 or digit > 9) return;

    const glyph = DIGIT_BITMAPS[digit];
    var row: usize = 0;
    while (row < 7) : (row += 1) {
        var col: usize = 0;
        while (col < 5) : (col += 1) {
            const bit = 4 - col;
            if (((glyph[row] >> @as(u3, @intCast(bit))) & 1) == 0) continue;
            fillRect(x0 + col * scale, y0 + row * scale, scale, scale, color);
        }
    }
}

fn isConflictAt(idx: usize) bool {
    const v = values[idx];
    if (v == 0) return false;

    const x = idx % GRID;
    const y = idx / GRID;

    var c: usize = 0;
    while (c < GRID) : (c += 1) {
        if (c == x) continue;
        if (values[y * GRID + c] == v) return true;
    }

    var r: usize = 0;
    while (r < GRID) : (r += 1) {
        if (r == y) continue;
        if (values[r * GRID + x] == v) return true;
    }

    const box_x = (x / BOX) * BOX;
    const box_y = (y / BOX) * BOX;

    r = 0;
    while (r < BOX) : (r += 1) {
        c = 0;
        while (c < BOX) : (c += 1) {
            const xx = box_x + c;
            const yy = box_y + r;
            const peer_idx = yy * GRID + xx;
            if (peer_idx == idx) continue;
            if (values[peer_idx] == v) return true;
        }
    }

    return false;
}

fn setPixel(x: usize, y: usize, color: Color) void {
    if (x >= RENDER_W or y >= RENDER_H) return;
    const off = (y * RENDER_W + x) * 4;
    output_buf[off + 0] = color[0];
    output_buf[off + 1] = color[1];
    output_buf[off + 2] = color[2];
    output_buf[off + 3] = color[3];
}

fn fillRect(x: usize, y: usize, w: usize, h: usize, color: Color) void {
    if (w == 0 or h == 0) return;
    const x1 = @min(x + w, RENDER_W);
    const y1 = @min(y + h, RENDER_H);

    var yy = y;
    while (yy < y1) : (yy += 1) {
        var xx = x;
        while (xx < x1) : (xx += 1) {
            setPixel(xx, yy, color);
        }
    }
}

fn rngNext() u32 {
    var x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

fn shuffleU8(arr: anytype) void {
    const T = @TypeOf(arr.*);
    const info = @typeInfo(T);
    comptime {
        if (info != .array or info.array.child != u8) {
            @compileError("shuffleU8 expects *[N]u8");
        }
    }

    const len = info.array.len;
    if (len <= 1) return;

    var i: usize = len - 1;
    while (i > 0) : (i -= 1) {
        const j = @as(usize, @intCast(rngNext() % @as(u32, @intCast(i + 1))));
        const tmp = arr.*[i];
        arr.*[i] = arr.*[j];
        arr.*[j] = tmp;
    }
}
