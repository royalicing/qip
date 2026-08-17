<title>QIP Oracles</title>

<style>
  main table {
    width: 100%;
    border-collapse: collapse;
  }

  main th,
  main td {
    border-bottom: 1px solid color-mix(in srgb, currentColor 18%, transparent);
    padding: 0.45rem 0.6rem 0.45rem 0;
    text-align: left;
    vertical-align: top;
  }

  main th:last-child,
  main td:last-child {
    padding-right: 0;
  }
</style>

# QIP Oracles

Compliance oracles are executable test assets packaged as Wasm. An oracle owns
its memory, imports the small `qip` oracle bridge, and declares ordered cases:
this input must render exactly these bytes, this input must trap, or this output
must satisfy a procedural check.

You can use these oracles with `qip comply` against QIP Content components, or
instantiate the same `.wasm` from JavaScript, Go, Rust, Python, or another host
and route the oracle calls to a non-QIP implementation. The implementation does
not need to be Wasm. It only needs an adapter that accepts input bytes and either
returns output bytes or reports a trap-like failure.

```bash
curl -O https://qip.dev/oracles/luhn.comply.wasm
qip comply components/utf8/luhn.wasm --with luhn.comply.wasm
npx qipx comply components/utf8/luhn.wasm --with luhn.comply.wasm
```

For the bridge ABI and authoring rules, see [`qip comply`](/docs/comply).

## General UTF-8 And Text Oracles

| Oracle | Checks | Download | Source |
| --- | --- | --- | --- |
| Preserve empty input | Empty input renders as empty output. | [wasm](/oracles/preserve-empty.wasm) | [wat](/oracles/preserve-empty.wat) |
| Preserve whitespace | Common whitespace inputs pass through unchanged. | [wasm](/oracles/preserve-whitespace.wasm) | [wat](/oracles/preserve-whitespace.wat) |
| Preserve ASCII | Printable ASCII passes through unchanged. | [wasm](/oracles/preserve-ascii.wasm) | [wat](/oracles/preserve-ascii.wat) |
| Trap invalid UTF-8 | Invalid UTF-8 byte sequences trap instead of being repaired silently. | [wasm](/oracles/trap-invalid-utf8.wasm) | [wat](/oracles/trap-invalid-utf8.wat) |
| Trap empty input | Empty input must trap. Useful for validators that require a value. | [wasm](/oracles/trap-empty-input.wasm) | [wat](/oracles/trap-empty-input.wat) |

## Identifiers And Formatting

| Oracle | Checks | Download | Source |
| --- | --- | --- | --- |
| Luhn | Normalized Luhn-valid values pass; invalid values trap. | [wasm](/oracles/luhn.comply.wasm) | [wat](/oracles/luhn.comply.wat) |
| E.164 phone numbers | Phone numbers normalize to E.164 form. | [wasm](/oracles/e164.comply.wasm) | [wat](/oracles/e164.comply.wat) |
| ISO 4217 alpha to numeric | Currency alphabetic codes map to numeric codes. | [wasm](/oracles/iso-4217-alpha-to-numeric.comply.wasm) | [zig](/oracles/iso-4217-alpha-to-numeric.comply.zig) |
| en-US currency | Locale-specific currency formatting. | [wasm](/oracles/currency-format-en-us.comply.wasm) | [zig](/oracles/currency-format-en-us.comply.zig) |
| en-IN currency | Locale-specific currency formatting. | [wasm](/oracles/currency-format-en-in.comply.wasm) | [zig](/oracles/currency-format-en-in.comply.zig) |
| de-DE currency | Locale-specific currency formatting. | [wasm](/oracles/currency-format-de-de.comply.wasm) | [zig](/oracles/currency-format-de-de.comply.zig) |
| fr-FR currency | Locale-specific currency formatting. | [wasm](/oracles/currency-format-fr-fr.comply.wasm) | [zig](/oracles/currency-format-fr-fr.comply.zig) |
| ja-JP currency | Locale-specific currency formatting. | [wasm](/oracles/currency-format-ja-jp.comply.wasm) | [zig](/oracles/currency-format-ja-jp.comply.zig) |

## Unicode And Markdown

