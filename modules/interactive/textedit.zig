const std = @import("std");

const RENDER_W: usize = 320;
const RENDER_H: usize = 220;
const OUTPUT_BYTES: usize = RENDER_W * RENDER_H * 4;

const FLAG_KEY_DOWN: i32 = 1 << 0;
const FLAG_SHIFT: i32 = 1 << 2;
const FLAG_CTRL: i32 = 1 << 3;
const FLAG_ALT: i32 = 1 << 4;
const FLAG_META: i32 = 1 << 5;

const BTN_PRIMARY: i32 = 1 << 0;
const BTN_SECONDARY: i32 = 1 << 2;

const XK_LEFT: i32 = 0xFF51;
const XK_UP: i32 = 0xFF52;
const XK_RIGHT: i32 = 0xFF53;
const XK_DOWN: i32 = 0xFF54;
const XK_HOME: i32 = 0xFF50;
const XK_END: i32 = 0xFF57;
const XK_PAGE_UP: i32 = 0xFF55;
const XK_PAGE_DOWN: i32 = 0xFF56;
const XK_RETURN: i32 = 0xFF0D;
const XK_BACKSPACE: i32 = 0xFF08;
const XK_DELETE: i32 = 0xFFFF;
const XK_TAB: i32 = 0xFF09;

const DOC_CAP: usize = 8192;
const CLIP_CAP: usize = 2048;

const WINDOW_X: i32 = 10;
const WINDOW_Y: i32 = 10;
const WINDOW_W: i32 = 300;
const WINDOW_H: i32 = 200;
const TITLE_H: i32 = 18;
const MENU_H: i32 = 14;

const TEXT_X: i32 = WINDOW_X + 8;
const TEXT_Y: i32 = WINDOW_Y + TITLE_H + MENU_H + 6;
const TEXT_W: i32 = WINDOW_W - 16;
const TEXT_H: i32 = WINDOW_H - TITLE_H - MENU_H - 14;
const CHAR_W: i32 = 7;
const LINE_H: i32 = 10;
const VIEW_COLS: i32 = @divTrunc(TEXT_W, CHAR_W);
const VIEW_ROWS: i32 = @divTrunc(TEXT_H, LINE_H);

const Color = [4]u8;
const C_DESKTOP: Color = .{ 0x9F, 0xB6, 0xD2, 0xFF };
const C_WIN: Color = .{ 0xF4, 0xF4, 0xF4, 0xFF };
const C_WIN_DARK: Color = .{ 0x68, 0x68, 0x68, 0xFF };
const C_TITLE_TOP: Color = .{ 0xD8, 0xD8, 0xD8, 0xFF };
const C_TITLE_BOTTOM: Color = .{ 0xB0, 0xB0, 0xB0, 0xFF };
const C_TEXT_BG: Color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
const C_TEXT: Color = .{ 0x11, 0x11, 0x11, 0xFF };
const C_DIM: Color = .{ 0x55, 0x55, 0x55, 0xFF };
const C_SEL: Color = .{ 0x1F, 0x62, 0xD4, 0xFF };
const C_SEL_TEXT: Color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
const C_CARET: Color = .{ 0x10, 0x10, 0x10, 0xFF };

const Rect = struct { x: i32, y: i32, w: i32, h: i32 };
const Range = struct { start: usize, end: usize };

var output_buf: [OUTPUT_BYTES]u8 = undefined;

var doc: [DOC_CAP]u8 = undefined;
var doc_len: usize = 0;

var undo_doc: [DOC_CAP]u8 = undefined;
var undo_len: usize = 0;
var undo_caret: usize = 0;
var undo_anchor: usize = 0;
var has_undo: bool = false;

var clipboard: [CLIP_CAP]u8 = undefined;
var clipboard_len: usize = 0;

var caret: usize = 0;
var anchor: usize = 0;

var scroll_line: i32 = 0;
var scroll_col: i32 = 0;
var preferred_col: i32 = -1;

var pointer_x: i32 = -1000;
var pointer_y: i32 = -1000;
var primary_down: bool = false;
var secondary_down: bool = false;
var mouse_selecting: bool = false;

var blink_counter: i32 = 0;
var blink_on: bool = true;
var needs_redraw: bool = true;
var initialized: bool = false;

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

