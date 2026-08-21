# Temporary Content Failure And Uniform Audit

This is a working migration file for the Content `commit` contract.
Delete it after every row is resolved in component tests or permanent contract
documentation. It is not a normative QIP specification.

Audit snapshot: 2026-08-20. The repository had unrelated in-progress image
format changes during this audit. Recheck renamed and newly added components
before starting the migration.

## Migration Order

Do the component work in two passes:

1. Fix components intended to return normally for every allowed input. Prove
   their output bounds, remove zero returns that can mean either error or empty
   output, and keep them free of `commit` when they need no recoverable error.
   Run the static trap analyzer on the final compiled Wasm.
2. Add `commit` to components that can reject an allowed input. Make `render`
   return normally for expected rejection and make the
   host ignore provisional output unless `commit` accepts it.

Whenever either pass changes a component with uniforms, make the same change
reset every public uniform to its authored default after `render` returns.
Reset after successful, empty, and failed renders. A failable component may
retain private candidate values until `commit`, but its public uniform values are
already reset. Add a repeated-render test which omits the setter on the second
render and observes the authored default.

## Repository Migration Estimate

The snapshot contained 174 Content migration targets and one deliberate
infinite-loop fixture. The earlier estimate assigned `commit` to every format
parser because it treated MIME as routing information only. That estimate is
withdrawn.

The revised contract lets a component require a valid declared format. An
expensive PNG, KTX2, ZIP, or similar transform can remain without `commit` when
its documented domain is valid supported input. A separate pass-through
validator accepts arbitrary bytes and uses `commit` to establish that guarantee
at an untrusted boundary. A combined validator and transform can also export
`commit`.

Recount the repository after each component's input domain is documented. The
new count should separate validators, transforms which require validated input,
and transforms which deliberately accept untrusted claimed-format bytes. The
previous totals of 18 effectively unaltered, 36 repaired without `commit`, and
120 gaining `commit` must not be used for planning.

Export presence and static proof are independent. `commit` says that the
component can report rejection without trapping. Missing `commit` says only
that it cannot do so; it does not mean the compiled Wasm cannot trap. A static
analyzer can prove that the exact Wasm bytes do not trap when the host follows
the contract. Rebuilding the component requires a new proof. The same proof is
possible for components with `commit` when all expected failures reach
`commit` and all valid call sequences avoid traps.

Export counting cannot determine whether conforming calls can trap. Static
analysis must use each component's documented encoding, format profile,
capacity, uniforms, and call order.

### Progress On 2026-08-20

Forty-six components have received a source-level capacity and failure review.
The remaining first-pass count must be recalculated under the valid-format
precondition rule. Fourteen components have completed the second-pass `commit`
migration: the UTF-8, ASCII, zlib, Core Wasm, Base64, Luhn, CSS class, HTML ID,
HTML input-name, HTML tag, strict-profile, bounded-loop, bounded-output, and
nontrapping-divide validators. The QIP CLI, Go
Compliance bridge, and `qipx` JavaScript host implement the call sequence and
`must_reject`.

The reviewed components are SHA-256, Base64, CRC-32, trim, E.164,
Markdown title extraction, YouTube ID extraction, three Unicode transforms,
four zlib compressors, nine locale-specific currency formatters, the CSS
expression evaluator, the SVG current-color recolorer, two TTF glyph-path
extractors, two bitmap OG-image renderers, two SVG OG-image renderers, and the
SQLite table counter, plus the UTF-8, ASCII, zlib, Core Wasm, Base64 decoder,
Luhn, CSS class, HTML ID, HTML input-name, HTML tag, strict-profile,
bounded-loop, bounded-output, and nontrapping-divide validators. This is 46 of
174 Content components in the audit: 32 resolved without `commit`, 14 migrated
with `commit`, and 128 snapshot targets still to review or resolve. Recount the
live repository after the in-progress image-format rename settles.
“Reviewed” does not mean that static analysis has proved the compiled Wasm free
of traps. It means the source now states its size argument, tests the relevant
boundary, and no longer uses zero for an error that should be unreachable.

## Commit Results During Migration

For failable Content:

```text
result == 0  accepted
result < 0   rejected
```

Negative details are advisory and are not a stable error-code registry. A host
must treat every negative value as rejection even when it does not understand
the value.

The optional diagnostic form is one signed `i64` bitfield:

```text
bit 63      error
bit 62      invalid input
bits 61-32  reserved; zero for now
bits 31-0   input byte offset or consumed byte count
```

