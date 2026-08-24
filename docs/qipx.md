# `qipx` CLI

`qipx` runs QIP Content components from Node.js without package dependencies. Use it to run and inspect content pipelines, check components against Compliance oracles, and compare implementations with a reused WebAssembly instance.

The package requires Node.js 22 or newer. Run it without installing it globally:

```sh
npx @qip.dev/qipx --help
```

## Subcommands

| Command | Use |
| --- | --- |
| `qipx run [options] <component.wasm> [...]` | Run one Content component or a left-to-right component pipeline. Input comes from stdin by default; output goes to stdout. |
| `qipx dry run [options] <component.wasm> [...]` | Validate a pipeline, its MIME connections, memory limits, capacities, and uniforms without reading input or calling `render`. |
| `qipx comply [options] <file-or-dir> [...]` | Check the Content ABI and strict WebAssembly subset, then run any Compliance oracles supplied with `--with`. |
| `qipx bench -i <input> [options] <component.wasm> [...]` | Compare warmed Content components on Node/V8 or Bun/JavaScriptCore. Every candidate must return the same type and bytes as the first component. |

Run `npx @qip.dev/qipx --help` for the current options. Uniform options follow the component they configure:

```sh
npx @qip.dev/qipx run text-to-bmp.wasm \
  -u cols=80 \
  -u leading=16 \
  < input.txt > output.bmp
```

## Try a component

Download the GitHub Flavored Markdown renderer, then run it:

```sh
curl -L -o gfm-commonmark.0.31.2.wasm \
  https://qip.dev/components/text/markdown/gfm-commonmark.0.31.2.wasm

printf '# Hello from qipx\n' \
  | npx @qip.dev/qipx run gfm-commonmark.0.31.2.wasm
```

See the [Content Component Contract](/docs/content-component) for the ABI, [Compliance oracles](/docs/comply) for portable behavior checks, and [Benchmarking Components](/docs/benchmarking-components) for benchmark interpretation.

`qipx` deliberately focuses on Content components and Compliance oracles. It does not serve router projects or run Tile, Form, or Interactive components. Use the repository's other hosts when you need those execution models.