| Oracle | Checks | Download | Source |
| --- | --- | --- | --- |
| Unicode 17 uppercase | Default Unicode uppercase mappings. | [wasm](/oracles/unicode-17-uppercase.comply.wasm) | [zig](/oracles/unicode-17-uppercase.comply.zig) |
| Unicode 17 lowercase | Default Unicode lowercase mappings. | [wasm](/oracles/unicode-17-lowercase.comply.wasm) | [zig](/oracles/unicode-17-lowercase.comply.zig) |
| Unicode 17 label casefold | Label-safe Unicode case folding. | [wasm](/oracles/unicode-17-casefold-labels.comply.wasm) | [zig](/oracles/unicode-17-casefold-labels.comply.zig) |
| CommonMark 0.31.2 | The 655 upstream CommonMark examples. | [wasm](/oracles/commonmark-spec-0.31.2.wasm) | [zig](/oracles/commonmark-spec-0.31.2.zig) |
| GFM additions | GitHub Flavored Markdown behavior covered by local fixtures. | [wasm](/oracles/commonmark-0.31.2-gfm.wasm) | [zig](/oracles/commonmark-0.31.2-gfm.zig) |
| CommonMark differential corpus | Minimized Markdown inputs that catch renderer differences. | [wasm](/oracles/commonmark-differential-corpus.comply.wasm) | [zig](/oracles/commonmark-differential-corpus.comply.zig) |
| HTML5 entities | Entity decoding behavior inside rendered HTML. | [wasm](/oracles/html5-entities.comply.wasm) | [zig](/oracles/html5-entities.comply.zig) |

## Documents, Images, And Web Formats

| Oracle | Checks | Download | Source |
| --- | --- | --- | --- |
| SVG to data URI | SVG bytes encode to a safe data URI form. | [wasm](/oracles/svg-to-data-uri.comply.wasm) | [zig](/oracles/svg-to-data-uri.comply.zig) |
| Data URI to CSS URL | Data URIs wrap correctly for CSS `url(...)`. | [wasm](/oracles/data-uri-to-css-url.comply.wasm) | [zig](/oracles/data-uri-to-css-url.comply.zig) |
| Mermaid to Unicode HTML | Strict Mermaid subset renders to Unicode diagram HTML. | [wasm](/oracles/mermaid-to-unicode-html.comply.wasm) | [zig](/oracles/mermaid-to-unicode-html.comply.zig) |
| JPEG to BMP BGRA32 | Baseline JPEG decodes to canonical 32-bit BGRA BMP. | [wasm](/oracles/jpeg-to-bmp-bgra32.comply.wasm) | [zig](/oracles/jpeg-to-bmp-bgra32.comply.zig) |
| BMP BGRA32 ICC to sRGB | 32-bit BGRA BMP color conversion contract. | [wasm](/oracles/bmp-bgra32-icc-to-srgb.comply.wasm) | [zig](/oracles/bmp-bgra32-icc-to-srgb.comply.zig) |
| WARC connected search params | WARC recipe behavior for connected search parameters. | [wasm](/oracles/warc-connect-search-params.comply.wasm) | [zig](/oracles/warc-connect-search-params.comply.zig) |

## Syntax Highlighting

These oracles check representative highlighted HTML output for language-specific
syntax highlighters.

| Language | Download | Source |
| --- | --- | --- |
| Bash | [wasm](/oracles/syntax-highlight-bash.comply.wasm) | [zig](/oracles/syntax-highlight-bash.comply.zig) |
| C | [wasm](/oracles/syntax-highlight-c.comply.wasm) | [zig](/oracles/syntax-highlight-c.comply.zig) |
| C# | [wasm](/oracles/syntax-highlight-csharp.comply.wasm) | [zig](/oracles/syntax-highlight-csharp.comply.zig) |
| CSS | [wasm](/oracles/syntax-highlight-css.comply.wasm) | [zig](/oracles/syntax-highlight-css.comply.zig) |
| Go | [wasm](/oracles/syntax-highlight-go.comply.wasm) | [zig](/oracles/syntax-highlight-go.comply.zig) |
| HTML | [wasm](/oracles/syntax-highlight-html.comply.wasm) | [zig](/oracles/syntax-highlight-html.comply.zig) |
| Java | [wasm](/oracles/syntax-highlight-java.comply.wasm) | [zig](/oracles/syntax-highlight-java.comply.zig) |
| JavaScript | [wasm](/oracles/syntax-highlight-javascript.comply.wasm) | [zig](/oracles/syntax-highlight-javascript.comply.zig) |
| Python | [wasm](/oracles/syntax-highlight-python.comply.wasm) | [zig](/oracles/syntax-highlight-python.comply.zig) |
| Ruby | [wasm](/oracles/syntax-highlight-ruby.comply.wasm) | [zig](/oracles/syntax-highlight-ruby.comply.zig) |
| Swift | [wasm](/oracles/syntax-highlight-swift.comply.wasm) | [zig](/oracles/syntax-highlight-swift.comply.zig) |
| Wasm text | [wasm](/oracles/syntax-highlight-wasm.comply.wasm) | [zig](/oracles/syntax-highlight-wasm.comply.zig) |
| Zig | [wasm](/oracles/syntax-highlight-zig.comply.wasm) | [zig](/oracles/syntax-highlight-zig.comply.zig) |