export fn key_event(x11_key: i32, flags: i32, _: i32) i32 {
    ensureInit();
    if ((flags & FLAG_KEY_DOWN) == 0) return 0;

    const extend = (flags & FLAG_SHIFT) != 0;
    const shortcut_mod = (flags & (FLAG_CTRL | FLAG_META)) != 0;
    const alt = (flags & FLAG_ALT) != 0;
    if (alt) return 0;

    if (shortcut_mod and handleShortcut(x11_key)) {
        touchAfterEdit();
        return 1;
    }

    if (handleNavKey(x11_key, extend)) {
        touchAfterNav();
        return 1;
    }

    if (handleEditKey(x11_key)) {
        touchAfterEdit();
        return 1;
    }

    if (isPrintable(x11_key) and !shortcut_mod) {
        const ch: u8 = @as(u8, @intCast(x11_key));
        if (insertSlice(&[_]u8{ch})) touchAfterEdit();
        return 1;
    }

    return 0;
}

export fn pointer_event(button_mask: i32, x_px: i32, y_px: i32, _: i32) i32 {
    ensureInit();
    pointer_x = x_px;
    pointer_y = y_px;
    const primary = (button_mask & BTN_PRIMARY) != 0;
    const secondary = (button_mask & BTN_SECONDARY) != 0;

    if (secondary and !secondary_down) {
        // Simple context behavior: select word-ish token by line click.
        const idx = textIndexAtPoint(x_px, y_px);
        caret = idx;
        anchor = idx;
        preferred_col = -1;
        mouse_selecting = false;
        touchAfterNav();
    }

    if (primary and !primary_down) {
        const idx = textIndexAtPoint(x_px, y_px);
        caret = idx;
        anchor = idx;
        preferred_col = -1;
        mouse_selecting = pointInRect(x_px, y_px, .{ .x = TEXT_X, .y = TEXT_Y, .w = TEXT_W, .h = TEXT_H });
        touchAfterNav();
    } else if (primary and primary_down and mouse_selecting) {
        const idx = textIndexAtPoint(x_px, y_px);
        caret = idx;
        ensureCaretVisible();
        touchAfterNav();
    } else if (!primary and primary_down) {
        mouse_selecting = false;
        touchAfterNav();
    }

    primary_down = primary;
    secondary_down = secondary;
    return if (needs_redraw) 1 else 0;
}

export fn tick(_: i32) i32 {
    ensureInit();
    blink_counter = @mod(blink_counter + 1, 120);
    const next = blink_counter < 60;
    if (next != blink_on) {
        blink_on = next;
        needs_redraw = true;
    }
    return if (needs_redraw) 1 else 0;
}

export fn render_output() i32 {
    ensureInit();
    drawFrame();
    needs_redraw = false;
    return @as(i32, @intCast(OUTPUT_BYTES));
}

fn ensureInit() void {
    if (initialized) return;
    initialized = true;
    resetState();
}

fn resetState() void {
    doc_len = 0;
    clipboard_len = 0;
    has_undo = false;
    caret = 0;
    anchor = 0;
    scroll_line = 0;
    scroll_col = 0;
    preferred_col = -1;
    pointer_x = -1000;
    pointer_y = -1000;
    primary_down = false;
    secondary_down = false;
    mouse_selecting = false;
    blink_counter = 0;
    blink_on = true;

    _ = insertSliceRaw("Untitled.txt\n\nThis is a plain text document.\nUse keyboard and mouse selection.\n\nShortcuts:\n- Ctrl/Cmd+A Select All\n- Ctrl/Cmd+C Copy\n- Ctrl/Cmd+X Cut\n- Ctrl/Cmd+V Paste\n- Ctrl/Cmd+Z Undo\n");
    caret = doc_len;
    anchor = caret;
    ensureCaretVisible();
    needs_redraw = true;
}

fn touchAfterEdit() void {
    preferred_col = -1;
    ensureCaretVisible();
    blink_counter = 0;
    blink_on = true;
    needs_redraw = true;
}

fn touchAfterNav() void {
    ensureCaretVisible();
    blink_counter = 0;
    blink_on = true;
    needs_redraw = true;
}

