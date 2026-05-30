# Vector Editor

A simple SVG-style vector editor focused on path primitives:

- Create `line`, `polygon`, and cubic `bezier` path shapes
- Select by clicking edges
- Edit nodes by dragging anchors and Bezier control handles

Controls:

- `1` = Select tool
- `2` = Line tool (click-drag-release)
- `3` = Polygon tool (click to add vertices, `Enter` or `Finish` to close)
- `4` = Bezier tool: click to add an anchor, keep holding + drag to pull mirrored handles, release, then click next anchor (`Enter` or `Finish` to commit)
- `G` = toggle fill on selected polygon/bezier shape
- `N` or `Backspace` = delete selected node (or shape)
- `D` or `Delete` = delete selected shape
- `Esc` = cancel current draft
- `C` = clear all

Toolbar buttons match the same actions.

Bezier notes:

- As anchors are added, smooth mirrored handles are shown immediately.
- Dragging one handle mirrors the opposite handle around the anchor.

<qip-play>
  <source src="/modules/interactive/vector-editor.wasm" type="application/wasm" />
</qip-play>
