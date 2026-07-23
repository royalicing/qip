# QIP Docs

## The Problem With Software Today

Much software is built as layers of frameworks, packages, platforms, and operating-system features. The result is often non-deterministic in practice: behavior can depend on installed packages, environment variables, filesystem layout, network services, locale, clocks, and the exact setup of the machine around it.

Containers can package that environment, which is useful for full applications. For a content transform, validator, image filter, or small interactive tool, it is often more machinery than the work needs.

AI coding raises the stakes. Agents can generate useful code quickly, but that code is easier to review and test when its inputs, outputs, memory, and host access are explicit.

## The QIP Values

QIP is named for the constraints we want every component to keep:

- **Quarantined:** components run in a deterministic sandbox with zero access to the host: no filesystem, no network, and no environment.
- **Immutable:** components are self-contained with no required dependencies, so once you have a working component it keeps working with no updates required.
- **Portable:** components run identically across web and native hosts through the same QIP contract.

## Names In These Docs

QIP is the portable standard of component contracts, documented in these pages.

[`qip`](/docs/qip-cli) is the command-line host implemented in this repo. It also serves as a reference implementation of QIP. This repo also contains browser JavaScript hosts such as `<qip-edit>` and `<qip-play>`. Native implementations such as in Swift are also available on request.

## QIP Spec

If you want to send someone the current QIP spec, send them these pages:

- [QIP Component Contracts](/docs/component-contract): the component types, their execution models, maturity, and how hosts distinguish them.
- [Content Component Contract](/docs/content-component): the memory ABI, render lifecycle, content types, and composition rules for finite transforms.
- [Interactive Component Contract](/docs/interactive-component): the framebuffer, event codes, timing, sizing, and host loop for interactive components.
- [`qip comply`](/docs/comply): the Compliance-component bridge, ordered oracle calls, memory ownership, and executable conformance checks.
- [Uniforms](/docs/uniforms): optional numeric component configuration and host application rules.
- [Hard Limits](/docs/hard-limits): the constrained WebAssembly subset QIP components should stay inside.
- [Formats and Encodings](/docs/formats): the MIME type and byte-format conventions that let components compose cleanly.

The current Tile and Form interfaces are evolving:

- The repository's `IMAGE.md` for Tile components.
- [Form ABI](/docs/form_abi) for Form components.

[`qip` CLI](/docs/qip-cli), [Router](/docs/router), [Recipes](/docs/recipes), and [Browser Elements](/docs/qip-elements) are reference implementation and tooling docs. They are useful when building with this repo, but they are not the core QIP component spec.

## Why WebAssembly

WebAssembly gives QIP a compact execution target with wide runtime support.

A normal execution component is a WebAssembly binary with explicit exports and no imports. By default, QIP gives it no filesystem, network, environment, clock, or secrets. The host writes input bytes into component memory, calls a known export such as `render(input_size)`, then reads output bytes back. Compliance components use only the narrow `qip` oracle bridge documented in [`qip comply`](/docs/comply); that bridge does not expose general host capabilities.

That shape gives the host a deterministic execution boundary: the same component bytes and input bytes are guaranteed produce the same output bytes. Components stay small enough to test, benchmark, and replace when better code appears.

PDF/A, PDF/X, and PDF/UA are not replacements for PDF; they are constrained ways to use PDF for archiving, print exchange, and accessibility. QIP plays the same role for WebAssembly: every QIP component is a WebAssembly module, but not every WebAssembly module is a QIP component.

## Why Not WASI

WASI helps WebAssembly programs behave more like portable command-line or server programs. That is the right shape when code needs file descriptors, clocks, randomness, environment variables, sockets, or a virtual filesystem.

QIP is deliberately narrower. QIP is for components that should not need those capabilities. If a component transforms Markdown, validates UTF-8, renders an image tile, or emits an interactive frame, the host can pass the required bytes in and read bytes back out. The component does not need to explore the filesystem, network, clock, environment, or secrets around it.

That narrower subset is easier to run in browsers, easier to inspect, easier to reproducibly test by comparing outputs, and easier to use safely with AI-generated code. If a component needs database access, user settings, or files, your app should fetch that data and pass in the specific bytes the component is allowed to see.