fn handleShortcut(key: i32) bool {
    switch (key) {
        'a', 'A' => {
            anchor = 0;
            caret = doc_len;
            return true;
        },
        'c', 'C' => {
            copySelectionToClipboard();
            return true;
        },
        'x', 'X' => {
            if (!hasSelection()) return true;
            pushUndo();
            copySelectionToClipboard();
            _ = deleteSelection();
            return true;
        },
        'v', 'V' => {
            if (clipboard_len == 0) return true;
            pushUndo();
            _ = replaceSelectionWith(clipboard[0..clipboard_len]);
            return true;
        },
        'z', 'Z' => {
            undo();
            return true;
        },
        else => return false,
    }
}

fn handleNavKey(key: i32, extend: bool) bool {
    switch (key) {
        XK_LEFT => {
            moveLeft(extend);
            preferred_col = -1;
            return true;
        },
        XK_RIGHT => {
            moveRight(extend);
            preferred_col = -1;
            return true;
        },
        XK_UP => {
            moveVertical(-1, extend);
            return true;
        },
        XK_DOWN => {
            moveVertical(1, extend);
            return true;
        },
        XK_HOME => {
            moveHome(extend);
            preferred_col = -1;
            return true;
        },
        XK_END => {
            moveEnd(extend);
            preferred_col = -1;
            return true;
        },
        XK_PAGE_UP => {
            moveVertical(-VIEW_ROWS, extend);
            return true;
        },
        XK_PAGE_DOWN => {
            moveVertical(VIEW_ROWS, extend);
            return true;
        },
        else => return false,
    }
}

fn handleEditKey(key: i32) bool {
    switch (key) {
        XK_BACKSPACE => {
            pushUndo();
            return backspace();
        },
        XK_DELETE => {
            pushUndo();
            return deleteForward();
        },
        XK_RETURN => {
            pushUndo();
            return insertSlice(&[_]u8{'\n'});
        },
        XK_TAB => {
            pushUndo();
            return insertSlice("    ");
        },
        else => return false,
    }
}

fn isPrintable(k: i32) bool {
    return k >= 32 and k <= 126;
}

fn moveLeft(extend: bool) void {
    if (!extend and hasSelection()) {
        caret = selectionRange().start;
        anchor = caret;
        return;
    }
    if (caret > 0) caret -= 1;
    if (!extend) anchor = caret;
}

fn moveRight(extend: bool) void {
    if (!extend and hasSelection()) {
        caret = selectionRange().end;
        anchor = caret;
        return;
    }
    if (caret < doc_len) caret += 1;
    if (!extend) anchor = caret;
}

fn moveHome(extend: bool) void {
    caret = lineStartAt(caret);
    if (!extend) anchor = caret;
}

fn moveEnd(extend: bool) void {
    caret = lineEndAt(caret);
    if (!extend) anchor = caret;
}

fn moveVertical(delta_lines: i32, extend: bool) void {
    const line = lineNumberAt(caret);
    const col = colAt(caret);
    if (preferred_col < 0) preferred_col = col;
    const target_line = @max(0, line + delta_lines);
    caret = indexAtLineCol(target_line, preferred_col);
    if (!extend) anchor = caret;
}

fn hasSelection() bool {
    return caret != anchor;
}

fn selectionRange() Range {
    if (caret <= anchor) return .{ .start = caret, .end = anchor };
    return .{ .start = anchor, .end = caret };
}

fn copySelectionToClipboard() void {
    if (!hasSelection()) {
        clipboard_len = 0;
        return;
    }
    const sel = selectionRange();
    const count = @min(CLIP_CAP, sel.end - sel.start);
    var i: usize = 0;
    while (i < count) : (i += 1) clipboard[i] = doc[sel.start + i];
    clipboard_len = count;
}

fn replaceSelectionWith(text: []const u8) bool {
    _ = deleteSelection();
    return insertSlice(text);
}

fn deleteSelection() bool {
    if (!hasSelection()) return false;
    const sel = selectionRange();
    const remove_count = sel.end - sel.start;
    if (remove_count == 0) return false;
    var i = sel.start;
    while (i + remove_count < doc_len) : (i += 1) {
        doc[i] = doc[i + remove_count];
    }
    doc_len -= remove_count;
    caret = sel.start;
    anchor = caret;
    return true;
}

