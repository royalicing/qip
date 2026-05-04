# Router

This page is for site authors using `qip router` and `qip dev`.

It explains:

- where files should go
- what each command does
- what runs when (content recipes vs WARC recipes)

## Project Layout

Typical setup:

```txt
site/                         # content root
  index.md

docs/                         # optional additional content root
  index.md
  how-it-works.md
  module-contract.md

recipes/                      # optional recipe root
  text/markdown/10-...wasm
  text/markdown/80-...wasm
  application/warc/10-...wasm

modules/                      # optional browser/module asset root
  utf8/trim.wasm
  application/warc/warc-check-broken-links.wasm

modules/form/                 # optional form module root
  contact.wasm
```

Related references:

- [Content Layout](/docs/content)
- [Recipe Layout](/docs/recipes)

## Content Roots: Local or GitHub

`<content_dir>` can be either:

- local directory path (existing behavior), for example `./site`
- GitHub repo locator, for example `github:cool-calm/collected-press/site`

For GitHub roots, qip uses a two-step flow:

1. Fetch repo HEAD SHA (git `info/refs` style endpoint).
2. Fetch file bytes from GitHub raw CDN pinned to that SHA.

That means each runtime load is immutable once resolved: all content in that run comes from one commit SHA.

Examples:

```sh
qip dev github:cool-calm/collected-press/site --recipes ./recipes --modules ./modules
qip router get github:cool-calm/collected-press/site /docs/how-it-works --recipes ./recipes
qip router warc github:cool-calm/collected-press/site --recipes ./recipes > site.warc
```

## Route Behavior

Given a content file like `site/docs/module-contract.md`, qip routes:

- pretty URL: `/docs/module-contract`
- source URL: `/docs/module-contract.md`

Common behavior:

- pretty URLs are where markdown recipes usually run (for HTML output)
- source URLs intentionally remain raw source (for example raw markdown)

## Redirect Files (`.uri` / `.uris`)

We prefer file-based redirects because they are explicit, versioned, and easy to review.

If a content file ends with `.uri` or `.uris`, qip serves that route as `302 Found` using the first redirect target from a `text/uri-list` payload.

- comments (lines starting with `#`) are ignored
- blank lines are ignored
- first non-comment line wins
- target can be an absolute URL or a path

Example:

```txt
# site/how-it-works.uri
/docs/how-it-works
```

This gives you:

- source path: `/how-it-works.uri`
- pretty path: `/how-it-works`
- response: `302` with `Location: /docs/how-it-works`

## What Runs When

### `qip dev <content_dir> ...`

Per request:

1. Resolve request path to a content file or module asset.
2. For content pages, run matching content recipes (for example `recipes/text/markdown/*`).
3. If response is HTML, inject runtime support for `<qip-form>` and `<qip-preview>`.
4. If `recipes/application/warc/*` exists, apply that WARC recipe layer to this page response too.
5. Serve the final response.

Result: preview in dev matches route-archive behavior for WARC-level transforms.

### `qip router get <content_dir> <path> ...`

Runs the same page pipeline as dev for one path and prints the response body.

### `qip router head <content_dir> <path> ...`

Runs the same route pipeline but returns headers only.

### `qip router list <content_dir> ...`

Lists all routed paths and content types.

### `qip router warc <content_dir> ...`

1. Enumerate all routed paths.
2. Resolve each path to a response.
3. Build one WARC archive from those responses.
4. If `recipes/application/warc/*` exists, run it over the archive.
5. Emit final WARC bytes.

If `--view-source` is used, source artifacts are added as extra WARC records.

## Recipe Layers

There are two independent recipe layers:

- content layer: `recipes/<mime-type>/...`
- examples: `recipes/text/markdown/*`, `recipes/text/html/*`
- runs when rendering each page

- archive layer: `recipes/application/warc/...`
- runs on WARC output
- also applied in dev per page so behavior stays consistent

## Practical Build Pattern

Static export usually looks like:

1. `qip router warc ./site --recipes recipes --forms modules/form --modules modules`
2. pipe WARC into archive-processing modules (for checks or export)

Example pipeline:

```sh
qip router warc ./site --recipes recipes --forms modules/form --modules modules \
  | qip run modules/application/warc/warc-check-broken-links.wasm \
           modules/application/warc/warc-to-static-tar-no-trailing-slash.wasm
```

In this model:

- page transforms belong in `recipes/text/...`
- site-wide WARC transforms belong in `recipes/application/warc/...`