Setting bit 63 makes the result negative. A host only needs the signed test to
reject the transaction. The other fields are optional debug information:

```text
error=1 invalid=0  processing failure; low word is consumed input bytes
error=1 invalid=1  validation failure; low word is the first invalid byte
```

For a validation failure caused by truncated input, the offset is the end of
input. A component which cannot identify a useful byte position sets the low
word to zero. Reporting a validation offset is helpful, not required.

Do not delay a `commit` migration only to thread offsets through a parser. Put a
TODO near the top of the source, for example:

```text
TODO(content-commit): report the invalid input byte offset instead of zero.
```

The TODO is implementation work, not a contract failure. A negative result with
the invalid-input bit and zero detail is a complete rejection.

In unsigned construction notation:

```text
error              = 0x8000_0000_0000_0000
invalid_input      = 0x4000_0000_0000_0000
detail_mask        = 0x0000_0000_ffff_ffff

output_exhausted   = error | consumed_input_bytes
validation_failure = error | invalid_input | invalid_input_offset
```

The component bitcasts the constructed `u64` to `i64` for the ABI return. This
preserves all `u32` progress values, including zero and `UINT32_MAX`, without
colliding with accepted result `0`. Reserved bits permit later diagnostics
without changing the sign-based host rule.

Do not introduce a shared component helper library for these values during the
migration. Keep the few constants and the `u64`-to-`i64` bitcast local to each
component. Central contract tests must exercise the boundary encodings and host
decoding. A shared helper can be considered later only if real implementations
develop enough repeated, error-prone logic to justify another dependency.

This is source-compatible with an old host on successful input: it calls
`render` and reads the same output without noticing `commit`. On rejected input
an old host can observe a zero-byte result instead of a trap. QIP is alpha, so
the migration prioritizes the intended contract over preserving that old
failure behavior.

Timed and Interactive rejection uses the same negative bitfield. The host
already stores the previously committed timestamp, so `commit` does not need to
return that timestamp when it rejects.

## Pass 1: Repair Nontrapping Candidates

These components should not gain `commit` if the stated proof or repair holds.