fn insertSlice(text: []const u8) bool {
    const to_insert = @min(text.len, DOC_CAP - doc_len + (if (hasSelection()) selectionRange().end - selectionRange().start else 0));
    if (to_insert == 0) return false;
    _ = deleteSelection();
    if (doc_len + to_insert > DOC_CAP) return false;

    var i: usize = doc_len;
    while (i > caret) : (i -= 1) {
        doc[i + to_insert - 1] = doc[i - 1];
    }
    var j: usize = 0;
    while (j < to_insert) : (j += 1) doc[caret + j] = text[j];
    doc_len += to_insert;
    caret += to_insert;
    anchor = caret;
    return true;
}

fn insertSliceRaw(text: []const u8) bool {
    if (text.len > DOC_CAP - doc_len) return false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        doc[doc_len + i] = text[i];
    }
    doc_len += text.len;
    return true;
}

fn backspace() bool {
    if (deleteSelection()) return true;
    if (caret == 0) return false;
    var i = caret - 1;
    while (i + 1 < doc_len) : (i += 1) {
        doc[i] = doc[i + 1];
    }
    doc_len -= 1;
    caret -= 1;
    anchor = caret;
    return true;
}

fn deleteForward() bool {
    if (deleteSelection()) return true;
    if (caret >= doc_len) return false;
    var i = caret;
    while (i + 1 < doc_len) : (i += 1) {
        doc[i] = doc[i + 1];
    }
    doc_len -= 1;
    anchor = caret;
    return true;
}

fn pushUndo() void {
    if (has_undo and undo_len == doc_len and undo_caret == caret and undo_anchor == anchor) return;
    var i: usize = 0;
    while (i < doc_len) : (i += 1) undo_doc[i] = doc[i];
    undo_len = doc_len;
    undo_caret = caret;
    undo_anchor = anchor;
    has_undo = true;
}

fn undo() void {
    if (!has_undo) return;
    var i: usize = 0;
    while (i < undo_len) : (i += 1) doc[i] = undo_doc[i];
    doc_len = undo_len;
    caret = @min(undo_caret, doc_len);
    anchor = @min(undo_anchor, doc_len);
    has_undo = false;
}

fn lineStartAt(idx: usize) usize {
    var i = @min(idx, doc_len);
    while (i > 0 and doc[i - 1] != '\n') : (i -= 1) {}
    return i;
}

fn lineEndAt(idx: usize) usize {
    var i = @min(idx, doc_len);
    while (i < doc_len and doc[i] != '\n') : (i += 1) {}
    return i;
}

fn lineNumberAt(idx: usize) i32 {
    const end = @min(idx, doc_len);
    var i: usize = 0;
    var line: i32 = 0;
    while (i < end) : (i += 1) {
        if (doc[i] == '\n') line += 1;
    }
    return line;
}

fn colAt(idx: usize) i32 {
    return @as(i32, @intCast(@min(idx, doc_len) - lineStartAt(idx)));
}

fn lineStartFor(line_no: i32) usize {
    if (line_no <= 0) return 0;
    var i: usize = 0;
    var line: i32 = 0;
    while (i < doc_len and line < line_no) : (i += 1) {
        if (doc[i] == '\n') line += 1;
    }
    return i;
}

fn indexAtLineCol(line_no: i32, col_no: i32) usize {
    const start = lineStartFor(line_no);
    const end = lineEndAt(start);
    const c = @max(0, col_no);
    return @min(end, start + @as(usize, @intCast(c)));
}

fn lineCount() i32 {
    if (doc_len == 0) return 1;
    var lines: i32 = 1;
    var i: usize = 0;
    while (i < doc_len) : (i += 1) {
        if (doc[i] == '\n') lines += 1;
    }
    return lines;
}

fn ensureCaretVisible() void {
    const line = lineNumberAt(caret);
    const col = colAt(caret);

    if (line < scroll_line) scroll_line = line;
    if (line >= scroll_line + VIEW_ROWS) scroll_line = line - VIEW_ROWS + 1;
    if (col < scroll_col) scroll_col = col;
    if (col >= scroll_col + VIEW_COLS) scroll_col = col - VIEW_COLS + 1;

    const max_scroll_line = @max(0, lineCount() - VIEW_ROWS);
    if (scroll_line > max_scroll_line) scroll_line = max_scroll_line;
    if (scroll_line < 0) scroll_line = 0;
    if (scroll_col < 0) scroll_col = 0;
}

