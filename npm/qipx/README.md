# qipx

`qipx` is a zero-dependency Node CLI and library for running [QIP Content
components](https://qip.dev/docs/content-component) and [Compliance
oracles](https://qip.dev/docs/comply).

The package requires Node.js 22 or newer. Useful component and oracle downloads
are available from [qip.dev/tools](https://qip.dev/tools) and
[qip.dev/oracles](https://qip.dev/oracles).

## Try It

Download a Markdown renderer and run it with `npx`:

```sh
curl -L -o gfm-commonmark.0.31.2.wasm \
  https://qip.dev/components/text/markdown/gfm-commonmark.0.31.2.wasm

printf '# Hello from qipx\n' | npx qipx run gfm-commonmark.0.31.2.wasm
```

Multiple components run left to right. Download a compressor and a Base64
encoder, then pipe bytes through both:

```sh
curl -L -o zlib-compress.wasm \
  https://qip.dev/components/bytes/zlib-compress.wasm
curl -L -o base64-encode.wasm \
  https://qip.dev/components/bytes/base64-encode.wasm

printf 'qip + wasm\n' | npx qipx run zlib-compress.wasm base64-encode.wasm
```

## CLI

Run a Content component pipeline:

```sh
qipx run [options] <component.wasm> [component2.wasm ...]

Options:
  -i, --input <path>              Read input from a file instead of stdin
  -o, --output <path>             Write output to a file instead of stdout
  --input-content-type <type>     Set the initial pipeline content type
  --max-memory <bytes>            Reject modules whose declared memory exceeds bytes
  --capacities-must-fit           Reject stages whose max output cannot fit next input
```

Validate a pipeline without reading input, calling `render`, or writing output:

```sh
qipx dry run [options] <component.wasm> [component2.wasm ...]
```

`dry run` uses the same component loading, Strict Wasm Profile subset, Content
ABI validation, content-type checks, and `--capacities-must-fit` checks as
`run`. It applies uniforms on the prepared instances so missing setters,
invalid values, and setter traps fail before execution. It does not read stdin,
call `render`, or write output.

Uniforms can be supplied as query strings after a component path:

```sh
qipx run components/utf8/text-to-bmp.wasm '?cols=80&leading=16' < text.txt > out.bmp
```

Uniform keys are lowercase snake identifiers with 1 to 63 characters. They must
start with `[a-z]`, continue with `[a-z0-9_]*`, must not end with `_`, and must
not contain `__`.

Integer `i32` uniforms are treated as unsigned values. Use an `i64` uniform when
a component needs signed integer configuration.

Check QIP Content compliance for files or directories:

```sh
qipx comply [options] <file-or-dir> [...]

Options:
  --with <compliance.wasm>        Run a Compliance oracle (repeatable)
  --seed <n>                      Call uniform_set_seed(u32) on each oracle
  --max-memory <bytes>            Reject implementation memory above bytes
```

Download a component and a reusable oracle, then check them together:

```sh
curl -L -o utf8-must-be-valid.wasm \
  https://qip.dev/components/utf8/utf8-must-be-valid.wasm
curl -L -o trap-invalid-utf8.wasm \
  https://qip.dev/oracles/trap-invalid-utf8.wasm

npx qipx comply utf8-must-be-valid.wasm --with trap-invalid-utf8.wasm
```

`comply` accepts files and directories. Directories are searched recursively.
Each `.wasm` file is checked against the Strict Wasm Profile subset, static QIP
ABI exports, and QIP Content ABI.

Use `--with` to add one or more Compliance oracles. `qipx` runs the built-in
checks first, then runs each oracle through the `qip` bridge.

A Compliance oracle can also test a non-QIP implementation. A JS test can
instantiate the oracle `.wasm`, bind the `qip` imports, and route each declared
case to a normal JavaScript function that returns bytes or throws. The
implementation does not need to be WebAssembly; only the adapter must implement
the oracle bridge.

```text
PASS components/utf8/trim.wasm
PASS components/utf8/trim.wasm --with compliance/preserve-empty.wasm (1 cases)

pass=2 fail=0 total=2
```

Benchmarking is coming soon:

```sh
qipx bench [options] <component.wasm> [...]
# qipx bench is coming soon
```

## JavaScript API

Use Node's standard library to load files and the built-in `WebAssembly` APIs to
compile and instantiate. Then pass the instance to `newComponent`:

```js
import { readFile } from "node:fs/promises";
import {
  contentTypeUTF8,
  createPipeline,
  newComponent,
  newContentComponentContract,
  wasmMustComplyWithComponentContract,
} from "qipx";

const label = "gfm-commonmark.0.31.2.wasm";
const wasm = await readFile("gfm-commonmark.0.31.2.wasm");
const contract = newContentComponentContract({
  label,
  maxMemory: 67108864,
  input: contentTypeUTF8("text/markdown"),
  output: contentTypeUTF8("text/html"),
});

wasmMustComplyWithComponentContract(wasm, contract);
// Synchronous equivalent:
// const instance = new WebAssembly.Instance(new WebAssembly.Module(wasm));
const { instance } = await WebAssembly.instantiate(wasm);
const markdown = newComponent(instance, contract);

const pipeline = createPipeline([{ component: markdown }]);
const result = pipeline.run("# Hello\n");

console.log(new TextDecoder().decode(result.bytes));
```

The library keeps WebAssembly instantiation outside its contract so callers can
choose async or sync setup. It provides QIP-specific validation and execution:

- `wasmMustComplyWithComponentContract(bytes, options)` checks the byte-level
  QIP Content contract before compilation and instantiation. It enforces the
  Strict Wasm Profile subset, `maxMemory`, no imports, no start function, no
  `memory.grow`, no atomics, the required Content exports, complete
  content-type metadata pairs, and static QIP ABI getter functions.
- `newContentComponentContract(options)` creates a reusable contract object for
  byte-level checks and instantiated component checks.
- `newComponent(instance, contract)` validates the instantiated QIP Content ABI
  and reads callable getter values and content-type metadata bytes. The
  contract can include `input: contentTypeUTF8(...)`, `input:
  contentTypeBytes(...)`, `output: contentTypeUTF8(...)`, or `output:
  contentTypeBytes(...)` when your code must verify the expected component
  contract.
- `validatePipeline(stages, options)` checks stage compatibility before input
  bytes run. This is where content-type mismatches and
  `capacitiesMustFit` failures are reported.
- `pipeline.run(input)` executes synchronously against instantiated components.
  This is where runtime traps, input-too-large errors, and invalid output length
  errors are reported.

`qipx` does not include a cache. If two recipes share a `.wasm` file, keep
the component yourself and pass it to each pipeline that needs it.

## Failure modes

When validation or execution fails, the library throws an `Error` or
`RangeError`. The CLI prints the message and exits with code 1.

| Phase | Function or CLI point | Typical failures |
| --- | --- | --- |
| Component contract bytes | `wasmMustComplyWithComponentContract(bytes, { maxMemory })` or CLI component loading | invalid Wasm binary header; imports; start function; shared memory; `memory.grow`; atomics; malformed function bodies; declared memory exceeds `maxMemory`; memory has no declared maximum when `maxMemory` is set; missing Content exports; non-static ABI getters |
| Instantiation and ABI | `newComponent(instance, options)` | exported memory is missing; `render` is missing; input/output pointer or capacity exports are missing or ambiguous; declared content type is invalid |
| Pipeline validation | `validatePipeline(stages, options)` or `createPipeline(...)` | a stage expects a different content type than the previous stage produced; pipeline content type is unspecified for a stage that declares an input type; `capacitiesMustFit` finds producer output capacity larger than consumer input capacity |
| Execution | `pipeline.run(input)` or `runPipeline(input, stages, options)` | input bytes do not fit the stage input buffer; the component traps; returned output length exceeds the advertised output capacity or memory bounds |
| Compliance bridge | `qipx comply impl.wasm --with oracle.wasm` | oracle does not export `memory` or `comply`; oracle imports other than the `qip` bridge; bridge ordinals are not sequential; expected output does not match actual output; expected trap does not trap; must_render_into protocol is not closed |

Example `maxMemory` failure:

```text
component.wasm declares maximum memory 67108864 bytes, exceeding --max-memory 8388608
```

Example pipeline compatibility failure:

```text
markdown.wasm expects text/markdown, got text/html
```

Example capacity compatibility failure:

```text
zlib-compress.wasm output capacity 8389259 exceeds base64-encode.wasm input capacity 65536
```
