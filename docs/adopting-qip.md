# Adopting QIP In Existing Apps

Use QIP for small content transforms that need to run the same way across runtimes, or for generated code that should not get ambient access to the host app.

QIP does not replace your framework, data model, auth, routing, or deployment. The app passes bytes into a WebAssembly component, the component returns bytes, and normal app code stays in charge of everything around that call.

The tradeoff is explicitness. QIP is more work than calling a library function: you define input bytes, output bytes, memory limits, and error behavior. In return, the component is self-contained, deterministic, and isolated from the filesystem, network, environment, package graph, and secrets unless the host deliberately passes data in.

## Use It For

- Content transforms shared by web, server, CLI, CI, native, or mobile apps.
- Small AI-generated components that should only see explicit input.
- Stable transforms where exact output bytes can be tested.

Good first examples: Markdown rendering, QR-code creation, SVG rasterization, HTML validation, image filtering, formatting, normalization.

## Keep The App In Charge

Do not turn your whole app into QIP components. Keep user sessions, auth, database queries, metrics, logging, request routing, permissions, product workflow, and platform integration in normal code.

Put QIP around the steps that benefit from a strict content-in, content-out contract. Normal code can still run before, after, or between QIP stages:

1. App code loads Markdown from the database.
2. QIP renders Markdown to HTML.
3. App code records metrics or applies product rules.
4. QIP validates or wraps the HTML.
5. App code stores, serves, or caches the result.

## AI-Generated Code

QIP does not make AI-generated code correct. It limits what AI-generated code can access.

A QIP component only sees the bytes written into its memory. It cannot scan your project directory, read environment variables, open sockets, call third-party APIs, inspect secrets, or reach into host process state. You still review and test whether it validates input and returns the expected output, but it has fewer ways to interfere with the rest of the app.

## Performance

Each QIP stage is a benchmark target. Feed it bytes, measure runtime, optimize the component, and compare output bytes. If the bytes still match and the stage gets faster, ship the same `.wasm` anywhere that component runs.

Use host code instead when the fast path needs platform APIs, shared mutable app state, GPU integration, or background network access.

## Adoption Path

1. Pick one small content transform.
2. Define input type, output type, and invalid-input behavior.
3. Write or generate the QIP component.
4. Add fixtures, snapshots, or a `qip comply` checker.
5. Run `qip comply`.
6. Run `qip bench`.
7. Embed the same `.wasm` where the app needs that behavior.

```bash
qip comply components/text/markdown/commonmark.0.31.2.wasm --with compliance/commonmark-spec-0.31.2.wasm
qip bench -i page.md --benchtime=2s components/text/markdown/commonmark.0.31.2.wasm
```

## Runtime Guides

The QIP memory contract stays the same across hosts. These guides show the loading, memory, failure, and instance-lifetime choices for specific application runtimes:

- [Running QIP In Python](/docs/running-in-python) loads a WebAssembly Core module from disk with Wasmtime.
- [Running QIP In Java](/docs/running-in-java) loads the same module with the pure-Java Chicory runtime.
- [Running QIP In .NET](/docs/running-in-dotnet) uses Wasmtime from C# and covers ASP.NET instance ownership.
- [Running QIP In React](/docs/running-in-react) covers browser Client Components and Next.js Server Components.

For lower-level JavaScript integration, including direct `.wasm` imports where the runtime supports them, see [Running In JavaScript](/docs/running-in-javascript).

## When Not To Use QIP

Use normal app code when the work needs live database queries, network calls, secrets, large mutable state, platform APIs, framework lifecycle hooks, or host-specific acceleration.

A normal library call may also be better when the code is already trusted, platform-specific behavior is fine, and the dependency is stable enough for your team.