fn textIndexAtPoint(x: i32, y: i32) usize {
    const clamped_x = clampI32(x, TEXT_X, TEXT_X + TEXT_W - 1);
    const clamped_y = clampI32(y, TEXT_Y, TEXT_Y + TEXT_H - 1);
    const line = scroll_line + @divTrunc(clamped_y - TEXT_Y, LINE_H);
    const col = scroll_col + @divTrunc(clamped_x - TEXT_X, CHAR_W);
    return indexAtLineCol(line, col);
}

fn drawFrame() void {
    fillRectI32(0, 0, @as(i32, @intCast(RENDER_W)), @as(i32, @intCast(RENDER_H)), C_DESKTOP);
    drawWindow();
}

fn drawWindow() void {
    fillRectI32(WINDOW_X, WINDOW_Y, WINDOW_W, WINDOW_H, C_WIN);
    drawRect(WINDOW_X, WINDOW_Y, WINDOW_W, WINDOW_H, C_WIN_DARK);

    drawVerticalGradient(WINDOW_X + 1, WINDOW_Y + 1, WINDOW_W - 2, TITLE_H - 2, C_TITLE_TOP, C_TITLE_BOTTOM);
    drawRect(WINDOW_X + 1, WINDOW_Y + TITLE_H - 1, WINDOW_W - 2, 1, C_WIN_DARK);
    drawTextScaled(WINDOW_X + 8, WINDOW_Y + 5, "TextEdit", C_TEXT, 1);
    drawWindowButtons();

    fillRectI32(WINDOW_X + 1, WINDOW_Y + TITLE_H, WINDOW_W - 2, MENU_H, .{ 0xE5, 0xE5, 0xE5, 0xFF });
    drawRect(WINDOW_X + 1, WINDOW_Y + TITLE_H + MENU_H - 1, WINDOW_W - 2, 1, .{ 0xB2, 0xB2, 0xB2, 0xFF });
    drawTextScaled(WINDOW_X + 8, WINDOW_Y + TITLE_H + 4, "File Edit Format View Help", C_DIM, 1);

    fillRectI32(TEXT_X - 1, TEXT_Y - 1, TEXT_W + 2, TEXT_H + 2, C_WIN_DARK);
    fillRectI32(TEXT_X, TEXT_Y, TEXT_W, TEXT_H, C_TEXT_BG);
    drawDocumentText();
    drawStatusBar();
}

fn drawWindowButtons() void {
    fillCircle(WINDOW_X + 8, WINDOW_Y + 9, 3, .{ 0xE1, 0x65, 0x5B, 0xFF });
    fillCircle(WINDOW_X + 18, WINDOW_Y + 9, 3, .{ 0xE8, 0xC3, 0x58, 0xFF });
    fillCircle(WINDOW_X + 28, WINDOW_Y + 9, 3, .{ 0x63, 0xCA, 0x62, 0xFF });
}

fn drawDocumentText() void {
    const sel = selectionRange();
    const has_sel = hasSelection();

    var row: i32 = 0;
    while (row < VIEW_ROWS) : (row += 1) {
        const line_no = scroll_line + row;
        const line_start = lineStartFor(line_no);
        if (line_start > doc_len) break;
        if (line_start == doc_len and line_no > lineNumberAt(doc_len)) break;
        const line_end = lineEndAt(line_start);

        const visible_start = @min(line_end, line_start + @as(usize, @intCast(scroll_col)));
        const visible_end = @min(line_end, visible_start + @as(usize, @intCast(VIEW_COLS)));
        const y = TEXT_Y + row * LINE_H;

        var i = visible_start;
        while (i < visible_end) : (i += 1) {
            const x = TEXT_X + @as(i32, @intCast(i - visible_start)) * CHAR_W;
            if (has_sel and i >= sel.start and i < sel.end) {
                fillRectI32(x, y, CHAR_W, LINE_H, C_SEL);
            }
            const ch = doc[i];
            drawTextScaled(x + 1, y + 2, &[_]u8{ch}, if (has_sel and i >= sel.start and i < sel.end) C_SEL_TEXT else C_TEXT, 1);
        }
    }

    if (blink_on) drawCaret();
    drawScrollBar();
}

fn drawCaret() void {
    if (hasSelection()) return;
    const line = lineNumberAt(caret);
    const col = colAt(caret);
    if (line < scroll_line or line >= scroll_line + VIEW_ROWS) return;
    if (col < scroll_col or col > scroll_col + VIEW_COLS) return;
    const x = TEXT_X + (col - scroll_col) * CHAR_W;
    const y = TEXT_Y + (line - scroll_line) * LINE_H;
    fillRectI32(x, y + 1, 1, LINE_H - 2, C_CARET);
}

