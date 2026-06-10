# Spreadsheet

A compact spreadsheet for editing cells directly inside a QIP interactive module.

Supported:

- Arrow-key cell navigation
- Mouse cell selection
- Type to edit the active cell
- `Enter` commits and moves down
- `Tab` commits and moves right
- `Esc` cancels the current edit
- `Backspace` / `Delete` clears or edits cell text
- `Ctrl`/`Cmd` + `C`, `X`, `V` for internal copy, cut, and paste
- Simple formulas with integer cell references, such as `=B2*C2` and `=D2+D3`

<qip-play>
  <source src="/components/interactive/spreadsheet.wasm" type="application/wasm" />
</qip-play>
