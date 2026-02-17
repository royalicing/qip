# Visitor Web Router ABI v0

This document freezes the **web-request-router** ABI contract for Visitor Router v0.

Go implementation for this ABI contract lives under `internal/routerabi`.

## Required Exports

All exports below are required and use Wasm `i32` values for pointers, lengths, counts, and status codes.

| Export name | Kind | Signature |
| --- | --- | --- |
| `memory` | memory | linear memory |
| `input_ptr` | function | `() -> i32` |
| `input_cap` | function | `() -> i32` |
| `route` | function | `(path_len: i32, query_len: i32) -> i32` |
| `etag_ptr` | function | `() -> i32` |
| `etag_len` | function | `() -> i32` |
| `content_type_ptr` | function | `() -> i32` |
| `content_type_len` | function | `() -> i32` |
| `content_sha256_ptr` | function | `() -> i32` |
| `content_sha256_count` | function | `() -> i32` |
| `recipe_sha256_ptr` | function | `() -> i32` |
| `recipe_sha256_count` | function | `() -> i32` |
| `location_ptr` | function | `() -> i32` |
| `location_len` | function | `() -> i32` |

## Input Buffer Layout

At `input_ptr`:

- `path_bytes | query_bytes` (UTF-8 bytes only)
- `route(path_len, query_len)` receives lengths only
- Host writes exactly `path_len + query_len` bytes
- `path_len + query_len` must be `<= input_cap`

## Route Semantics

1. Host calls `status := route(path_len, query_len)`.
2. If `300 <= status <= 399`: response is a redirect and `location_len > 0` is required.
3. If `status >= 400`: response is an error.
4. Otherwise: response body is resolved from `content[]` digests folded through `recipes[]` digests.

## Host Invariants (Must Enforce)

The host must validate all exported pointer/length/count outputs before reading bytes:

- all pointer+len reads must stay in wasm memory bounds
- `content_sha256_count >= 0`
- `recipe_sha256_count >= 0`
- digest arrays are exactly `count * 32` bytes
- for 3xx responses, `location_len > 0`

Digest shape:

- `content_sha256_ptr` points to `content_sha256_count` consecutive SHA-256 digests
- `recipe_sha256_ptr` points to `recipe_sha256_count` consecutive SHA-256 digests
- each digest is 32 bytes

## Reference Fixture

Reference fixture spec is in:

- `fixtures/visitor_router_v0_reference.json`
