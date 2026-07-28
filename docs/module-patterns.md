# QIP Content Component Patterns

A Content component receives one bounded input, calls `render`, and produces
one bounded output. Start by deciding what the output means. That choice
determines whether rejection should trap, whether empty output is valid, and
whether the component belongs in the middle or at the end of a pipeline.

This page covers implementation patterns. The
[Content Component Contract](/docs/content-component) defines the ABI and host
call flow.

## Choose By Purpose

| Purpose | Successful output | Reject with | Repository example |
| --- | --- | --- | --- |
| Assertion gate | Original input unchanged | Trap | [`utf8-must-be-valid.wasm`](/components/utf8/utf8-must-be-valid.wasm) |
| Transformer | Replacement content | Trap | [`json-prettify.wasm`](/components/text/json/json-prettify.wasm) |
| Converter | Content in a different format | Trap | [`svg-to-data-uri.wasm`](/components/image/svg+xml/svg-to-data-uri.wasm) |
| Reporter | Counts, scores, or diagnostics | Trap | [`wasm-counts.wasm`](/components/application/wasm/wasm-counts.wasm) |
| Extractor or filter | Matching content, which may be empty | Trap | [`wasm-read-input-content-type.wasm`](/components/application/wasm/wasm-read-input-content-type.wasm) |

These purposes describe data flow. UTF-8 versus arbitrary bytes is a separate
ABI choice, covered under [Choose The Byte Contract](#choose-the-byte-contract).

## Assertion Gate

Use an assertion gate to enforce an invariant without changing the payload. On
success, return the original bytes and byte count. On failure, trap so the
pipeline stops before an unsafe value reaches another component.

[`utf8-must-be-valid.wasm`](/components/utf8/utf8-must-be-valid.wasm) checks
every UTF-8 sequence and preserves valid input. The
[`warc-check-broken-links.wasm`](/components/application/warc/warc-check-broken-links.wasm)
assertion uses the same shape: it returns the archive unchanged when every
internal link resolves and traps when one does not.

An assertion may use the input region as its output region when no rewrite is
needed. Otherwise, copy the input to a separate output buffer. In either case,
downstream components must receive exactly the bytes that were checked.

Use [`qip comply`](/docs/comply) when the assertion has reusable pass, equality,
and must-trap cases.

## Transformer

Use a transformer when every successful input produces replacement content.
Examples include trimming text, normalizing case, formatting currency,
prettifying JSON, and compressing bytes.

The output may be shorter, the same size, or larger than the input. Choose an
output capacity from the largest supported result, not from a typical fixture.
Trap if the result does not fit. Never return a truncated prefix.

A transformer may write in place only when the algorithm is proven safe for
overlapping input and output. Separate buffers are easier to review when output
can expand or when the parser still needs earlier input bytes.

## Converter

A converter changes the content format. It has the same buffer and failure
rules as a transformer, plus exact input and output MIME metadata.

For example,
[`svg-to-data-uri.wasm`](/components/image/svg+xml/svg-to-data-uri.wasm)
declares `image/svg+xml -> text/uri-list`. It writes in place from the end of
the shared buffer towards the beginning so percent-encoding cannot overwrite
unread input.

Declare only the format the component actually accepts and emits. Do not use a
broad MIME type to hide unsupported variants. See
[Formats and Encodings](/docs/formats) for repository conventions.

## Reporter

A reporter replaces the input with facts about it. Counts, scores, indexes,
diagnostics, and status records are ordinary successful output.

[`wasm-counts.wasm`](/components/application/wasm/wasm-counts.wasm) accepts
`application/wasm` and returns deterministic `text/csv`. It reports
measurements without deciding whether the module should pass a policy.

Reporters are normally terminal. If another component follows, it receives the
report, not the original input. Use an assertion gate when the original payload
must continue through the pipeline.

Do not call a reporter a validator merely because it emits `valid` or
`invalid`. Returning `invalid` is still successful execution. Trap when invalid
input must abort the operation.

## Extractor Or Filter

An extractor selects part of a valid input. A filter selects zero or more
matching records. Empty output is correct when the input contains no match.

[`wasm-read-input-content-type.wasm`](/components/application/wasm/wasm-read-input-content-type.wasm)
returns zero bytes when a valid module omits optional input content-type
metadata. Malformed Wasm and invalid metadata trap.

No match does not always mean a zero-byte file.
[`warc-extract-broken-links.wasm`](/components/application/warc/warc-extract-broken-links.wasm)
returns a valid archive containing no response records when it finds no broken
internal links; the archive still contains its required `warcinfo` record.

Malformed input and output overflow are not “no match”. Trap for those
conditions so callers can distinguish failure from a successful empty result.

## A Trap Is The Emergency Stop

Use a trap when continuing could corrupt, truncate, mislabel, or discard data.
The pipeline stops and reports failure instead of passing damaged output to the
next component.

Trap on:

- malformed input;
- input or output outside the component's supported limits;
- violated safety or format invariants;
- allocation or cleanup failure; and
- any condition that would otherwise produce partial or misleading output.

Returning zero is different. It tells the host that the component succeeded
and produced an empty result. Return zero only when empty output is correct.

Some existing components return zero on parse errors or overflow. Do not copy
that behavior into new components: it makes failure indistinguishable from a
successful empty result. When changing such a component, preserve zero only if
its documented output can legitimately be empty; otherwise, change the failure
path to trap and update its tests.

Language forms:

```zig
if (invalid_input or output_overflow) @trap();
```

```c
if (invalid_input || output_overflow) __builtin_trap();
```

```wat
(if (local.get $invalid_input)
  (then unreachable))
```

## Choose The Byte Contract

Use `input_utf8_cap` or `output_utf8_cap` only when the corresponding bytes
must be valid UTF-8. Use the `bytes` capacity exports for arbitrary binary
data. Capacity values are byte counts in both cases.

Add exact MIME metadata when a component requires or guarantees a specific
format. Omit it for intentionally generic UTF-8 or bytes. The
[Content Component Contract](/docs/content-component#optional-content-type-metadata)
defines composition and metadata inheritance.

## Design For Repeated Renders

Hosts may reuse an instance. A trap stops one call; it does not reset WebAssembly
memory or globals.

Reset cursors, overflow flags, parser state, and allocator telemetry at the
start of each render. Once allocation begins, release temporary allocations
before returning or trapping.

Test an invalid render followed by a valid render on the same instance. This
catches stale output lengths, poisoned parser state, and arenas that were not
reset after rejection.

## Test The Contract Boundary

For each component, cover:

- one representative successful input and exact output;
- malformed input that must trap;
- empty input and no-match input, when either is valid;
- the largest supported input or a focused capacity-boundary case;
- output overflow;
- a rejected render followed by a valid render on the same instance; and
- exact MIME metadata for converters and format-specific components.

Use [Bounded Output Proofs](/docs/hard-limits#bounded-output-proofs) when the
compiled component should carry a statically checkable output bound. Follow
[Benchmarking Components](/docs/benchmarking-components) only after behavior
and limits are stable.

## When Not To Use A Content Component

Use [Interactive](/docs/interactive-component) when state must remain live
across events and scheduled ticks. Use Tile for host-managed image regions and
Form for prompt-driven multi-step input; both are indexed from
[QIP Component Contracts](/docs/component-contract).

Content components require the complete input and maximum output to fit their
declared memory. If the workload requires unbounded streaming or data larger
than a practical fixed memory limit, change the boundary rather than hiding the
stream inside an oversized component.
