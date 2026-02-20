# qip

## Small, secure, and predictable software components

`qip` runs WebAssembly modules in a strict, composable pipeline. Each module you write does one focused job: e.g. parse, validate, transform, render, etc.

These modules can be composed into ever greater units, such as a HTTP server or image effect pipeline.

I like to think of `qip` as “React components but for everything (and that run anywhere).”

## The problems with software today

Software today is like Matryoshka dolls, frameworks that depend on libraries that depend on libraries that depend on OS libs and so on. This can be incredibly productive for building, but has lead to increasingly complex and bloated end-user apps.

This has expanded the surface areas for security attacks, due to the large number of moving parts and countless dependencies prone to supply-chain attacks. It also means that software is less predictable and harder to debug. Any line of a dependency could be reading SSH keys & secrets, mining bitcoin, remotely executing code. This gets worse in an AI world, especially if we are no longer closely reviewing code.

## Two key technologies combined

There are two recent technologies that change this: WebAssembly and agentic coding.

With WebAssembly we get light cross-platform executables. We can really write once, run anywhere. We can create stable, self-contained binaries that don’t depend on anything external. We can sandbox them so they don’t have any access to the outside world: no file system, no network, not even the current time. This makes them deterministic, a property that makes software more predictable, reliable, and easy to test.

## AI needs hard boundaries

With agentic coding we get the ability to quickly mass produce software. But most programming languages today have wide capabilities that make untrustworthy code risky. Any generated line could read SSH keys or talk to the network or mine bitcoin. We need hard constraints.

`qip` forces you to break code into boundaries. Most modules follow a simple contract: there’s some input provided to the WebAssembly module, and there’s some output it produces. Since this contract is deterministic we can then cache easily using the input as a key. Since modules are self-contained and immutable we can also use them as a cache key. Connect these modules together and you get a deterministic pipeline. Weave these pipelines together and you get a predictable, understandable system.

## Old guardrails

Paradigms like functional or object-oriented or garbage collection become less relevant in this new world. These were patterns that allowed teams of humans to consistently make sense of the modular parts they wove into software. To a LLM, imperative is just as easy as any other paradigm to author. Static or bump allocation is no harder than `malloc`/`free`.

Memory is only copied between modules so within it can mutate memory as much as it likes, which lets you (or your agent) find the most optimal algorithm. If we align code written to the underlying computing model of the von-Neumann-architecture we can get predictably faster performance. We get pockets of speed safely sewn together.

## Benefits

- Small swappable units that you author, either with AI or by hand.
- Deterministic outputs that are easy to test and cache.
- Portable execution that works identically across platforms.
- Explicit input/output contracts securely isolated from disk/network/secrets.
- **Simplicity first**: boring interfaces, predictable behavior
- **Security by default**: sandboxed modules, minimal host surface
- **Focused tools**: compose narrow modules instead of building giant runtimes
- **Long-term maintainability**: contracts over conventions, reproducible pipelines

## Tech choices

`qip` is built in Go using its venerable standard library for file system access, HTTP server, and common format decoding/encoding. The wazero library is used to run WebAssembly modules in a secure sandbox. WebAssembly modules can be authored in C, Zig, WAT, or any language that targets wasm32.

It specifically does not use WASI. This standard has ballooned in complexity and scope creep. To get stuff done and to support browsers we can use a much smaller contract between hosts and modules.

`qip` favors explicit simple contracts and plain directory layouts over magic.

## Philosophy

Good tools should be:

- easy to compose
- secure by default
- cheap to replace
- work on the web, on native, and the command line
- runnable by agents and by users

---

- [How qip Works](./how-it-works.md)