| Component or group | Finding | Required work |
| --- | --- | --- |
| `components/bytes/bytes-to-sha256.zig` | Reviewed 2026-08-20. It returns a fixed 32-byte digest for every byte input and traps only when the host exceeds the advertised input cap. | Keep it without `commit`; its existing digest test passes. Use static analysis to check the rebuilt Wasm for traps. |
| `components/bytes/base64-encode.wat` | Resolved 2026-08-20. The old 65,536-byte output capacity was too small for a 65,536-byte input. | Output capacity is now the exact `4 * ceil(INPUT_CAP / 3)` bound of 87,384 bytes. Node tests compare a patterned maximum input with its independent encoder; a portable Compliance oracle checks a modest all-zero case without prescribing the implementation capacity. Run static trap analysis on the rebuilt Wasm. |
| `components/bytes/crc32-hex.wat` | Resolved 2026-08-20. It has fixed eight-byte output for every byte input. | It now traps on a host input-cap violation. A portable Compliance oracle covers fixed vectors and repeated-instance state. Run static trap analysis on the rebuilt Wasm. |
| `components/utf8/trim.c` | Resolved 2026-08-20. Trimming cannot expand valid UTF-8 input: `out_len = end - start <= input_size <= INPUT_CAP = OUTPUT_CAP`. | The unreachable zero-on-overflow return was removed and host input-cap violations now trap. A portable Compliance oracle covers trimming and accepted empty output; an implementation test covers the complete input bound. Run static trap analysis on the rebuilt Wasm. |
| `components/utf8/e164.zig` | Resolved 2026-08-20. Compliance treats empty input, `abc`, and `+` as accepted empty output. Its leading `+` needs one more output byte than an all-digit input. | Output capacity is now `INPUT_CAP + 1`; no digits is documented as successful empty output. An implementation test covers the exact maximum boundary without coupling the portable Compliance oracle to that capacity. Run static trap analysis on the rebuilt Wasm. |
| `components/text/markdown/extract-title-text.zig` | Resolved 2026-08-20. No title is valid empty output. Tags, entities, escapes, and Markdown delimiters emit no more bytes than they consume, so `output_size <= selected_title_size <= input_size`. | Output capacity now equals the 1 MiB input capacity; overflow is an invariant defect rather than a second meaning for zero. The portable Compliance oracle covers behavior; an implementation test covers a maximum-size plain heading. Run static trap analysis on the rebuilt Wasm. |
| `components/utf8/youtube-id-extractor.zig` | Resolved 2026-08-20. No match is valid empty output. Every emitted ID is a slice of a longer source token, and each inserted newline corresponds to a source separator. | The implementation now reserves zero only for valid empty output, treats a violated `output_size <= input_size` invariant as a defect, and tests a near-capacity sequence. Run static trap analysis on the rebuilt Wasm. |
| Unicode uppercase and lowercase | Resolved 2026-08-20. Valid UTF-8 is the allowed input. Unicode 17 uppercase has a 3:1 worst-case byte ratio; lowercase has a 3:2 ratio. | Inputs now use the 1 MiB compact profile and outputs use the exact expansion formulas. Inline Zig tests audit every generated mapping and fill the complete input with a worst-case scalar. Protocol and invariant failures use traps. Independent Compliance and JavaScript duel corpora pass. Run static trap analysis on the rebuilt Wasm. |
| `components/utf8/unicode-17-normalize-nfc.zig` | Resolved at source level 2026-08-20. It uses the 1 MiB compact profile, scratch for two decomposed scalars per input byte, and four output bytes per decomposed scalar. | An inline Zig test recursively audits every Unicode 17 canonical decomposition and every Hangul syllable against both bounds. NFC composition cannot increase the decomposed sequence. Invalid UTF-8 is not an allowed input; invariant traps remain emergency stops. Run static trap analysis on the rebuilt Wasm. |
| zlib compressors | Resolved at source level 2026-08-20. Compression accepts every byte string within the 8 MiB input capacity. The stored-block encoder has an exact block-overhead formula. Fixed-Huffman tokens cost at most 9 bits per literal or 31 bits per match of at least three bytes. Dynamic-Huffman tokens cost at most 15 bits per literal or 48 bits per match, and their tree header has a separate calculated bound. | All four components now trap on oversized host input and on violated internal bounds instead of returning an ambiguous zero. Inline tests cover maximum input and the code-table limits; all 21 tests pass. Rebuilt Wasm artifacts pass 2,000 differential fuzz iterations against Node zlib. Static trap analysis remains future work. |
| Currency formatters | Resolved 2026-08-20. Each locale accepts one exact ASCII decimal and a supported ISO 4217 numeric uniform. Its authored currency default is USD (840). | All nine formatters reset the currency uniform after every normal render. Inline Zig tests check hard-coded locale output for EUR, omit the setter, and then check hard-coded USD output. The output bounds and unsupported-input traps remain unchanged. Run static trap analysis on the rebuilt Wasm. |
| `components/text/css/css-expression-to-value.zig` | Resolved 2026-08-20. It accepts its documented CSS scalar grammar and traps on malformed or dimensionally invalid expressions. Its 22 finite, non-negative uniforms have authored pixel defaults. | A successful render now resets all 22 uniforms. One inline Zig test evaluates every uniform in one expression, checks hard-coded configured output `186px`, omits every setter, and checks hard-coded default output `95.2px`. JavaScript tests now pass uniforms before each render and replace an instance after a trap. Run static trap analysis on the rebuilt Wasm. |
| `components/image/svg+xml/svg-recolor-current-color.zig` | Resolved 2026-08-20. It is a total text rewrite over valid UTF-8 and does not need to parse SVG structure. Replacing the 12-byte `currentColor` token with seven or nine CSS hex bytes proves output cannot exceed input. | Oversized host input now traps instead of being silently clamped. A normal render resets `color_rgba` to opaque black. An inline Zig test checks hard-coded red output followed by hard-coded default black output without another setter. Run static trap analysis on the rebuilt Wasm. |
| TTF glyph-path extractors | Reviewed 2026-08-20. Both require a supported valid TTF and trap on malformed data, unsupported structures, parser limits, an invalid selected range, or output overflow. The CSV component documents these limits; the SVG definitions component links to the same parser and limits. | Both now reset `first_codepoint` and `last_codepoint` to U+0020 and U+00FF after every successful render. Direct Wasm tests select U+0041, render again without setters, and observe both default endpoints in hard-coded CSV or SVG output. Keep output overflow as a documented supported-profile boundary unless a complete 32 MiB bound is proved. |
| `components/utf8/text-to-og-image-font8x8.c` | Resolved 2026-08-20. It always emits one 1,200 by 630 BGRA BMP, so the exact output size is `54 + 1200 * 630 * 4` bytes. | Compile-time assertions now prove the authored canvas has rows and columns and its BMP fits the 4 MiB output. Oversized input traps instead of being silently clamped. A direct Wasm test observes custom red-on-blue output, omits both setters, and observes default black-on-white output. |
| `components/utf8/text-to-og-image-dejavu-sans-mono.zig` | Resolved 2026-08-20. It always emits one 1,200 by 630 BGRA BMP with the same exact size as the font8x8 renderer. | Compile-time checks prove the canvas has rows and columns and its BMP fits the 4 MiB output. Oversized input traps instead of being silently clamped. Inline Zig and direct Wasm tests observe custom red-on-blue output followed by default black-on-white output without setters. |
| SVG OG-image renderers | Reviewed 2026-08-20. The DejaVu and Inter components require valid form data, supported embedded glyphs, and text which fits their fixed card profile. Inputs outside that documented profile trap. | Both reset text color, background color, font weight, and maximum font size after every successful render. Inline Zig and direct Wasm tests check hard-coded custom output followed by authored defaults. JavaScript tests reapply uniforms before later renders and replace an instance after a trap. Keep output overflow as an invariant trap while the fixed 8 MiB bound is audited. |
| `components/application/vnd.sqlite3/sqlite-table-count.zig` | Resolved 2026-08-20. It emits a decimal `u64` count plus newline or one short fixed diagnostic, all within its 4 KiB output. | Oversized host input now traps instead of being silently clamped. The table uniform resets after every normal return, including diagnostic output. A direct Wasm test checks table 1 count `15`, default table 0 count `20`, an out-of-range diagnostic, and default count `20` again. |
| Pure generators | They have no caller-provided source value to reject. | Keep them without `commit` if every uniform value is clamped or the complete output bound is proven. Reset all uniforms after render, then run static trap analysis. |

