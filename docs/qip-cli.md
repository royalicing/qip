# qip CLI

`qip` is the command-line host in this repo. QIP is the broader standard: the component contract, execution shape, and architecture.

This page is about CLI behavior: commands, file and network access by the host process, runtime guardrails, and implementation details that should not be mistaken for the whole QIP standard. This repo also contains browser JavaScript hosts such as `<qip-edit>` and `<qip-play>`. Native hosts such as the Swift implementation should follow the same component contract but may expose different application APIs.

## Names

Use these names consistently:

- **QIP**: the component contract, execution shape, and design philosophy.
- **`qip`**: the CLI executable implemented in this repo.
- **QIP component**: a WebAssembly module that follows the QIP contract.
- **QIP host**: any implementation that loads a component, writes input bytes, calls exports, and reads output bytes.
- **Browser hosts**: this repo's `<qip-edit>` and `<qip-play>` JavaScript runtimes.

## Commands

The CLI is the operational tool for local development, CI, benchmarking, and static-site workflows:

| Command | Use |
| --- | --- |
| `qip run` | Run a chain of QIP components on input bytes. |
| `qip bench` | Compare one or more components for output parity and performance. |
| `qip image` | Run RGBA image filter pipelines. |
| `qip comply` | Validate a component and run compliance modules. |
| `qip score` | Statically score Wasm control-flow, call cost, recursion, and loop-bound evidence. |
| `qip router dev` | Serve a content directory with routing and recipes. |
| `qip router` | Resolve routes and export route artifacts such as WARC. |
| `qip form` | Run an interactive QIP form component in the terminal. |

`qip dev` remains available as a compatibility alias for `qip router dev`. It prints a migration notice so scripts can be updated without breaking immediately.

For the available execution models, see [QIP Component Contracts](/docs/component-contract). For the normal `qip run` ABI, see the [Content Component Contract](/docs/content-component). For route behavior, see [Router](/docs/router). For compliance testing, see [`qip comply`](/docs/comply).

## Runtime Boundary

The CLI is designed to run untrusted QIP components with a narrow host interface.

Components execute inside `wazero` and interact with the CLI only through exported function calls and linear memory.

Current host behavior:

- `qip` does not provide WASI to components.
- `qip` does not register custom host functions for module imports.
- Components that depend on unavailable imports fail instantiation.

Practical effect:

- Module code has no direct API to read files, open sockets, or make HTTP requests.

## What The Host Process Can Do

The CLI process itself can still perform host I/O:

- Read input files via `-i` and module files from disk.
- Fetch component bytes from `https://...` URLs.
- Write output to stdout (`run`) or output files (`image`).
- Serve localhost HTTP in `qip router dev` (`127.0.0.1:<port>`).

So trust in components is separate from trust in the CLI process and its environment.

## Supply Chain Notes

Remote modules:

- Are fetched over HTTPS at runtime.
- Are not currently digest-pinned/enforced.
- Can have their SHA-256 printed in verbose mode for inspection.

Recommendation:

- Prefer pinned/local module artifacts for repeatable production pipelines.

## Resource Controls

Current CLI guardrails:

- `run` executes under a `5000ms` context timeout by default (configurable via `--timeout-ms`).
- `image` executes under a `4000ms` context timeout by default (configurable via `--timeout-ms`).
- Each `dev` request executes under a `100ms` context timeout.
- Input size is checked against module-advertised input capacity.
- Output size is checked against module-advertised output capacity when output buffers are exported.
- `run`, `bench`, and `image` can reject modules whose declared memory exceeds a byte cap with `--max-memory <bytes>`.
- `run`, `bench`, and `image` reject modules containing `memory.grow` by default.
- `--allow-memory-grow` permits growth when paired with `--max-memory <bytes>`.
- `qip score` reports `fixed_bound_loops: PASS` when loop backedges match the accepted fixed-counter pattern, and `WARN` when the bound is not proven.
- `modules/application/wasm/wasm-strict-profile.wasm` enforces the strict artifact profile's factual rules (imports, memory shape, banned instructions, recursion) as a QIP component; `modules/application/wasm/wasm-bounded-loops.wasm` proves loop bounds. Pipe through both for the full strict tier.

The browser JavaScript hosts expose the same policy with `max-memory="<bytes>"` and `allow-memory-grow`; see [Browser Elements](/docs/qip-elements) and the [Interactive Component Contract](/docs/interactive-component).

Current limitations:

- A module can declare large initial linear memory; instantiation may still reserve significant address space.

Recommendation:

- Components should declare a fixed memory maximum at build time. Zig components should use `--max-memory=<bytes>`; see [Writing QIP Components In Zig](/docs/zig-components).
- Use `--max-memory` when running unreviewed modules or CI checks. A module with memory but no declared maximum is rejected when this flag is set.
- Use `--allow-memory-grow` only for components whose allocator requires it, and set `--max-memory` in the same command.
- Use `qip score <component.wasm>` when you want a readable static report before deciding whether to enforce the stricter safety checker.
- See [Hard Limits](/docs/hard-limits) for build flags and language-specific guidance.

## Data Safety Expectations

- Module output should be treated as untrusted bytes.
- A module trap or runtime error aborts that stage/request.
- `qip` does not validate semantic correctness of module output beyond contract bounds checks.
