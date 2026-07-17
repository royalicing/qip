# Router Specification

The qip router is a deterministic specification for turning a content tree into HTTP responses. We prefer a small set of explicit routing rules because site authors, recipe authors, and export tooling should all be able to predict the same response for the same input files.

This document is normative for `qip router`, including `qip router dev`.

## Site Root

`qip router dev` and the other `qip router` subcommands take one site root. The site root is the directory or remote snapshot qip routes from.

The preferred local layout is:

```txt
site/
  index.md
  docs/router.md
  _recipes/
    text/markdown/10-markdown-basic.wasm
    application/warc/20-check-links.wasm
  _components/
    form/contact.wasm
    interactive/side-scroller-platformer.wasm
  _elements/
    qip-edit.js
```

The site root may also be a GitHub locator such as `github:owner/repo/subdir`. GitHub content roots must resolve to one repository snapshot, and a single runtime load must read all content from that snapshot.

## Project Directories

qip reserves three exact top-level directory names:

- `_recipes`: content and archive recipe components
- `_components`: browser-loadable QIP components
- `_elements`: browser custom-element modules

Reserved project directories must not be routed as content. Other underscore paths, such as `_og/card.png`, are ordinary content unless a future spec reserves them.

qip auto-discovers these project directories under the site root:

| Role | Default directory | Override flag |
| --- | --- | --- |
| Recipes | `<site>/_recipes` | `--recipes <dir>` |
| Components | `<site>/_components` | `--components <dir>` |
| Elements | `<site>/_elements` | none |

The recipe and component flags override auto-discovery. Element modules always belong to the site because they define site-owned browser behavior. This keeps the common command short while allowing shared recipe and component directories:

```sh
qip router dev ./site
qip router dev ./site --recipes ../shared-recipes
```

Local project directories may be real directories or symlinks. Symlinks are the preferred way to share recipes across sites without introducing a config file. Remote object stores such as S3 do not have symlinks, so shared project directories must be copied or handled by future remote-root support.

Nested `_recipes`, `_components`, and `_elements` directories are reserved for future path-scoped behavior. qip must not use nested project directories in this version.

## Request Paths

Request paths must be canonicalized before route lookup.

- An empty path must become `/`.
- A path without a leading slash must be treated as if it had one.
- Dot segments must be cleaned with URL-path semantics.
- qip currently uses no trailing slash as the canonical form. `/docs/` must redirect to `/docs`.
- A canonicalization redirect must preserve the query string.

The router should not allow two different content files to claim the same request path. If route construction finds a duplicate path for different files, it must fail before serving.

## File Paths

Content files are discovered by walking the site root.

- Regular files must be routable.
- Directories must be walked recursively.
- Symlinks may point at regular files or directories.
- Symlink cycles must not recurse forever.
- Top-level qip-reserved project directories must be skipped.
- Content paths must be valid UTF-8.
- Content paths must not start with `/`.
- Content paths must not contain backslashes.
- Content paths must already be clean relative paths; `.` and `..` forms must be rejected.

These rules keep file paths portable and make route generation reviewable.

## File To Route Mapping

Every content file must receive a source route:

```txt
site root:    site/
file:         docs/router.md
source route: /docs/router.md
```

Some file types also receive a pretty route:

| File extension | Pretty route rule |
| --- | --- |
| `.html` | remove the extension |
| `.md` | remove the extension |
| `.markdown` | remove the extension |
| `.uri` | remove the extension |
| `.uris` | remove the extension |

Example:

```txt
site/docs/router.md -> /docs/router.md and /docs/router
```

Other file types should not receive a pretty route. They are served only at their source route.

## Parent Pages

An `index` file defines the page for its parent path. This is how qip represents directory-level pages without inventing a separate directory object.

Examples:

```txt
site/index.md          -> /index.md and /
site/docs/index.md     -> /docs/index.md and /docs
site/docs/reference.md -> /docs/reference.md and /docs/reference
```

The canonical parent path must not end in `/` under the current trailing-slash policy. A request for `/docs/` must redirect to `/docs`.

Parent pages also matter for WARC-level context. When an application-WARC recipe transforms `/docs/reference`, qip may provide context records for `/` and `/docs` if those paths resolve to HTML pages. Recipe authors should treat those records as context, not as the target response.

## Source MIME

The router determines source MIME from the file extension.

- `.md` and `.markdown` must be `text/markdown`.
- `.uri` and `.uris` must be `text/uri-list`.
- Other extensions should use the platform MIME table.
- Unknown extensions must fall back to `application/octet-stream`.
- MIME parameters from platform lookup should be stripped for route matching.

The source MIME selects content recipes. The response MIME may differ after transformation.

## Redirect Files

Files with source MIME `text/uri-list` are redirects.

The router must read the first non-empty, non-comment line as the redirect target.

- A leading UTF-8 byte-order mark on the first line must be ignored.
- Blank lines must be ignored.
- Lines starting with `#` must be ignored.
- The first remaining line must become the `Location` header.
- The response status must be `302 Found`.
- Content recipes must not run for redirect files.

Example:

```txt
# site/start.uri
/docs/how-it-works
```

This creates `/start.uri` and `/start`; both resolve to a redirect with `Location: /docs/how-it-works`.

## Content Recipes

Content recipes transform individual content responses. They are discovered under:

```txt
site/_recipes/<type>/<subtype>/*.wasm
```

For example, `site/_recipes/text/markdown/*.wasm` applies to content whose source MIME is `text/markdown`. If `--recipes <dir>` is provided, qip must use `<dir>/<type>/<subtype>/*.wasm` instead.