`components/image/svg+xml/svg-to-data-uri.zig` can require valid SVG. It does
not need to parse SVG again before applying its total, bounded percent encoding.
An untrusted source needs an SVG validator earlier in the recipe.

## Pass 2: Add Commit

Start with small assertion gates, then a parser which can leave partial output,
then larger format decoders.

| Component or group | Finding | Required work |
| --- | --- | --- |
| `components/utf8/utf8-must-be-valid.zig` | Migrated 2026-08-20. It now advertises `input_bytes_cap`, shares accepted input as UTF-8 output, rejects malformed sequences through `commit`, and reports the first invalid byte or truncated end offset. | Keep the inline lifecycle tests and `compliance/reject-invalid-utf8.wasm` in the permanent suite. |
| `components/utf8/utf8-must-be-ascii.zig` | Migrated 2026-08-20. It accepts arbitrary bytes, shares accepted ASCII as UTF-8 output, and rejects the first non-ASCII byte through `commit`. | Keep the inline lifecycle tests and `compliance/reject-non-ascii.wasm` in the permanent suite. |
| `components/multipart/form-data/form-data-to-tar.zig` | Expected parser errors become traps, including errors after partial TAR output. | Use it as the first partial-output state-machine migration. Reject at commit and prove instance reuse after rejection. |
| `components/bytes/zlib-decompress.zig` | Migrated 2026-08-20. Valid empty streams now accept while malformed input and output exhaustion reject through `commit`. The inflater does not yet distinguish those two failure causes. | Keep the inline and JavaScript lifecycle tests. Later, expose inflater failure kind and input progress for more precise diagnostics. |
| `components/utf8/base64-decode.wat` | Migrated 2026-08-20. Empty input and canonical RFC 4648 quartets accept. Incomplete quartets, invalid alphabet bytes, misplaced padding, early padding, and non-zero unused pad bits reject through `commit` with a byte offset. | Keep the portable Compliance oracle and JavaScript lifecycle cases. The component deliberately requires whitespace removal and complete four-byte groups at its boundary. |
| `components/utf8/utf8-must-be-valid-odin.odin` | It is another arbitrary-bytes UTF-8 assertion gate and still traps on malformed input. | Migrate it to the same byte-domain and `commit` behavior as the Zig implementation, or remove it if the duplicate implementation no longer earns its maintenance cost. |
| `components/utf8/luhn.wat` | Migrated 2026-08-20. Empty, too-short, non-digit, and checksum failures reject through `commit`. Accepted normalized digits use the input buffer as output, and the instance recovers after rejection. | Keep the generated and mutation-based Compliance oracle and direct JavaScript lifecycle test. |
| `components/text/css/css-class-validator.wat` | Migrated 2026-08-20. Empty, whitespace-only, and multiple-token values reject through `commit`. Accepted trimmed text is compacted in place, and interior whitespace reports its byte offset. | Keep the portable Compliance oracle. It covers accepted output, rejection, and reuse without prescribing the 64 KiB implementation capacity. |
| HTML ID, input-name, and tag validators | Migrated 2026-08-20. Their semantic failures reject through `commit`. HTML IDs and input names preserve accepted input in place; the tag validator returns `builtin` or `custom`. Malformed UTF-8 remains a caller precondition violation. | Keep the inline output and recovery tests, portable Compliance oracles, and JavaScript precondition test. Add a precise invalid-name offset to the tag validator if a diagnostic consumer needs it. |
| `components/utf8/tld-validator.wat` | Its name says TLD validator, but `render` requires a dot and extracts the suffix from a domain. The Makefile passes bare `com` and records empty output. This behavior is too ambiguous to preserve during a failure migration. | Decide whether this validates a bare TLD or extracts a TLD from a domain. Then add `commit`, use accepted text in place where possible, and cover the chosen behavior with a portable oracle. |
| `components/application/wasm/wasm-validate-core-1.0.zig` | Migrated 2026-08-20. It shares accepted input as byte output, rejects parser or validation errors through `commit`, and recovers on the same instance. | Keep the inline and JavaScript lifecycle tests. Thread the parser position into the diagnostic when useful. |
| Wasm policy assertion gates: strict profile, bounded loops, bounded output, and nontrapping divides | Migrated 2026-08-20. A valid Wasm module can fail each policy. All four now reject through `commit`, preserve accepted modules in the input buffer, and recover after rejection. | Keep valid-Wasm as an input precondition. Keep detailed proof-language cases in inline Zig tests and the transaction sequence in the direct JavaScript tests. |
| HTML accessible-name, ID-reference, and unique-ID validators | Valid HTML can fail their semantic document rules. Their output is already unchanged input in several implementations. | Add `commit` for the semantic failure, preserve input in place, and decide separately whether malformed HTML is a precondition violation. |
| WARC broken-link and broken-module-import assertion gates | Valid WARC input can fail the link or module policy after substantial scanning. | Add `commit` for broken-reference summaries while retaining malformed-WARC and internal-capacity traps as precondition or defect paths. |
| DejaVu text-to-path SVG renderers | Valid UTF-8 and valid width, height, and font-size uniforms can exhaust the 8 MiB output. The current renderers then return zero after partial output. They also silently clamp an input size above the advertised 64 KiB cap. | Decide whether capacity truncation is accepted rendering behavior or a recoverable error. If it is an error, add `commit`; if it is truncation, close the SVG normally and document the additional limit. In both cases, trap on oversized host input and reset all three uniforms after every normal render. |
| `components/utf8/text-to-bmp.c` | Valid UTF-8 and valid `cols` and `leading` uniforms can make the calculated BMP exceed the 8 MiB output. The renderer then returns zero. It also silently clamps an input size above the advertised 64 KiB cap. | Add `commit` for output exhaustion, trap on oversized host input, and reset both uniforms after every normal render. |
| SQLite table dump, CSV, and row lookup | Valid SQLite input can produce more output than each component's fixed buffer, and these paths currently return zero after partial output. All three also silently clamp an input size above the advertised 8 MiB cap. | Add `commit` for output exhaustion, trap on oversized host input, and reset table, row, limit, and offset uniforms after every normal render. Keep textual SQLite diagnostics as accepted component output unless the component contract is deliberately changed. |
| PNG, JPEG, GIF, BMP, AVIF, WebP, JP2, SVG, KTX2, ZIP, PDF, TTF, Wasm, JSON, CSS-expression, and similar validators | Their input domain includes arbitrary or broadly encoded bytes and their output establishes a narrower valid format. | Add `commit`, preserve pass-through bytes where possible, and test rejection followed by reuse. |
| Transforms over validated formats | Malformed bytes violate their declared input precondition. | Do not add `commit` only to repeat validation. Replace ambiguous zero-as-failure returns with traps, document the supported profile, and place a validator at untrusted boundaries. |
| Combined validate-and-transform components | They deliberately accept untrusted claimed-format bytes and also perform the transform. | Add `commit` for malformed or unsupported content and keep partial output provisional. |
| Validators and assertion gates | Their purpose includes rejecting values inside their declared input domain. | Replace those `must_trap` cases with `must_reject`; retain traps for calls outside the domain and for defects. |

