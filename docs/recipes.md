# Recipes

This document defines how recipe modules are discovered from disk.

## Root

- Recipe root directory is provided by the host (for example `qip dev ./docs --recipes ./recipes`).
- Recipes are grouped by exact MIME type:
  - `recipes/text/markdown/`
  - `recipes/text/html/`
  - `recipes/image/png/`
  - `recipes/application/warc/`

Given MIME `type/subtype`, recipe directory is:

- `recipes/<type>/<subtype>/`

No wildcard fallback is defined in v0.

## WARC Recipes

`application/warc` recipes are first-class in v0. We prefer them for site-wide archive transforms because they run at the archive layer instead of one page at a time.

- Directory: `recipes/application/warc/`
- Typical use:
  - link integrity checks on the full routed archive
  - archive rewrites before export (for example tar/static packaging pipelines)
- Example filenames:
  - `10-warc-check-broken-links.wasm`
  - `20-warc-to-sitemap.wasm`
  - `30-warc-add-open-graph-image-meta.wasm`

## Execution Context

WARC recipes can run in two useful scopes. We prefer picking scope intentionally because it changes cost and feedback speed.

- Subset/path scope (faster iteration):
  - `qip dev` applies WARC recipe behavior on the currently resolved response.
  - `qip router get` / `qip router head` let you inspect one routed path.
- Whole-site scope (final archive behavior):
  - `qip router warc <content_dir> ...` enumerates the full routed site, builds one WARC, then applies `recipes/application/warc/*`.

Claim: use subset scope while developing recipe logic, and whole-site scope before publishing.
Reason: it shortens edit-test cycles without skipping the final archive semantics.
Example:

```sh
# Fast single-path iteration:
qip router get ./site /docs/router --recipes ./recipes

# Final whole-site run:
qip router warc ./site --recipes ./recipes --modules ./modules
```

## Host And URLs

`qip router warc` controls canonical route host via `--host <host>`. We prefer setting this explicitly for production builds so recipe logic that reads target URLs sees stable, deploy-intended origins.

Example:

```sh
qip router warc ./site --recipes ./recipes --host https://qip.dev
```

## Adding Routes

WARC recipes can synthesize or rewrite archive records, which means they can add output routes (for example `/sitemap.xml`) when they emit additional WARC records.

- In this repo, route assets like `/favicon.ico` and `/robots.txt` are present in the content/static output.
- WARC modules such as `modules/application/warc/warc-to-sitemap.wasm` show the pattern for deriving site-wide artifacts from the archive.

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
