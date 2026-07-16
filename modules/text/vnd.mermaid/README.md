# Mermaid to Unicode HTML

`mermaid-to-unicode-html.wasm` converts a strict Mermaid subset into the
span-styled Unicode box art used by Simon Willison's grok-mermaid tool.

The Content component accepts `text/vnd.mermaid` and returns a `text/html`
fragment. The fragment contains styled `<span>` runs and newline-separated
rows; the host supplies the surrounding `<pre>`.

## Supported subset

- top-to-bottom decision flowcharts with two-way branches, wrapped node labels,
  and solid, dotted, and thick edges
- two left-to-right subgraphs, each containing one edge, joined by one labelled
  edge; node labels wrap at 24 columns for up to four lines
- sequence diagrams with participants, aliases, adjacent calls, and adjacent
  dashed replies
- the start → state → fork → retry/end state-machine form
- one class with direct subclasses, fields, and methods
- linear ER chains with attributes, relationship labels, and `1`, `0..*`,
  and `1..*` cardinalities

The parser traps on blank input, invalid UTF-8, unsupported diagram families,
malformed statements, and graph shapes outside this initial subset. It does not
fall back to a framed source listing.

## Compatibility

`compliance/mermaid-to-unicode-html.fixtures.txt` contains 27
byte-for-byte HTML fixtures derived independently from the published reference
renderer. The strict comply component adds nine rejection cases.

The renderer deliberately preserves several visible reference quirks:

- flowchart decision nodes use rounded boxes rather than diamond outlines
- state start and end markers are both rendered as `●`
- class siblings are vertically centre-aligned
- cross-subgraph arrows attach to the group frames
- sequence message text uses the node-text span role, not the edge-label role

There is no max-width uniform. Width limiting in the reference swaps the
diagram for a framed source listing rather than laying it out differently.
