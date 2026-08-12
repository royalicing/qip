# Content Component Contract

Content components perform finite transformations over text or bytes. The host writes input into WebAssembly memory, applies any uniforms, calls `render(input_size)`, then reads the returned output bytes.

Use this contract for converters, validators, formatters, document renderers, generators, and pipeline stages. Use the [Interactive Component Contract](/docs/interactive-component) instead when a component must retain live state across user events and scheduled ticks.

## Required Exports

Every Content component exports:

- `memory`
- `input_ptr() -> i32`: offset where the host writes input.
- Either `input_utf8_cap() -> i32` or `input_bytes_cap() -> i32`: maximum input bytes.
- `render(input_size: i32) -> i32`: transform the input and return the output byte count.
- `output_ptr() -> i32`: offset where the host reads output. The host calls this only after a successful `render`.
- Either `output_utf8_cap() -> i32` or `output_bytes_cap() -> i32`: maximum output bytes.

Every pointer and capacity export is a zero-argument function returning `i32`.
An exported global is rejected. A getter function may read an immutable
internal global when its value is module-constant.

The `utf8` capacity exports declare that the corresponding bytes must be valid UTF-8. The `bytes` variants carry arbitrary binary data.

## Host Call Flow

For each render request using a known-valid QIP component, the host:

1. Instantiates or reuses the component.
2. Verifies that `input_size` does not exceed the input capacity.
3. Writes the input bytes at `input_ptr`.
4. Applies any requested [uniforms](/docs/uniforms).
5. Calls `render(input_size)`.
6. Calls `output_ptr` and reads exactly the returned number of bytes.

If `render` traps, the request fails. The host must not read `output_ptr`; the buffer may contain stale or partial output.

A valid component guarantees that a successful `render` returns a byte count
within its declared output capacity and that `output_ptr` identifies a region
large enough for those bytes. Application wrappers for a component they trust
may rely on those guarantees. They still check input size because the caller,
not the component, chooses the input.

## Known And Untrusted Components

A known-valid component is an artifact the application deliberately trusts:
for example, one built and tested with the application or obtained through a
controlled artifact pipeline. Its QIP exports, memory regions, content types,
and render behavior are part of that trust decision. Ordinary wrappers should
use the contract directly instead of repeatedly checking whether the component
honored it.

Arbitrary Wasm is different. Core WebAssembly validation proves that a module
is structurally valid Wasm, not that it implements a QIP contract. A generic
host accepting modules from users or third parties must establish that boundary
itself. Before execution it checks the required exports and their signatures.
Before copying input it checks the advertised input region. After `render` it
checks the returned size and output region before reading component memory. It
also applies the memory and execution policies described in [Hard
Limits](/docs/hard-limits).

These checks belong at the point where arbitrary modules enter the application.
Once an artifact has been admitted as a known-valid component, downstream
wrappers can use the simpler call flow above.