fn drawScrollBar() void {
    const bar_x = TEXT_X + TEXT_W - 8;
    const bar_y = TEXT_Y + 1;
    const bar_h = TEXT_H - 2;
    fillRectI32(bar_x, bar_y, 7, bar_h, .{ 0xEE, 0xEE, 0xEE, 0xFF });
    drawRect(bar_x, bar_y, 7, bar_h, .{ 0xC2, 0xC2, 0xC2, 0xFF });

    const lines = lineCount();
    if (lines <= VIEW_ROWS) {
        fillRectI32(bar_x + 1, bar_y + 1, 5, bar_h - 2, .{ 0xD8, 0xD8, 0xD8, 0xFF });
        return;
    }

    const thumb_h = @max(8, @divTrunc(bar_h * VIEW_ROWS, lines));
    const max_scroll = @max(1, lines - VIEW_ROWS);
    const travel = bar_h - thumb_h;
    const thumb_y = bar_y + @divTrunc(scroll_line * travel, max_scroll);
    fillRectI32(bar_x + 1, thumb_y, 5, thumb_h, .{ 0xB7, 0xB7, 0xB7, 0xFF });
    drawRect(bar_x + 1, thumb_y, 5, thumb_h, .{ 0x8D, 0x8D, 0x8D, 0xFF });
}

fn drawStatusBar() void {
    const y = WINDOW_Y + WINDOW_H - 10;
    fillRectI32(WINDOW_X + 1, y, WINDOW_W - 2, 9, .{ 0xE5, 0xE5, 0xE5, 0xFF });
    drawRect(WINDOW_X + 1, y, WINDOW_W - 2, 1, .{ 0xBC, 0xBC, 0xBC, 0xFF });

    const line = lineNumberAt(caret) + 1;
    const col = colAt(caret) + 1;
    drawTextScaled(WINDOW_X + 6, y + 2, "Ln", C_DIM, 1);
    drawNumber(WINDOW_X + 18, y + 2, line, C_DIM);
    drawTextScaled(WINDOW_X + 46, y + 2, "Col", C_DIM, 1);
    drawNumber(WINDOW_X + 66, y + 2, col, C_DIM);
    drawTextScaled(WINDOW_X + 104, y + 2, "Chars", C_DIM, 1);
    drawNumber(WINDOW_X + 134, y + 2, @as(i32, @intCast(doc_len)), C_DIM);
}

fn drawNumber(x: i32, y: i32, n: i32, color: Color) void {
    var buf: [16]u8 = undefined;
    const len = formatInt(n, &buf);
    drawTextScaled(x, y, buf[0..len], color, 1);
}

fn formatInt(n: i32, out: []u8) usize {
    if (out.len == 0) return 0;
    if (n == 0) {
        out[0] = '0';
        return 1;
    }
    var value = if (n < 0) -n else n;
    var tmp: [16]u8 = undefined;
    var tlen: usize = 0;
    while (value > 0 and tlen < tmp.len) : (tlen += 1) {
        tmp[tlen] = @as(u8, @intCast('0' + @mod(value, 10)));
        value = @divTrunc(value, 10);
    }
    var i: usize = 0;
    if (n < 0 and i < out.len) {
        out[i] = '-';
        i += 1;
    }
    var j: usize = 0;
    while (j < tlen and i < out.len) : (j += 1) {
        out[i] = tmp[tlen - 1 - j];
        i += 1;
    }
    return i;
}

fn pointInRect(x: i32, y: i32, r: Rect) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

fn drawVerticalGradient(x: i32, y: i32, w: i32, h: i32, top: Color, bottom: Color) void {
    if (w <= 0 or h <= 0) return;
    var yy: i32 = 0;
    while (yy < h) : (yy += 1) {
        const t = @divTrunc(yy * 255, @max(1, h - 1));
        const c: Color = .{
            lerpU8(top[0], bottom[0], t),
            lerpU8(top[1], bottom[1], t),
            lerpU8(top[2], bottom[2], t),
            0xFF,
        };
        fillRectI32(x, y + yy, w, 1, c);
    }
}

