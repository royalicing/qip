# Recipe Layout v0

This document defines how recipe modules are discovered from disk.

## Root

- Recipe root directory is provided by the host (for example `qip dev ./docs --recipes ./recipes`).
- Recipes are grouped by exact MIME type:
  - `recipes/text/markdown/`
  - `recipes/text/html/`
  - `recipes/image/png/`

Given MIME `type/subtype`, recipe directory is:

- `recipes/<type>/<subtype>/`

No wildcard fallback is defined in v0.

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