Components can make the successful output-size guarantee statically
certifiable with `components/application/wasm/wasm-bounded-output.wasm`. The
checker recognizes a small compiled-Wasm proof epilogue that traps when the
result exceeds the exact static output capacity. See [Bounded Output
Proofs](/docs/hard-limits#bounded-output-proofs) for the accepted shape and its
limits.

## Repeated Renders

Hosts may call `render` more than once on the same component instance. Each call is a new request using the bytes currently at `input_ptr` and the component's current uniform state.

Component authors should make repeated renders deliberate:

- Treat the input region as host-owned for the duration of each call.
- Return the byte length of the current output, not a cumulative length.
- Expect the host to read `output_ptr` after every successful render.
- Keep caches and scratch state consistent when input bytes or uniforms change.
- Trap on invalid input or output overflow instead of leaving a stale previous output.

This lets browser hosts retain an instance for many requests and lets wrappers set uniforms immediately before rendering without reinstantiation.

## Optional Content-Type Metadata

A component may declare an exact input or output MIME type with:

- `input_content_type_ptr()` and `input_content_type_size()`
- `output_content_type_ptr()` and `output_content_type_size()`

Both exports in a pointer/size pair must be present. Omit a pair when the content type is unknown or intentionally generic.

When present, the value must normally be one lowercase MIME media type, such
as `text/markdown`, `text/html`, or `image/bmp`. Do not include whitespace,
media ranges, comma-separated lists, or parameters such as `charset=utf-8`.
The multipart boundary slot defined below is the only parameter exception.
Hosts otherwise compare these strings exactly; they do not trim, lowercase,
or remove parameters.

Content type is module metadata, not render state. Its pointer, size, and bytes
must not vary with input, uniforms, previous calls, or other runtime state,
except for a host-written multipart boundary UUID as defined below. Modules in
the strict artifact profile make the initial metadata statically readable:

- each pointer and size export is a zero-argument `i32` getter containing
  exactly one `i32.const` or one `global.get` of an immutable constant `i32`
  global, followed by `end`;
- both exports in the pair are present; and
- the referenced bytes are within initial memory and supplied by one
  non-overlapping active data segment, rather than assembled by a start
  function or `render`.

This lets tooling read the declared type directly from Wasm sections without
allocating memory or instantiating and executing the module.

### Multipart Form Data

QIP allow-lists parameterized multipart media types rather than accepting
arbitrary MIME parameters. The initial allow-list contains only
`multipart/form-data`. Other `multipart/*` types and all other parameters
remain invalid until this contract defines their byte layout and host rules.

A component that consumes or produces multipart form data declares exactly
this shape:

```text
multipart/form-data;boundary=uuid-00000000-0000-0000-0000-000000000000
```

The boundary is the five immutable ASCII bytes `uuid-` followed by a mutable
36-byte canonical lowercase UUID. It is unquoted and has no surrounding
whitespace. No other parameters are permitted. The content-type pointer and
size remain module constants; the initial UUID bytes must be present in the
active data segment so static tooling can read a complete valid default.

Before `render`, a host may replace exactly those 36 UUID bytes in exported
memory. It must not change `multipart/form-data;boundary=uuid-`, the pointer,
the size, or any other byte. The replacement must have the canonical UUID
shape `8-4-4-4-12` using lowercase ASCII hexadecimal digits and hyphens. A
host that does not need a distinct boundary leaves the declared default in
place.

This exception is symmetric. A multipart producer reads its current output
boundary slot when rendering delimiters. A multipart consumer reads its
current input boundary slot when parsing them. To connect the two, the host
copies the producer's 36 UUID bytes into the consumer's input slot before
calling the consumer. The host also updates the content type it tracks for the
pipeline, so the producer's output and consumer's input still match exactly.
An exact-length slot does not accept an external multipart boundary of a
different shape or length; an ingress adapter must normalize such a body or
use a component contract designed for the complete external message.

The boundary parameter does not include the two structural hyphens used by
multipart delimiters. For boundary `uuid-<uuid>`, a producer emits:

```text
--uuid-<uuid>\r\n
--uuid-<uuid>--\r\n
```

Component authors must keep the declared slot as the single source of truth.
Code that renders or parses multipart bytes must load the current UUID from
that mutable memory for every request; it must not use an inlined or duplicate
constant. Output components must reject a part body containing a delimiter
line for the current boundary rather than emit ambiguous multipart. Tests must
replace the default UUID and prove that the exported content type and every
rendered or accepted delimiter use the replacement.

The pointer, size, media type, parameter name, `uuid-` prefix, and initial UUID
remain statically inspectable. Only the UUID slot is host-configurable. This
narrow exception preserves ordinary content-type metadata as immutable module
metadata and does not create a general string-uniform mechanism.

The repository includes such a reader as a QIP component. It prints the input
content type, prints an empty line when the pair is omitted, and traps when any
input or output content-type metadata violates the static form:

```bash
qip run -i component.wasm -- \
  components/application/wasm/wasm-read-input-content-type.wasm
```

Do not export catch-all MIME types for data whose generic shape is already
declared by the capacity ABI:

- Omit `text/plain` for generic UTF-8. The `input_utf8_cap` and
  `output_utf8_cap` exports already express that constraint.
- Omit `application/octet-stream` for generic raw bytes. The `input_bytes_cap`
  and `output_bytes_cap` exports already express that constraint.

Adding either MIME type has no descriptive benefit and unnecessarily
constrains recipe composition through exact content-type matching. Export
content-type metadata only when the component requires or guarantees a more
specific format.

## Pipeline Composition

The host tracks an optional content type as bytes pass through a pipeline:

- A caller-provided initial content type is authoritative.
- Direct stdin or `-i` input to `qip run` has no separate content-type channel. When no initial type exists, user intent permits the first stage.
- A declared input content type must exactly match the current pipeline type.
- Without declared input metadata, `input_utf8_cap` accepts any UTF-8 pipeline input and `input_bytes_cap` accepts any bytes.
- A declared output content type replaces the current pipeline type.
- Without declared output metadata, a UTF-8-to-UTF-8 transform preserves the current type.
- A bytes-to-UTF-8 transform produces new text with an unspecified type.
- Output through `output_bytes_cap` preserves the current type.

These rules let generic operations such as UTF-8 validation or byte-preserving transforms compose without erasing a more precise type, while format converters can explicitly change it.

## Memory And Failure Behavior

- Keep input and output buffers disjoint unless overlap is an intentional, tested optimization.
- Validate `input_size` inside the component even when the host also checks it.
- Reserve explicit scratch space rather than assuming unused capacity belongs to the component.
- Trap on invalid input, violated invariants, or output overflow.
- Prefer a trap over silent truncation for data-preserving transforms.
- Return `0` only when empty output is a successful result.
- For Zig components, compile with an explicit Wasm memory maximum. See [Writing QIP Components In Zig](/docs/zig-components) and [Hard Limits](/docs/hard-limits).

## Future Numeric Output Shapes

QIP previously supported `output_i32_cap`; it is not part of the current contract. Histograms, masks, label matrices, spectra, and similar results need more than a one-off integer-array export.

A future design should keep three concerns separate:

- Element type, such as `i32`, `u8`, `f32`, or a SIMD lane type.
- Logical shape, such as `[256]`, `[3, 256]`, or `[height, width, bands]`.
- Physical layout, including dense row-major, strides, alignment, tiling, or planar/interleaved data.

Until that design is specified, represent numeric collections through an explicitly documented byte format rather than relying on the removed export.
