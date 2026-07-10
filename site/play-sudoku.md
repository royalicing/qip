# Sudoku

Pointer controls:

- Click a cell to select it.
- Click `1`-`9` on the number pad to fill the selected editable cell.
- Use the X button to clear the selected cell or the die button to generate a new puzzle.
- Click the same empty selected cell again to toggle candidates by 3x3 mini-position.

Optional keyboard shortcuts:

- `1`-`9`: set a value in the selected editable cell.
- `Shift+1`-`9` or `Ctrl+1`-`9`: toggle candidate marks.
- `0`, Backspace, or Delete: clear selected editable cell.
- Arrow keys: move selection.
- `R`, `N`, or Enter: generate a new random puzzle.

<qip-play canvas-width="min(780px, 100%)" canvas-height="auto">
  <source src="/components/interactive/sudoku.wasm" type="application/wasm" />
</qip-play>