Confirmed current zero-as-failure examples include:

- `components/image/png/png-to-bmp-b8g8r8a8-srgb.zig`;
- `components/image/jpeg/jpeg-to-bmp-b8g8r8a8-srgb.zig`;
- `components/image/gif/gifsicle-optimize.zig`; and
- `components/image/bmp/bmp-double2.zig`.

Recheck equivalent KTX2-output and C-backed image components added during the
in-progress image migration.

The transaction state itself is small. A simple validator needs one pending
`i64` commit result. `utf8-must-be-valid.zig` already has the current byte index,
so it can report an exact validation offset without a parser redesign. A
validator which already returns an error or zero can first adopt generic
invalid-input rejection and add offsets later.

A transform which requires validated input may wrap a library which aborts on
malformed data. Such a trap is a caller precondition violation or a library
defect, not commit rejection. The host discards the instance and does not read
output. The packaged component should document and test the valid profile it
requires.

### libwebp Snapshot

The current libwebp 1.6.0 decoder can be packaged in either form. A boundary
validator or combined decoder can turn its status results into commit
rejection. A faster downstream decoder can require validated supported WebP.
The artifact is not yet statically certified nontrapping for that domain:

- `WebPGetFeatures` returns `VP8StatusCode`, including bitstream, unsupported,
  memory, parameter, and insufficient-data failures.
