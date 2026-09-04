# QIP Component Contracts

QIP components are WebAssembly modules with one of several small host interfaces. Choose the contract from the work the component does: transform finite content, maintain an interactive framebuffer, filter image tiles, collect a sequence of form values, or declare conformance cases for another component.

The contracts are at different stages of development. Content is mostly stable.
The Timed and Eventful Interactive contract is implemented by every repository
Interactive component, but remains open to change while QIP is alpha.
Compliance is usable across the repository, while its stricter authoring
profile and corpus tooling are still evolving. Tile and Form are useful today,
but their interfaces may still change substantially.

## Choose A Component Type

| Type | Use it for | Execution model | Maturity |
| --- | --- | --- | --- |
| [`Content`](/docs/content-component) | Text, binary data, documents, archives, validators, and finite renderers | The host writes one input, calls `render`, and reads one output | Mostly stable |
| [`Interactive`](/docs/interactive-component) | Games, simulations, and persistent interfaces | The host opens timed updates, delivers events, finishes updates, and renders declared Content output | Implemented; evolving |
| [`Compliance`](/docs/comply) | Reusable executable specifications for Content components | The oracle declares ordered cases through the host bridge; the host runs them against an implementation | Evolving |
| `Tile` | RGBA image filters | The host runs a filter over 64×64 pixel tiles, with optional halo pixels | Evolving |
| `Form` | Prompt-driven, multi-step input | The host exchanges one field value at a time until the component reports completion | Evolving |

Choose Content unless the component needs one of the other host lifecycles. A Content component can still produce an image, HTML interface, or other rich output; the distinction is that each `render` call is a finite input-to-output operation.

Interactive is for state that remains live between events. Compliance is for independently checking Content behavior, not for transforming end-user input directly. Tile exists to let image hosts process bounded regions without giving every filter a full-image buffer. Form coordinates a sequence of prompts and validation results. The latter two contracts should not yet be treated as long-term compatibility boundaries.

## Capabilities Build On Content

Timed and Eventful behavior extends the Content contract instead of replacing
it. A component exports only the later capabilities it needs:

```text
Content            render input -> output
Fallible Content   Content + recoverable rejection in the render result
Timed              Content + begin_update_at + finish_update
Eventful           Timed + key, pointer, or other events
```

`components/interactive/gif-player.wasm` demonstrates the split. It first acts
as fallible Content: the host supplies `image/gif`, and `render` accepts or
rejects it while it decodes the first frame. After acceptance it is
Timed because GIF frames have deadlines. It is not Eventful because playback
does not need keyboard or pointer input. A Content-only host can still run its
initial render and receive the first KTX2 frame; a Timed host can continue the
animation.

## Contract References

- [Content Component Contract](/docs/content-component) defines the memory buffers, `render` lifecycle, content-type metadata, composition rules, and failure behavior for finite transforms.
- [Interactive Component Contract](/docs/interactive-component) defines keyboard and pointer events, timed updates, declared output, and the host loop for persistent modules.
- [Running Interactive Components In A Terminal](/docs/terminal-interactive-components) defines the repository terminal hosts, key decoding, text presentation, and terminal-output safety boundary.
- [`qip comply`](/docs/comply) defines Compliance oracle memory ownership, oracle imports, ordered case declarations, and oracle authoring patterns.
- [Uniforms](/docs/uniforms) defines the optional numeric configuration setters that hosts can apply to components.

All component types also operate within [Hard Limits](/docs/hard-limits). [Formats and Encodings](/docs/formats) defines the byte-format and MIME conventions used when components exchange content.

## Evolving Contracts

### Timed And Eventful Components

[Timed And Eventful Component Contract](/docs/timed-and-eventful-components)
defines the current repository ABI. It uses `begin_update_at` and
`finish_update`, applies optional uniform overrides before events, and separates
updates from presentation. Canonical KTX2 is its primary pixel output, but the
contract does not require pixel output. `calculator` implements the
application-style path. `snake` implements fixed-step scheduled updates.

The current Timed and Interactive contracts remain open to change while QIP is
alpha. Repository hosts implement only this current ABI; alpha components must
be rebuilt when the contract changes.

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

1. During pipeline building, a module exporting `tile_rgba32float_64x64` is classified as Tile.
2. Other pipeline modules are classified as Content. This includes the initial render of a Timed or Eventful component.
3. `qip form` uses the Form contract path.
4. `qip comply --with` treats each oracle as Compliance and requires its
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

Timed and Eventful components extend Content. `qip run` invokes their initial
render through the Content contract; it does not open updates or send events.

Content and Tile can also share exports. The presence of `tile_rgba32float_64x64` wins during pipeline classification, so combine the two interfaces only when Tile behavior is intentional.

Compliance oracles target Content implementations because their bridge
drives `render(i32) -> i64`. They are test artifacts rather than Content
pipeline stages and should be passed with `qip comply --with`, not `qip run`.

The component interface is only the first compatibility boundary. Components must not assume unbounded memory, long-running execution, imports outside their documented contract, filesystem access, network access, or a larger runtime around them. See [Hard Limits](/docs/hard-limits) for the constraints that apply after choosing a contract.