Recipe files must have a numeric order prefix, such as `11-autolink-https.wasm`. qip must order recipe steps by numeric prefix, then by filename. Duplicate numeric prefixes within one MIME recipe chain must fail route loading. A leading `-` disables a recipe file.

Content recipe selection must be based on source MIME, not on the request path extension or output MIME.

Markdown has one special rule:

- Markdown pretty routes such as `/docs/router` should run `text/markdown` recipes.
- Markdown source routes such as `/docs/router.md` must not run `text/markdown` recipes.

This preserves a raw source URL while still giving authors a clean page URL.

For other MIME types, if a recipe chain exists for the source MIME, the chain should run for the routed content response.

When a recipe chain runs for `text/markdown`, qip currently treats the response as `text/html; charset=utf-8`. Recipe modules should still declare their output content type when a different result is intended.

Nested recipe roots are not active in this version. A file at `site/docs/_recipes/text/markdown/40-docs-sidebar.wasm` must not affect `/docs/router`. If path-scoped recipes are added later, they should merge by numeric prefix and should keep duplicate-prefix failures.

## Form Elements

`<qip-form>` is an ordinary site-owned custom element. It declares its Wasm dependency with exactly one direct `<source>`:

```html
<qip-form>
  <source src="/components/form/contact.wasm" type="application/wasm">
</qip-form>
```

The element module at `/elements/qip-form.js` fetches and instantiates that component. The Router does not interpret the form markup, embed module bytes, or maintain a separate form namespace. Missing sources and incompatible modules fail in the element at activation time.

## Component Assets

`.wasm` files under `site/_components`, or under `--components <dir>` when provided, must be served as browser-loadable QIP component assets at:

```txt
/components/<relative-path>.wasm
```

Component asset paths must be valid UTF-8, clean relative paths, and must not start with `/`. Non-`.wasm` files in the component root should be ignored.

Component assets must use `application/wasm`. They are not content pages and should not run content recipes.

## Element Modules

JavaScript files under `site/_elements` are served at matching paths under `/elements`:

```txt
site/_elements/qip-edit.js   -> /elements/qip-edit.js
site/_elements/lib/dom.js   -> /elements/lib/dom.js
```

Each file runs the site's `text/javascript` recipe chain before it is served or archived. This is where a site can minify, check, or otherwise transform its custom-element code.

A top-level filename containing a hyphen is an element entrypoint: `copy-code.js` corresponds to `<copy-code>`. Nested files remain importable dependencies but do not imply custom-element names. The router only provides the routes; selective script insertion is performed by an application-WARC recipe such as `warc-add-custom-element-scripts.wasm`.

## Application WARC Recipes

`site/_recipes/application/warc/*.wasm` is the archive-level recipe layer. It works on WARC records, not raw page bodies. If `--recipes <dir>` is provided, qip must use `<dir>/application/warc/*.wasm` instead.

In `qip router warc`, qip must:

1. Enumerate routed content, component asset, and element module paths.
2. Resolve each path to an HTTP response.
3. Build a WARC response record for each response.
4. Run the `application/warc` recipe chain over the whole archive, if one exists.
5. Emit the resulting WARC bytes.

In `qip router dev`, `qip router get`, and `qip router head`, qip should apply the same WARC recipe layer to the single requested response so local preview matches archive export.

### Kindred Routes

For a single-response WARC transformation, qip adds the target's kindred routes before its record. These are its parent pages and the sibling resources connected through `src`:

- `/`
- each parent page path of the target, such as `/docs` for `/docs/router`
- static assets referenced by any `src` attribute in the target HTML
- transformed top-level element entrypoints, so WARC recipes can selectively load them

Parent pages must be `200 OK` HTML. They let WARC recipes copy navigation and other shared structure into descendant pages, serving a role similar to layouts in other routers.

The shallow `src` scan follows browser URL resolution and ignores comments and raw text such as script bodies. It includes site-relative, non-HTML files served directly from the filesystem without a content recipe; component WASM files qualify. HTML, redirects, missing or external targets, synthetic routes, and recipe-transformed content are ignored. Paths are deduplicated after dropping queries and fragments, referenced assets are not scanned recursively, and a page may contribute at most 256 unique paths.

These rules give WARC recipes access to direct static dependencies without turning a single-route request into a whole-site build.

The target response must be selected from the transformed WARC by exact target URI.

## Route Listing

`qip router list` must list all routable content paths and component asset paths known before WARC recipe synthesis.

Each listed route must include:

- method: `GET` and `HEAD`
- request path
- media type without parameters

`qip router list` should not list routes synthesized only by an `application/warc` recipe, because those routes are created after the content router has already enumerated the base site.

## Commands

`qip router dev <content_dir> ...` must serve the same route resolution pipeline used by other router subcommands. In dev mode, it should reload recipe chains on recipe file changes, SIGHUP, or browser hard reload.

`qip router get <content_dir> <path> ...` must resolve one path through the dev-route pipeline and write the response body.

`qip router head <content_dir> <path> ...` must resolve one path through the dev-route pipeline and write headers/log output without a response body.

`qip router list <content_dir> ...` must print the base route table.

`qip router warc <content_dir> ...` must emit a WARC archive. If `--view-source` is set, qip must also add recipe source and view-source records so downstream tools can inspect the transformation inputs.

The project directory flags are overrides, not requirements:

```sh
qip router dev ./site
qip router get ./site /docs/router
qip router warc ./site --view-source
qip router warc ./site --recipes ../shared-recipes --components ../shared-components
```

## When Not To Use The Router

Do not use the router for ad hoc byte processing. Use `qip run` when you have a direct input-to-output component pipeline and no request paths.

Do not use content recipes for site-wide checks such as broken-link validation. Use `application/warc` recipes because they can see the routed archive as a whole.