- `WebPDecodeRGBAInto` and `WebPDecodeBGRAInto` return `NULL` when the internal
  decode status is not OK.
- The QIP wrapper already converts those results, dimension limits, animation,
  and arena exhaustion to zero output.
- The wrapper resets its complete arena before each render. Existing tests
  reject empty and zero-filled input; another rejects animated input and then
  successfully decodes valid input on the same instance.
- The Makefile builds this library with `-DNDEBUG`, so C `assert` calls are
  removed from this artifact.
- The compiled decoder still contains five explicit Wasm `unreachable`
  instructions. Their presence does not prove malformed input reaches them, but
  it prevents a simple instruction scan from certifying the artifact.

Before migration, choose which domain the component exports. A combined decoder
can add a pending commit result with detail zero and later use the full
`WebPDecode` status API for better classification. A validated-input decoder can
trap on a rejected library status, but its validator must exclude every such
input. Static reachability analysis and format-aware fuzzing must test the
chosen boundary.

### Packaged Library Failure Evidence

Treat failure behavior as a property of the packaged component artifact, not
of the upstream library name. Longer-term component documentation should
record:

- the library version, QIP adapter revision, build flags, and Wasm digest;
- which public status values the adapter converts to commit rejection;
- known abort, trap, allocation, and output-exhaustion paths;
- malformed, truncated, unsupported, and resource-limit corpus results;
- fuzzing scope, duration, sanitizer or instrumentation settings, and saved
  reproducers; and
- whether rejection recovery and same-instance reuse were tested.

Evidence can classify a path as rejected, trapping, or not yet known. “Not yet
known” is acceptable during the alpha migration. Do not turn missing evidence
into a claim that malformed input is safe.

## Uniform Reset Sweep

The first source scan found public uniforms in these non-Interactive groups:

- SQLite row/table components;
- ZIP file extraction;
- TTF-to-SVG path components;
- GIF optimization;
- KTX2 warm-fade;
- SVG rasterization and recoloring;
- CSS expression evaluation;
- currency formatters;
- text-to-image and text-to-path renderers; and
- the RGBA filter WAT components.

Some RGBA modules use the Tile contract rather than Content. Do not silently
change Tile persistence as part of the Content migration; either confirm that
the same reset rule applies to Tile or track those rows separately.

For each updated Content component with uniforms:

- identify and document the authored default for every uniform;
- use the staged value for the current render;
- reset the public value on every normal return from `render`;
- for a failable component, retain only private transaction data needed by
  `commit`;
- test a set/render/render sequence, where the second render observes defaults;
- test reset after accepted empty output; and
- test reset after render marks a transaction invalid and before commit rejects.

## Host And Compliance Follow-Up

- Detect `commit` by export presence during the alpha migration.
- Call `commit` after every normal return from `render` when present. After a
  trap, ignore output and replace the instance without calling `commit`.
- Treat every negative Content result as rejection; log the raw value only as
  optional debug information.
- Add `must_reject` for validator failures inside the declared input domain.
- [Done 2026-08-20] Keep the Compliance bridge stateless. Oracles call
  `set_uniform_u32` immediately before every case that needs a non-default
  value. The currency oracles now do this after each component render resets
  its public uniforms.
- Test valid zero-byte output separately from rejected zero-byte provisional
  output.