fn lerpU8(a: u8, b: u8, t255: i32) u8 {
    const inv = 255 - t255;
    const v = @divTrunc(@as(i32, a) * inv + @as(i32, b) * t255 + 127, 255);
    return @as(u8, @intCast(clampI32(v, 0, 255)));
}

fn drawTextScaled(x: i32, y: i32, text: []const u8, c: Color, scale: i32) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        drawCharScaled(x + @as(i32, @intCast(i)) * (4 * scale), y, text[i], c, scale);
    }
}

fn drawCharScaled(x: i32, y: i32, ch: u8, c: Color, scale: i32) void {
    const rows = glyph(ch);
    var ry: usize = 0;
    while (ry < 5) : (ry += 1) {
        var rx: usize = 0;
        while (rx < 3) : (rx += 1) {
            if ((rows[ry] & (@as(u8, 1) << @as(u3, @intCast(2 - rx)))) == 0) continue;
            fillRectI32(
                x + @as(i32, @intCast(rx)) * scale,
                y + @as(i32, @intCast(ry)) * scale,
                scale,
                scale,
                c,
            );
        }
    }
}

fn glyph(ch: u8) [5]u8 {
    return switch (ch) {
        'A', 'a' => .{ 0b010, 0b101, 0b111, 0b101, 0b101 },
        'B', 'b' => .{ 0b110, 0b101, 0b110, 0b101, 0b110 },
        'C', 'c' => .{ 0b111, 0b100, 0b100, 0b100, 0b111 },
        'D', 'd' => .{ 0b110, 0b101, 0b101, 0b101, 0b110 },
        'E', 'e' => .{ 0b111, 0b100, 0b110, 0b100, 0b111 },
        'F', 'f' => .{ 0b111, 0b100, 0b110, 0b100, 0b100 },
        'G', 'g' => .{ 0b111, 0b100, 0b101, 0b101, 0b111 },
        'H', 'h' => .{ 0b101, 0b101, 0b111, 0b101, 0b101 },
        'I', 'i' => .{ 0b111, 0b010, 0b010, 0b010, 0b111 },
        'J', 'j' => .{ 0b001, 0b001, 0b001, 0b101, 0b111 },
        'K', 'k' => .{ 0b101, 0b101, 0b110, 0b101, 0b101 },
        'L', 'l' => .{ 0b100, 0b100, 0b100, 0b100, 0b111 },
        'M', 'm' => .{ 0b101, 0b111, 0b111, 0b101, 0b101 },
        'N', 'n' => .{ 0b110, 0b101, 0b101, 0b101, 0b101 },
        'O', 'o', '0' => .{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        'P', 'p' => .{ 0b110, 0b101, 0b110, 0b100, 0b100 },
        'Q', 'q' => .{ 0b111, 0b101, 0b101, 0b111, 0b001 },
        'R', 'r' => .{ 0b110, 0b101, 0b110, 0b101, 0b101 },
        'S', 's', '5' => .{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        'T', 't' => .{ 0b111, 0b010, 0b010, 0b010, 0b010 },
        'U', 'u' => .{ 0b101, 0b101, 0b101, 0b101, 0b111 },
        'V', 'v' => .{ 0b101, 0b101, 0b101, 0b101, 0b010 },
        'W', 'w' => .{ 0b101, 0b101, 0b111, 0b111, 0b101 },
        'X', 'x' => .{ 0b101, 0b101, 0b010, 0b101, 0b101 },
        'Y', 'y' => .{ 0b101, 0b101, 0b010, 0b010, 0b010 },
        'Z', 'z' => .{ 0b111, 0b001, 0b010, 0b100, 0b111 },
        '1' => .{ 0b010, 0b110, 0b010, 0b010, 0b111 },
        '2' => .{ 0b111, 0b001, 0b111, 0b100, 0b111 },
        '3' => .{ 0b111, 0b001, 0b111, 0b001, 0b111 },
        '4' => .{ 0b101, 0b101, 0b111, 0b001, 0b001 },
        '6' => .{ 0b111, 0b100, 0b111, 0b101, 0b111 },
        '7' => .{ 0b111, 0b001, 0b001, 0b001, 0b001 },
        '8' => .{ 0b111, 0b101, 0b111, 0b101, 0b111 },
        '9' => .{ 0b111, 0b101, 0b111, 0b001, 0b111 },
        '.' => .{ 0b000, 0b000, 0b000, 0b010, 0b010 },
        ',' => .{ 0b000, 0b000, 0b000, 0b010, 0b100 },
        ':' => .{ 0b000, 0b010, 0b000, 0b010, 0b000 },
        ';' => .{ 0b000, 0b010, 0b000, 0b010, 0b100 },
        '!' => .{ 0b010, 0b010, 0b010, 0b000, 0b010 },
        '?' => .{ 0b111, 0b001, 0b011, 0b000, 0b010 },
        '"' => .{ 0b101, 0b101, 0b000, 0b000, 0b000 },
        '\'' => .{ 0b010, 0b010, 0b000, 0b000, 0b000 },
        '(' => .{ 0b001, 0b010, 0b010, 0b010, 0b001 },
        ')' => .{ 0b100, 0b010, 0b010, 0b010, 0b100 },
        '[' => .{ 0b011, 0b010, 0b010, 0b010, 0b011 },
        ']' => .{ 0b110, 0b010, 0b010, 0b010, 0b110 },
        '{' => .{ 0b001, 0b010, 0b110, 0b010, 0b001 },
        '}' => .{ 0b100, 0b010, 0b011, 0b010, 0b100 },
        '<' => .{ 0b001, 0b010, 0b100, 0b010, 0b001 },
        '>' => .{ 0b100, 0b010, 0b001, 0b010, 0b100 },
        '/' => .{ 0b001, 0b001, 0b010, 0b100, 0b100 },
        '\\' => .{ 0b100, 0b100, 0b010, 0b001, 0b001 },
        '+' => .{ 0b000, 0b010, 0b111, 0b010, 0b000 },
        '-' => .{ 0b000, 0b000, 0b111, 0b000, 0b000 },
        '*' => .{ 0b101, 0b010, 0b111, 0b010, 0b101 },
        '=' => .{ 0b000, 0b111, 0b000, 0b111, 0b000 },
        '_' => .{ 0b000, 0b000, 0b000, 0b000, 0b111 },
        '|' => .{ 0b010, 0b010, 0b010, 0b010, 0b010 },
        '#' => .{ 0b101, 0b111, 0b101, 0b111, 0b101 },
        '$' => .{ 0b010, 0b111, 0b110, 0b011, 0b111 },
        '%' => .{ 0b101, 0b001, 0b010, 0b100, 0b101 },
        '&' => .{ 0b010, 0b101, 0b010, 0b101, 0b011 },
        '@' => .{ 0b111, 0b101, 0b111, 0b100, 0b111 },
        '^' => .{ 0b010, 0b101, 0b000, 0b000, 0b000 },
        '`' => .{ 0b010, 0b001, 0b000, 0b000, 0b000 },
        '~' => .{ 0b000, 0b011, 0b110, 0b000, 0b000 },
        ' ' => .{ 0, 0, 0, 0, 0 },
        else => .{ 0b111, 0b001, 0b010, 0b000, 0b010 },
    };
}

fn fillCircle(cx: i32, cy: i32, r: i32, c: Color) void {
    var y = cy - r;
    while (y <= cy + r) : (y += 1) {
        var x = cx - r;
        while (x <= cx + r) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx + dy * dy <= r * r) setPixelI32(x, y, c);
        }
    }
}

fn drawRect(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    fillRectI32(x, y, w, 1, c);
    fillRectI32(x, y + h - 1, w, 1, c);
    fillRectI32(x, y, 1, h, c);
    fillRectI32(x + w - 1, y, 1, h, c);
}

fn fillRectI32(x0: i32, y0: i32, w: i32, h: i32, c: Color) void {
    if (w <= 0 or h <= 0) return;
    var y = y0;
    while (y < y0 + h) : (y += 1) {
        var x = x0;
        while (x < x0 + w) : (x += 1) setPixelI32(x, y, c);
    }
}

fn setPixelI32(x: i32, y: i32, c: Color) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(RENDER_W)) or y >= @as(i32, @intCast(RENDER_H))) return;
    const idx = (@as(usize, @intCast(y)) * RENDER_W + @as(usize, @intCast(x))) * 4;
    output_buf[idx + 0] = c[0];
    output_buf[idx + 1] = c[1];
    output_buf[idx + 2] = c[2];
    output_buf[idx + 3] = c[3];
}

fn clampI32(v: i32, lo: i32, hi: i32) i32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}
