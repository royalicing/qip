# How QIP Works

QIP is a small host runtime that executes QIP components with explicit memory contracts.

The mental model is simple:

1. Host reads bytes
2. Host writes bytes into component memory
3. Component runs
4. Host reads output bytes
5. Optional: feed output to the next component

That is the core loop for both CLI pipelines and web preview workflows.

## 1. QIP Component Contracts

A text/binary QIP component exports a small ABI:

- `input_ptr`
- `input_utf8_cap` or `input_bytes_cap`
- `render(input_size)`
- `output_ptr`
- `output_utf8_cap` or `output_bytes_cap` (or `output_i32_cap`)

The host validates capacities and boundaries before writing/reading memory.

This keeps QIP components interchangeable and predictable.

## 2. Runtime Execution

When you run:

```bash
qip run component-a.wasm component-b.wasm
```

`qip`:

- compiles the components
- instantiates each component for execution
- passes output of stage N as input to stage N+1
- preserves deterministic stage order

No hidden dependency graph, no plugin magic.

## 3. Content + Recipes (Web Dev Mode)

When you run:

```bash
qip dev ./site
```

`qip` builds in-memory state from the site tree:

- content files (source documents/assets)
- reserved project directories such as `_recipes`, `_forms`, and `_components`

Recipe discovery uses:

- `_recipes/<type>/<subtype>/NN-name.wasm`
- optional disabled form: `-NN-name.wasm`

Where `NN` is `00..99` and lower runs first.

Strictness today:

- duplicate prefixes in the same MIME folder are an error
- non-`.wasm` files are ignored
- filenames must match the required format

## 4. Request Handling

For each request in `qip dev`:

1. Resolve request path to a source file
2. Detect source MIME from file extension
3. Load source bytes
4. Run matching recipe chain (if any)
5. Return response bytes + content type + ETag

Selection is based on **source MIME** (for example `text/markdown`), which keeps routing linear and easy to inspect.

## 5. Reload Without Restart

`qip dev` supports in-place reload with `SIGHUP`:

```bash
kill -HUP <pid>
```

On reload, `qip` rebuilds content routes and recipe chains, then swaps state atomically.
If reload fails, the previous state keeps serving.

## 6. Why This Design

The architecture optimizes for:

- small, inspectable interfaces
- deterministic behavior
- reproducible builds and serving
- operational safety under change

Instead of adding framework complexity, `qip` keeps the host narrow and pushes domain logic into replaceable QIP components.
