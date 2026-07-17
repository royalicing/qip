# Recipes

This document defines how recipe QIP components are discovered from disk.

## Root

- Recipe root directory is discovered from the site root as `_recipes` by default.
- `--recipes <dir>` overrides discovery for shared or unusual layouts.
- Recipes are grouped by exact MIME type:
  - `_recipes/text/markdown/`
  - `_recipes/text/html/`
  - `_recipes/text/javascript/`
  - `_recipes/image/png/`
  - `_recipes/application/warc/`

Given MIME `type/subtype`, recipe directory is:

- `<recipe-root>/<type>/<subtype>/`

## WARC Recipes

`application/warc` recipes run at the whole-site layer instead of one page at a time. You can use them for site-wide transforms, such as adding trailing-slash redirects, verifying there are no broken links, or using the path to modify body content.

- Directory: `_recipes/application/warc/`
- Typical use:
  - link integrity checks on the full routed archive
  - JavaScript module import checks across rendered HTML
  - archive rewrites before export (for example tar/static packaging pipelines)
- Example filenames:
  - `10-warc-check-broken-links.wasm`
  - `20-warc-check-broken-module-imports.wasm`
  - `30-warc-to-sitemap.wasm`
  - `40-warc-add-open-graph-image-meta.wasm`

### Debugging broken links

`warc-check-broken-links.wasm` traps when an internal HTML link does not resolve. To inspect the failures, run the same archive through `warc-extract-broken-links.wasm`:

```sh
qip router warc ./site --view-source \
  | qip run components/application/warc/warc-extract-broken-links.wasm
```

The result is another `application/warc` archive. It keeps only response pages containing broken links and reduces each HTML body to the exact opening tags with broken `href`, `src`, `action`, `data`, or `srcset` values. An archive with no broken links produces an empty WARC.

### Rendering referenced content sizes

`recipes/application/warc/25-add-content-size.wasm` fills
`<qip-content-size>` elements from the response body stored at an absolute
site path:

```html
<qip-content-size src="/components/example.wasm"></qip-content-size>
```

Bodies below 1,000 bytes render as bytes. Larger bodies render as decimal
kilobytes with two fractional digits. The recipe updates the enclosing HTTP
and WARC content lengths. During single-route development, the router adds
direct static `src` dependencies to the subset WARC. An unresolved size path
is an error instead of producing a plausible size.

### Loading custom elements selectively

`components/application/warc/warc-add-custom-element-scripts.wasm` connects element routes to the pages that use them. It discovers top-level `/elements/<tag-name>.js` responses in the archive, detects matching custom-element tags in each HTML response, and inserts one external module script per used element:

```html
<script type="module" src="/elements/qip-edit.js"></script>
```

The recipe ignores tag-shaped text in comments, `script`, `style`, `textarea`, and `title` content. Existing scripts are not inserted again. Nested routes such as `/elements/lib/shared.js` remain available to imports but are not treated as entrypoints.

Run this recipe late in the WARC chain so it sees elements introduced by earlier transforms. This repository links it as `99-add-custom-element-scripts.wasm`. During single-route development, the router includes transformed top-level element modules in the subset WARC so discovery has the same inputs as a whole-site export.

## Execution Context

WARC recipes can run in two useful scopes. Pick the scope based on the question you are answering.

- Subset/path scope (faster iteration):
  - `qip router dev` applies WARC recipe behavior on the currently resolved response.
  - `qip router get` / `qip router head` let you inspect one routed path.
- Whole-site scope (final archive behavior):
  - `qip router warc <site> ...` enumerates the full routed site, builds one WARC, then applies `_recipes/application/warc/*`.

Use subset scope while developing recipe logic. Use whole-site scope before publishing so final archive semantics are still exercised.

```sh
# Fast single-path iteration:
qip router get ./site /docs/router

# Final whole-site run:
qip router warc ./site
```

## Host And URLs

`qip router warc` controls canonical route host via `--host <host>`. We prefer setting this explicitly for production builds so recipe logic that reads target URLs sees stable, deploy-intended origins.

Example:

```sh
qip router warc ./site --host https://qip.dev
```

## Adding Routes

WARC recipes can synthesize or rewrite archive records, which means they can add output routes (for example `/sitemap.xml`) when they emit additional WARC records.

- In this repo, route assets like `/favicon.ico` and `/robots.txt` are present in the content/static output.
- WARC QIP components such as `components/application/warc/warc-to-sitemap.wasm` show the pattern for deriving site-wide artifacts from the archive.

## Ordering

- Recipe execution order is determined by a required two-digit prefix.
- Prefix range is `00` to `99`.
- Lower number runs first.

Filename format:

- `NN-name.wasm`
- `NN` is two ASCII digits.
- `name` is ASCII-only.

Disabled filename format:

- `-NN-name.wasm`
- Leading `-` means the recipe is disabled and must be ignored.
- Example: `-10-normalize.wasm`

Examples:

- `10-normalize.wasm`
- `20-markdown-render.wasm`
- `90-html-wrap.wasm`
- `-10-normalize.wasm` (disabled)

## Tie-Breaking

- Primary sort: numeric prefix ascending.
- Secondary sort: full filename lexicographic ascending.

## Validation

Host should reject recipe entries if:

- filename is non-ASCII
- filename does not match either `NN-name.wasm` or `-NN-name.wasm`

Host should ignore non-`.wasm` files in the recipes tree.

## Scope

- This contract only defines recipe discovery and order.
- Which MIME type applies to a content file is determined by routing/build logic.
- Nested `_recipes` directories are reserved for future path-scoped recipes and are not active in this version.
