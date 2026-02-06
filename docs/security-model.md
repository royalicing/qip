# Security Model

This document describes the current security boundaries of `qip` as implemented today.

## Threat Model

`qip` is designed to run untrusted WebAssembly modules with a narrow host interface.

Primary concern:

- Untrusted module bytes (local or remote) may be malicious or buggy.

## Isolation Boundary

Modules execute inside `wazero` and interact with the host only through exported function calls and linear memory.

Current host behavior:

- `qip` does not provide WASI to modules.
- `qip` does not register custom host functions for module imports.
- Modules that depend on unavailable imports fail instantiation.

Practical effect:

- Module code has no direct API to read files, open sockets, or make HTTP requests.

## What The Host Process Can Do

The `qip` process itself can still perform host I/O:

- Read input files via `-i` and module files from disk.
- Fetch module bytes from `https://...` URLs.
- Write output to stdout (`run`) or output files (`image`).
- Serve localhost HTTP in `qip dev` (`127.0.0.1:<port>`).

So trust in modules is separate from trust in the host process and its environment.

## Supply Chain Notes

Remote modules:

- Are fetched over HTTPS at runtime.
- Are not currently digest-pinned/enforced.
- Can have their SHA-256 printed in verbose mode for inspection.

Recommendation:

- Prefer pinned/local module artifacts for repeatable production pipelines.

## Resource Controls

Current guardrails:

- `run`, `image`, and each `dev` request execute under a `100ms` context timeout.
- Input size is checked against module-advertised input capacity.
- Output size is checked against module-advertised output capacity when output buffers are exported.

Current limitations:

- No explicit per-module memory policy is configured in `qip` runtime config.
- A module can declare large initial linear memory; instantiation may still reserve significant address space.

## Data Safety Expectations

- Module output should be treated as untrusted bytes.
- A module trap or runtime error aborts that stage/request.
- `qip` does not validate semantic correctness of module output beyond contract bounds checks.