- Use `test/lib/content-component-host.mjs` for JavaScript lifecycle tests. It
  keeps an instance after rejection, discards it after a render or commit trap,
  applies uniforms before render, and never exposes provisional rejected output.

## Capacity Profiles To Resolve

Capacity is both a compatibility promise and a resource budget. The repository
currently clusters discretionary input capacities around these candidate
profiles:

| Profile | Capacity | Typical use |
| --- | ---: | --- |
| compact | 1 MiB | Short text, small byte transforms, and bounded utility input |
| document | 16 MiB | Markdown, CSS, JSON, source text, fonts, Wasm, and documents |
| media | 64 MiB | Compressed images and media containers |
| archive | 128 MiB | WARC, TAR, ZIP, and other explicitly large containers |

These are candidate authored defaults, not yet normative limits. Keep an exact
capacity instead when the data model determines it, such as a three-byte
currency code, a fixed digest, a maximum pixel count, an image header plus
pixel bytes, or a proven encoding expansion formula.

Do not use 64 KiB merely because it is one Wasm page. Existing components with
that discretionary cap need either a workload-specific justification or
promotion to the 1 MiB compact profile. A genuinely small grammar should use
its natural exact bound instead of treating 64 KiB as a separate profile.

“Genuinely small” describes the accepted input grammar, not the output. A
component which accepts one currency code, one CSS scalar expression, or one ID
can use a grammar-derived exact capacity. A component which scans prose, source
text, or a document to find that same value uses the appropriate compact or
document profile even when it emits only a few bytes. Exact bounds must come
from the documented grammar or representation, not from a guess about typical
input.

Do not round a derived output capacity merely to match a profile. For example,
Base64 output remains `4 * ceil(input_cap / 3)`, and KTX2 output includes its
exact header and level payload. Standard input profiles make pipeline
compatibility more predictable; exact output bounds preserve useful resource
information.

Before making the profiles normative:

- classify every discretionary capacity and explain exceptions;
- decide whether each profile is a recommendation or a minimum guaranteed by a
  named component contract;
- measure total linear memory after input, output, stack, tables, and scratch;
- test fixed 16 MiB and 64 MiB sentinels only for profiles that include them;
  and
- keep portable Compliance fixtures below the contract's declared minimum,
  rather than matching one implementation's exact capacity.

## Analysis And Test Plan

Use static checks, model-based state tests, differential reuse tests, and fuzzing
together. Fuzzing alone cannot prove nontrapping behavior, a capacity bound, or
an authored uniform default.

### Static Contract Analysis

- Classify the component from its exports: Content has `render`; failable
  Content also has `commit`; Timed adds `begin_at`; Interactive adds events.
- Check exact signatures, static pointer and capacity getters, initial-memory
  ranges, and whether the component accepts UTF-8 or arbitrary bytes.
- Treat `commit` only as evidence that rejection can return normally. Never
  infer that valid calls cannot trap from its presence or absence.
- Accept a no-trap proof only when static analysis covers every core Wasm trap
  under valid host inputs and call order. Bind the
  proof to the digest of the exact Wasm file.
- Reject a `commit` result type narrower than `i64`.
- Check that output capacity can represent the component's proven worst case.
  Treat a reachable “return zero on overflow” branch as a contract mismatch.
- Inventory every public uniform and its authored default. Require permanent
  metadata or a component-specific test fixture when the default cannot be
  discovered mechanically.
- For accepted output, check returned length against capacity and validate UTF-8
  when the component exports `output_utf8_cap`.

Static bytecode inspection can also prove that `commit`, `begin_at`, setters,
and events contain no stores into the declared output range when their address
expressions are simple enough. Dynamic snapshots cover implementations outside
that analyzable subset.

### Model-Based Lifecycle Tests

Drive each reusable instance with generated command sequences and compare its
observable behavior with the transaction state machine. Include these fixed
sequences before fuzzing:

1. valid render, accepted commit, then another valid transaction;
2. invalid render which returns normally, negative commit, then a valid render
   and accepted commit on the same instance;
3. valid empty render and acceptance, distinct from zero returned before
   rejection;
4. repeated rejection and recovery cycles;
5. render twice, setter after render, commit without required render, and other
   illegal phase calls, with `commit` returning a negative protocol diagnostic
   rather than trapping; and
6. output exhaustion at progress counts `0`, `1`, and `UINT32_MAX`, with exact
   encode/decode tests for the signed bitfield; and
7. validation failures at byte zero, in the middle, and at end-of-input, plus a
   parser which can only report generic rejection.