For the concrete runtime limits, see [Hard Limits](/docs/hard-limits). For the boundary model, see [Architecture And Boundaries](/docs/architecture-boundaries).

## Content-First Not File-First

QIP treats content as bytes with MIME types, not as files with special build-system meaning.

That is why recipes are selected by MIME type, why Content components can convert/assert/refine, and why our router works with `application/warc` instead of a particular static-file layout.

For example, `qip router warc ./site` produces a `application/warc` Web Archive. Another component can check for broken links, add extra endpoints, insert meta tags or stylesheets, and turn the archive into a static tarball to be deployed.

## Adopting QIP In An Existing App

QIP fits into existing apps when a small content transform should work the same across platforms, or when generated code should run without filesystem, network, environment, or secret access.

Keep the app in charge of routing, auth, storage, and product workflow. Move a small deterministic transformation into a QIP component: render Markdown, validate HTML, normalize an identifier, transform an image, or generate a QR code. The component gets only the bytes the app passes in, and the app gets portable behavior it can test by comparing output bytes.

See [Adopting QIP In Existing Apps](/docs/adopting-qip) for the practical checklist.


<nav class="docs-sidebar" aria-label="Docs">
<ol>
<li><span class="docs-section">Getting Started</span>
<ol>
<li><a href="/docs">Why QIP Exists</a></li>
<li><a href="/docs/how-it-works">How QIP Works</a></li>
<li><a href="/docs/adopting-qip">Adopting QIP In Existing Apps</a></li>
<li><a href="/docs/architecture-boundaries">Architecture And Boundaries</a></li>
</ol>
</li>
<li><span class="docs-section">Running</span>
<ol>
<li><a href="/docs/qip-cli">qip cli</a></li>
<li><a href="/docs/qip-elements">Browser Elements</a></li>
<li><a hidden href="/docs/javascript-runner">JavaScript Renderer Annotated Source</a></li>
<li><a href="/docs/running-in-javascript">Running In JavaScript</a></li>
<li><a href="/docs/running-in-react">Running In React</a></li>
<li><a href="/docs/running-in-python">Running In Python</a></li>
<li><a href="/docs/running-in-java">Running In Java</a></li>
<li><a href="/docs/running-in-dotnet">Running In .NET</a></li>
</ol>
</li>
<li><span class="docs-section">QIP spec</span>
<ol>
<li><a href="/docs/component-contract">Component Contracts</a></li>
<li><a href="/docs/content-component">Content Component</a></li>
<li><a href="/docs/interactive-component">Interactive Component</a></li>
<li><a href="/docs/uniforms">Uniforms</a></li>
<li><a href="/docs/hard-limits">Hard Limits</a></li>
<li><a href="/docs/formats">Formats and Encodings</a></li>
<li><a hidden href="/docs/form_abi">Form ABI!</a></li>
<li><a href="/docs/comply">Comply</a></li>
</ol>
</li>
<li><span class="docs-section">Making components</span>
<ol>
<li><a href="/docs/module-patterns">QIP Component Patterns</a></li>
<li><a href="/docs/zig-components">Writing QIP Components In Zig</a></li>
<li><a href="/docs/c-wasm-toolchains">Building C Libraries As QIP Components</a></li>
<li><a href="/docs/tracing">Tracing</a></li>
<li><a href="/docs/wasm-counts">Counting A WebAssembly Module</a></li>
<li><a href="/docs/nontrapping-divides">Proving Non-Trapping Divides</a></li>
<li><a href="/docs/interactive-rendering-performance">Interactive Rendering Performance</a></li>
<li><a href="/docs/testing-interactive-components">Testing Interactive Components</a></li>
</ol>
</li>
<li><span class="docs-section">Router</span>
<ol>
<li><a href="/docs/content">Content Layout</a></li>
<li><a href="/docs/recipes">Recipe Layout</a></li>
<li><a href="/docs/router">Router</a></li>
<li><a href="/docs/routing-recipes">File Routing & Recipe Orchestration</a></li>
<li><a hidden href="/docs/visitor_router_abi_v0">Visitor Router ABI v0</a></li>
</ol>
</li>
</ol>
</nav>
