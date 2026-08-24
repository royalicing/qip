<title>Text content components</title>

# Text content components

These components accept a `text/*` MIME type. Common day-to-day formats come first. Download a `.wasm` file and run it with [`qip run`](/docs/qip-cli), or combine compatible inputs and outputs with the [recipe finder](/recipes).

## Markdown (`text/markdown`)

- [`gfm-commonmark.0.31.2.wasm`](/components/text/markdown/gfm-commonmark.0.31.2.wasm) renders GitHub Flavored Markdown on top of CommonMark 0.31.2.
- [`commonmark.0.31.2.wasm`](/components/text/markdown/commonmark.0.31.2.wasm) renders CommonMark 0.31.2 as HTML.
- [`extract-title-text.wasm`](/components/text/markdown/extract-title-text.wasm) extracts plain text from the first Markdown heading.
- [`markdown-basic.wasm`](/components/text/markdown/markdown-basic.wasm) renders the repository's smaller basic Markdown subset as HTML.

Related tool: [Markdown to HTML](/markdown-to-html).

## HTML (`text/html`)

### Transform

- [`html-accessible-name-unique-validator.wasm`](/components/text/html/html-accessible-name-unique-validator.wasm) rejects duplicate accessible names in the supported interactive-element subset.
- [`html-add-highlight-stylesheet-night-owl.wasm`](/components/text/html/html-add-highlight-stylesheet-night-owl.wasm) adds the Night Owl syntax-highlight stylesheet.
- [`html-link-extractor.wasm`](/components/text/html/html-link-extractor.wasm) replaces each absolute HTTPS link with a line containing that URL.
- [`html-page-wrap.wasm`](/components/text/html/html-page-wrap.wasm) wraps an HTML fragment in the repository's page shell.
- [`html-to-accessibility-tree.wasm`](/components/text/html/html-to-accessibility-tree.wasm) renders supported HTML as a Markdown accessibility tree.
- [`html-id-reference-validator.wasm`](/components/text/html/html-id-reference-validator.wasm) rejects same-document ID references that do not resolve to a valid target.
- [`html-unique-id-validator.wasm`](/components/text/html/html-unique-id-validator.wasm) rejects duplicate `id` values.
- [`html-wcag-contrast-aa.wasm`](/components/text/html/html-wcag-contrast-aa.wasm) checks supported foreground and background colors against WCAG AA contrast thresholds.

### Syntax highlight

These components highlight matching fenced code blocks and return `text/html`:

- [`html-code-syntax-highlight-bash.wasm`](/components/text/html/html-code-syntax-highlight-bash.wasm)
- [`html-code-syntax-highlight-c.wasm`](/components/text/html/html-code-syntax-highlight-c.wasm)
- [`html-code-syntax-highlight-css.wasm`](/components/text/html/html-code-syntax-highlight-css.wasm)
- [`html-code-syntax-highlight-go.wasm`](/components/text/html/html-code-syntax-highlight-go.wasm)
- [`html-code-syntax-highlight-html.wasm`](/components/text/html/html-code-syntax-highlight-html.wasm)
- [`html-code-syntax-highlight-ruby.wasm`](/components/text/html/html-code-syntax-highlight-ruby.wasm)
- [`html-code-syntax-highlight-swift.wasm`](/components/text/html/html-code-syntax-highlight-swift.wasm)
- [`html-code-syntax-highlight-tsx.wasm`](/components/text/html/html-code-syntax-highlight-tsx.wasm)
- [`html-code-syntax-highlight-wasm.wasm`](/components/text/html/html-code-syntax-highlight-wasm.wasm)
- [`html-code-syntax-highlight-zig.wasm`](/components/text/html/html-code-syntax-highlight-zig.wasm)

Related tools: [syntax highlighter](/syntax-highlight) and [HTML accessibility tree](/accessibility-tree).

## CSS (`text/css`)

- [`css-minify.wasm`](/components/text/css/css-minify.wasm) removes comments and unnecessary whitespace. It returns `text/css`.

Related tools: [CSS minifier](/css-minifier) and [CSS expression calculator](/css-expression-calculator).

## URI list (`text/uri-list`)

- [`data-uri-to-css-url.wasm`](/components/text/uri-list/data-uri-to-css-url.wasm) wraps a data URI for use as a CSS `url()` value.
- [`url-to-qr-svg.wasm`](/components/text/uri-list/url-to-qr-svg.wasm) renders one URL as an SVG QR code.

Related tools: [QR code maker](/qr) and [SVG data URI](/svg-data-uri).

## Mermaid (`text/vnd.mermaid`)

- [`mermaid-to-unicode-html.wasm`](/components/text/vnd.mermaid/mermaid-to-unicode-html.wasm) renders the supported Mermaid subset as Unicode box art in HTML.

Related tool: [Mermaid to Unicode box art](/mermaid).

## JavaScript (`text/javascript`)

- [`js-to-bmp.wasm`](/components/text/javascript/js-to-bmp.wasm) renders the supported JavaScript syntax subset to a BMP image.
- [`js-to-bmp2.wasm`](/components/text/javascript/js-to-bmp2.wasm) provides the newer Zig implementation of the same JavaScript-to-BMP pipeline.

## CSV (`text/csv`)

- [`content-recipe-to-browser-javascript.wasm`](/components/text/csv/content-recipe-to-browser-javascript.wasm) turns a component-recipe CSV row into browser JavaScript. It returns `text/javascript`.

Related tool: [component recipe finder](/recipes).

## C source (`text/x-c`)

- [`c-to-bmp.wasm`](/components/text/x-c/c-to-bmp.wasm) renders the supported C syntax subset to a BMP image.

Looking for raster formats instead? See the [image content components](/image).
