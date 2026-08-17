# QIP Component Contracts

QIP components are WebAssembly modules with one of several small host interfaces. Choose the contract from the work the component does: transform finite content, maintain an interactive framebuffer, filter image tiles, collect a sequence of form values, or declare conformance cases for another component.

The contracts are at different stages of development. The Content and Interactive contracts are mostly stable. Compliance is usable across the repository, while its stricter authoring profile and corpus tooling are still evolving. Tile and Form are useful today, but their interfaces may still change substantially.

## Choose A Component Type

| Type | Use it for | Execution model | Maturity |
| --- | --- | --- | --- |
| [`Content`](/docs/content-component) | Text, binary data, documents, archives, validators, and finite renderers | The host writes one input, calls `render`, and reads one output | Mostly stable |
| [`Interactive`](/docs/interactive-component) | Games, simulations, and persistent interfaces | The host delivers events, advances time with `tick`, and pulls framebuffer pixels | Mostly stable |
| [`Compliance`](/docs/comply) | Reusable executable specifications for Content components | The oracle declares ordered cases through the host bridge; the host runs them against an implementation | Evolving |
| `Tile` | RGBA image filters | The host runs a filter over 64×64 pixel tiles, with optional halo pixels | Evolving |
| `Form` | Prompt-driven, multi-step input | The host exchanges one field value at a time until the component reports completion | Evolving |

Choose Content unless the component needs one of the other host lifecycles. A Content component can still produce an image, HTML interface, or other rich output; the distinction is that each `render` call is a finite input-to-output operation.

Interactive is for state that remains live between events. Compliance is for independently checking Content behavior, not for transforming end-user input directly. Tile exists to let image hosts process bounded regions without giving every filter a full-image buffer. Form coordinates a sequence of prompts and validation results. The latter two contracts should not yet be treated as long-term compatibility boundaries.

## Contract References

- [Content Component Contract](/docs/content-component) defines the memory buffers, `render` lifecycle, content-type metadata, composition rules, and failure behavior for finite transforms.
- [Interactive Component Contract](/docs/interactive-component) defines framebuffer output, keyboard and pointer events, timing, sizing, and the host loop for persistent interactive modules.
- [`qip comply`](/docs/comply) defines Compliance oracle memory ownership, oracle imports, ordered case declarations, and oracle authoring patterns.
- [Uniforms](/docs/uniforms) defines the optional numeric configuration setters that hosts can apply to components.

All component types also operate within [Hard Limits](/docs/hard-limits). [Formats and Encodings](/docs/formats) defines the byte-format and MIME conventions used when components exchange content.

## Evolving Contracts

### Tile

Tile components are RGBA32Float filters used by `qip image` and the browser image host. The current interface includes:

- `memory`
- `input_ptr()` and `input_bytes_cap()`
- `tile_rgba32float_64x64(tile_x: f32, tile_y: f32)`
- Optional `calculate_halo_px()`
- Optional host-managed `uniform_set_width_and_height(width: f32, height: f32)`

Tiles are 64×64 pixels. A filter that requests a halo receives an expanded tile with edge clamping, so its row stride is larger than 64 pixels. If any stage requests a halo, the host uses a full-image float32 pipeline for the contiguous Tile stages.

The current interface is documented in the repository's `IMAGE.md`. Expect this contract to change as the image execution model develops.

### Form

Form components are prompt-driven workflows used by `qip form`. The component exposes metadata for the current input, accepts one value through `render`, and either reports a validation error, advances to the next input, or produces its final output.

See [Form ABI](/docs/form_abi) for the current required exports and host flow. Expect this contract to change as CLI and browser form hosts develop.

## Contract Detection

Hosts classify a module from its exports and the command being run:

1. `qip run` with exactly one component first checks whether the module matches Interactive first-frame handling.
2. If it does not, normal pipeline building starts.
3. During pipeline building, a module exporting `tile_rgba32float_64x64` is classified as Tile.
4. Other pipeline modules are classified as Content.
5. `qip form` uses the Form contract path.
6. `qip comply --with` treats each oracle as Compliance and requires its
   exported `memory` and `comply() -> i32` entry point.

For example, a module exporting `tile_rgba32float_64x64` is treated as Tile during pipeline composition even when it also exports `render`.

## Shared Conventions

QIP pointer, size, and capacity values are exported as zero-argument functions
returning `i32`.
An exported WebAssembly global with the same name does not satisfy the contract.

Components may expose optional `uniform_set_<key>` functions for numeric configuration. Uniforms are shared configuration machinery rather than a separate component type. See [Uniforms](/docs/uniforms) for setter signatures, host ordering, parsing, and CLI syntax.

Compliance oracles are the exception to the normal no-import rule. They may
import the documented oracle functions from the `qip` host module. They own
their memory; they do not import or share the implementation's memory. The host
copies each declared input into a separate implementation instance and records
expected output, actual output, traps, and the case ordinal.

## Intersections

Content and Interactive share `render` and some output exports, but have different host lifecycles. A single-component `qip run` invocation checks the Interactive shape before treating the module as a Content pipeline stage.

Content and Tile can also share exports. The presence of `tile_rgba32float_64x64` wins during pipeline classification, so combine the two interfaces only when Tile behavior is intentional.

Compliance oracles target Content implementations because their bridge
drives `render(i32) -> i32`. They are test artifacts rather than Content
pipeline stages and should be passed with `qip comply --with`, not `qip run`.

The component interface is only the first compatibility boundary. Components must not assume unbounded memory, long-running execution, imports outside their documented contract, filesystem access, network access, or a larger runtime around them. See [Hard Limits](/docs/hard-limits) for the constraints that apply after choosing a contract.
