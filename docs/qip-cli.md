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
| `qip dry run` | Validate and describe a run pipeline without executing it. |
| `qip bench` | Compare one or more components for output parity and performance. |
| `qip image` | Run RGBA image filter pipelines. |
| `qip comply` | Validate a component and run compliance modules. |
| `qip score` | Statically score Wasm control-flow, call cost, recursion, and loop-bound evidence. |
| `qip router dev` | Serve a content directory with routing and recipes. |
| `qip router` | Resolve routes and export route artifacts such as WARC. |
| `qip form` | Run an interactive QIP form component in the terminal. |

`qip dev` remains available as a compatibility alias for `qip router dev`. It prints a migration notice so scripts can be updated without breaking immediately.

For the available execution models, see [QIP Component Contracts](/docs/component-contract). For the normal `qip run` ABI, see the [Content Component Contract](/docs/content-component). For route behavior, see [Router](/docs/router). For compliance testing, see [`qip comply`](/docs/comply).

`qip dry run` uses the same resolution, module policy, uniform application, and
pipeline planner as `qip run`. It reports each component kind, input/output
encoding and MIME type, buffer capacities, composition warnings, and the total
declared buffer capacity. It does not read `-i`, execute `render`, or write
output. See [Recipes](/docs/recipes#planning-and-dry-runs) for the composition
rules.

`--max-memory <bytes>` applies independently to each component. Dry run rejects
a component when that component's declared memory minimum or maximum exceeds
the cap, or when its memory has no declared maximum. It does not compare the cap
to the sum printed at the end of the report. That total is declared buffer
capacity, not resident Wasm memory.

`--capacities-must-fit` rejects a connection between adjacent Content
components when the producer's declared maximum output capacity exceeds the
consumer's input capacity. Without the flag, this is a warning: the pipeline
can still run when the actual intermediate value is smaller than the
producer's maximum. The flag is useful in CI when component authors want every
declared Content-to-Content connection to be safe for the full producer output
range. Tile capacities describe fixed-size per-tile working buffers and are
validated separately; they are not whole-image Content capacities. This flag
is unrelated to `--max-memory`.

## Runtime Boundary

The CLI is designed to run untrusted QIP components with a narrow host interface.

Components execute inside `wazero` and interact with the CLI through their documented exports and linear memory. Compliance components additionally use the narrow host bridge described in [`qip comply`](/docs/comply).

Current host behavior:

- `qip` does not provide WASI to components.
- Normal execution commands do not register custom host functions for module imports.
- `qip comply` registers the `qip` oracle imports only for the Compliance component; the implementation under test remains separately instantiated without those imports.
- Components that depend on imports outside their contract fail instantiation.

Practical effect:

- Module code has no direct API to read files, open sockets, or make HTTP requests. The Compliance bridge can only submit inputs, expected results, trap expectations, examinations, and uniform values to the host.

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
- `run`, `dry run`, `bench`, and `image` can reject modules whose declared memory exceeds a byte cap with `--max-memory <bytes>`.
- `run`, `dry run`, `bench`, and `image` reject modules containing `memory.grow` by default.
- `--allow-memory-grow` permits growth when paired with `--max-memory <bytes>`.
- `qip score` reports `fixed_bound_loops: PASS` when loop backedges match the accepted fixed-counter pattern, and `WARN` when the bound is not proven.
- `components/application/wasm/wasm-strict-profile.wasm` enforces the strict artifact profile's factual rules: imports, memory shape, banned instructions, recursion, and statically readable content-type metadata. `components/application/wasm/wasm-bounded-loops.wasm` proves loop bounds. Pipe through both for the full strict tier. [Hard Limits](/docs/hard-limits) is the canonical map of which commands enforce each rule.
- `components/application/wasm/wasm-nontrapping-divides.wasm` conservatively proves that integer division and remainder instructions cannot trap. Its proof vocabulary covers constants, unsigned ranges, dominating zero/overflow guards, and facts propagated through locals; see [Proving Integer Divisions Do Not Trap](/docs/nontrapping-divides).

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