When a component documents a trapping library boundary, add a separate fixture
for it. The fixture proves that the host discards the instance and does not read
output. Do not count that case as rejection recovery; recovery tests begin with
a new instance.

After a trap, discard the instance. Recovery is required after commit rejection,
not after the emergency-stop path.

### Large-Input Sentinels

Add generic size probes in addition to component-specific Compliance cases.
They test different boundaries:

- call `render` with `input_cap + 1` and `UINT32_MAX` when those values exceed
  the advertised cap; require an immediate protocol trap without allocating or
  copying a buffer of that size;
- test 16 MiB and 64 MiB when each value is within the advertised cap; fill
  UTF-8 input with ASCII space and byte input with zero bytes;
- for a component documented to return normally for every allowed input, require these
  in-cap calls to return normally;
- for a component with `commit`, require `render` to return normally and let
  `commit` accept or reject the inert content according to the component's
  grammar; and
- for a documented trapping-library exception, record the trap and discard the
  instance rather than treating it as rejection recovery.

Fixed powers of two exercise signed comparisons, size arithmetic, and hidden
internal limits. They complement exact `input_cap` and `input_cap + 1` tests;
they do not replace them. A component-specific Compliance oracle should carry
the exact expected output or rejection when the inert content has portable
semantic meaning. The generic harness owns protocol-cap traps and should not
make every oracle embed tens of MiB of fixture memory.

### Uniform Reset Tests

Defaults do not need to be readable to test reset. Use a fresh instance as the
differential reference:

1. Render input `A` on a fresh instance without setters and save its output.
2. On another instance, set a non-default value and render any input.
3. Render `A` again on that reused instance without setters.
4. Require the third output to equal the fresh default output byte for byte.

Repeat the sequence with an accepted empty render and with a render which marks
the transaction invalid. After the latter, call `commit`, require rejection,
then render valid input without setters. Cover every uniform type and more than
one uniform so partial reset cannot pass.

For Timed and Interactive components, require all uniforms in each transaction
and compare a reused instance with a replayed fresh-instance trace at the same
epoch and timestamps.

### Output-Mutation Tests

Snapshot the declared output range before and after every call. Uniform setters,
`begin_at`, events, and `commit` must leave every byte unchanged. Only `render`
may alter that range. Scratch memory outside the output range may change.

Rejection always erases output logically: the provisional length and bytes are
invalid and the host must not read or cache them. Physical zeroing is a separate
possible guarantee. Requiring it would add work proportional to prior or
partial output, conflict with components which intentionally share input and
output, and provide little isolation because the host can read all exported
linear memory. It is not part of this proposal and the generic harness must not
test for zero-filled bytes.

Test the host as well as the component: instrument output reads and assert that
the host reads only after an accepted commit, never after a negative result.

### Fuzzing

- Fuzz arbitrary bytes for `input_bytes_cap` components. Generate only valid
  UTF-8 for `input_utf8_cap`, except when testing that the host rejects its own
  precondition before calling Wasm.
- Combine byte mutation with format-aware generators for PNG, JSON, Wasm, ZIP,
  and other structured inputs so coverage reaches late failures after partial
  output.
- Fuzz action sequences, not only single renders: setters, render, commit,
  rejection, reuse, reset, time advance, and events.
- Fill previous output with distinctive data and favor cases which fail after
  substantial processing. This exposes stale-length use and accidental reads
  after rejection without requiring physical zeroing.
- Run the same successful case on fresh and reused instances and compare output
  byte for byte. This detects retained uniforms and unintended hidden state.
- Bound execution with the existing memory, loop, and fuel policies. A timeout,
  unexpected trap, oversized length, invalid UTF-8 output, or illegal output
  mutation is a finding.
- Save and minimize both the input bytes and the action trace. A reproducer must
  include uniform values, transaction times, and whether output was read.

Component-specific Compliance oracles remain necessary for semantic
correctness. The generic harness proves lifecycle and envelope properties; it
cannot prove that a decoded image has the correct pixels or that a formatted
document has the intended meaning.

## Deferred Ideas

- Explore an optional physical output-clearing guarantee if a concrete
  confidentiality or host-integration use case justifies its cost. Any future
  design must define the cleared range, behavior for shared input/output
  buffers, and whether clearing occurs during `render` or instance disposal.

## Audit Limitations

The initial scan looked for traps and common `return 0` forms in Zig, C, and
WAT sources. It does not prove totality, find every library-propagated error, or
classify every current component. Before editing a component, inspect its
complete call graph, capacity arithmetic, MIME promises, Compliance oracle,
and tracked `.wasm` artifact.
