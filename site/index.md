# qip

Pipelines of safe determinism in a probabilistic world.

`qip` is for builders who want software that stays small, understandable, and reliable.

## What qip is

`qip` runs WebAssembly modules in a strict, composable pipeline.

Each module does one focused job: e.g. parse, validate, transform, render, or enhance.

- Small swappable units
- Deterministic outputs
- Portable execution
- Explicit input/output contracts

## Why this approach

Modern software is often too coupled, too stateful, and too hard to trust.
`qip` takes a different path:

- **Simplicity first**: boring interfaces, predictable behavior
- **Security by default**: sandboxed modules, minimal host surface
- **Focused tools**: compose narrow modules instead of building giant runtimes
- **Long-term maintainability**: contracts over conventions, reproducible pipelines

## Tech choices

`qip` is built in Go using it venerable standard library for file system access, HTTP server, and format encoding. It works with WebAssembly modules authored in C, Zig, WAT, or any language that targets wasm32.

It favors explicit contracts and plain directory layouts over magic.

## Philosophy

Good tools should be:

- easy to compose
- secure by default
- cheap to replace

That is the bar for `qip`.

- [How qip Works](./how-it-works.md)
