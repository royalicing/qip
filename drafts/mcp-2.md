# QIP Components and MCP 2.0

Research notes on exposing QIP components through the Model Context Protocol,
specification revision 2026-07-28 ("MCP 2.0"):
https://modelcontextprotocol.io/specification/2026-07-28

## What MCP 2.0 is

The 2026-07-28 revision is a substantial redesign over 2025-11-25, and almost
every change moves the protocol *toward* QIP's design:

- **Stateless core.** Protocol-level sessions and the `initialize` handshake
  are gone. Every request carries its protocol version, client info, and
  client capabilities in `_meta`
  (`io.modelcontextprotocol/protocolVersion` etc.), mirrored into HTTP headers
  (`MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`). Servers implement one
  new RPC, `server/discover`, advertising versions, capabilities, and
  identity. Servers needing cross-call state use explicit server-minted
  handles passed as ordinary tool arguments.
- **Streamable HTTP, simplified.** One POST endpoint. Each request gets either
  a single JSON response or a request-scoped SSE stream (progress
  notifications, then the final response). The GET stream, resumability
  (`Last-Event-ID`), and server-initiated JSON-RPC requests are all removed.
  Closing the response stream *is* cancellation. `Origin` validation is
  mandatory (DNS rebinding).
- **MRTR (multi round-trip requests).** When a server needs input mid-call
  (elicitation), it returns `resultType: "input_required"` with embedded
  `inputRequests`; the client retries the original request with
  `inputResponses` plus an opaque `requestState`. Replaces server-initiated
  elicitation entirely.
- **Cacheable, deterministic lists.** `tools/list` results must not vary
  per-connection, should be deterministically ordered, and carry `ttlMs` +
  `cacheScope` (`public`/`private`). Built for static catalogs.
- **Tools.** Typed result content blocks (text, image, audio, resource links,
  embedded resources with base64 `blob`), optional `structuredContent`
  validated by `outputSchema`, and two error channels: JSON-RPC protocol
  errors vs `isError: true` tool-execution results the model can self-correct
  from. `inputSchema`/`outputSchema` now accept any JSON Schema 2020-12
  keywords. Tool names: `[A-Za-z0-9_.-]`, ≤128 chars.
- **Deprecated/moved:** Roots, Sampling, and Logging are deprecated
  (12-month window); long-running work moved to an opt-in Tasks extension
  (`io.modelcontextprotocol/tasks`, polling via `tasks/get`); the old
  HTTP+SSE transport is formally deprecated. Skills-over-MCP and MCP Apps
  (inline interactive UI) exist as extensions.

## Why QIP is a strong MCP citizen

1. **The tool signature already exists in machine-readable form.**
   `inspectRunModuleContract` (`qip_runtime_run.go`) and the dry-run planner
   (`qip_runtime_dry.go`) extract input/output encoding, MIME type, and
   capacities — statically, without instantiating the module, thanks to the
   ABI rule that buffer metadata exports are module constants. A `tools/list`
   response can be generated entirely from static inspection.
2. **The sandbox story answers MCP's biggest security worry.** The spec
   repeatedly warns that tools are arbitrary code execution. QIP Content
   components have zero imports, no WASI, fixed memory, rejected
   `memory.grow`, and per-call timeouts. Worth stating in the server's
   `server/discover` self-description.
3. **Content Recipe CSV is a ready-made manifest**, and
   `content-recipe-to-browser-javascript.wasm` is direct precedent for
   compiling a recipe into a host — a `content-recipe-to-mcp-server`
   generator is a very QIP-idiomatic deliverable.
4. **Statelessness is native.** Each `tools/call` = fresh instance, plan +
   render, return bytes. No session machinery to fake.

## The mapping

**Tool identity.** Component paths sanitize directly into valid tool names:
`text.markdown.commonmark-0.31.2`. Deterministic ordering = sorted catalog.
`tools/list` can carry a long `ttlMs` and `cacheScope: "public"`.

**Input.** One required property: `content` — string for `utf8` components,
base64 for `bytes`. Each statically discovered `uniform_set_<key>` export
becomes an optional numeric property (the export scan gives name and type
i32/i64/f32/f64). Capacity limits go in the description (advisory `maxLength`
is now legal since any 2020-12 keyword is allowed, but it counts characters,
not bytes).

**Output.** MIME type picks the content block: `utf8` + `text/*` → text
block; `image/*` → image block (base64 + `mimeType`); other binary → embedded
resource with `blob`. QIP's exact-MIME discipline is stricter than MCP needs.

**Errors.** Trap → `isError: true` with the trap reason; planner mismatch
(wrong MIME into a chain) → same, with the dry-run explanation. Both fall in
the "model can self-correct" category. Capacity overflow should be reported
with the actual limit so the model can react.

**Form components → MRTR.** The Form ABI's one-prompt-at-a-time loop
(key/label/error triple) maps 1:1 onto `InputRequiredResult` +
`elicitation/create`. Because MRTR retries resend the original params plus
all collected `inputResponses`, the server can stay fully stateless by
replaying every collected value through a *fresh* form instance per retry —
deterministic replay, no serialized wasm state.

**Interactive components don't fit tools** (stateful framebuffer loops). If
ever wanted, the MCP Apps extension is the home, not `tools/call`.

## Gaps to solve

1. **No description metadata anywhere.** MCP tools live or die by
   `description`; the ABI has none, the catalog CSV has no name/description
   columns, and the browser finder hardcodes ~27 `MIME_LABELS` as a stand-in.
   Only 94 of 220 built components declare an output MIME type; only 46 are
   catalogued. Cheapest first: add `description` (and `title`) columns to
   `component-catalog.csv` — no ABI change, matches its curated philosophy.
   Longer term: a statically-readable `description_ptr`/`description_size`
   export pair following the content-type pattern, so the description travels
   inside the wasm.
2. **Numeric-only uniforms.** Fine for converters; a tool needing string
   parameters has no mechanism (the multipart-boundary UUID exception is
   deliberately narrow). Don't solve for MCP alone — expose numeric uniforms
   and revisit.
3. **Tool-count ergonomics.** 46+ tools is heavy for client context. Default
   to a small generic surface — `qip_convert(from_mime, to_mime, content)`
   backed by the finder's chain search, plus `qip_list_conversions` — with
   per-component tools as opt-in config. Plays well with client-side prompt
   caching.
4. **Keep the transpilers off the tool list.** The docs explicitly warn
   against exposing `qip-component-to-{c,zig,swift}` as a service accepting
   arbitrary wasm. Exclude them, or gate to stdio/local-only.
5. **Capacities range 256 B – 167 MB** across the catalog — surface per-tool
   limits in the schema/description rather than letting calls discover them
   by trapping.

## Where to build it

A **`qip mcp serve` subcommand** in the Go binary is the natural home:
wazero, contract inspection, the planner, and the timeout/memory guardrails
already live there, and stdio is what local clients (Claude Code and
friends) speak. Streamable HTTP is a thin layer on top — one POST handler,
`Origin` validation, header/body mirror checks — reusing the router server's
patterns. The Node `qip-router` package's web-standard `fetch(Request)` is
the second embedding point for an npm-installable server. Use the same
wazero interpreter/compiler policy as `qip run` (see the comply
interpreter caveat).

Staged plan:

1. **`qip mcp serve` (stdio):** `server/discover`; `tools/list` from the
   catalog CSV (+ new description column) with `ttlMs`/`cacheScope`;
   `tools/call` = plan + run with existing guardrails. Makes every
   catalogued converter usable from local MCP clients.
2. **Agent-workflow tools:** `qip_dry_run`, `qip_comply`, `qip_score` as
   tools — an agent authoring a component in Zig can validate against a
   compliance oracle without leaving the conversation. The 655-example
   CommonMark oracle (now 655/677/94/2143/1585 across five oracles) is a
   strong demo.
3. **`content-recipe-to-mcp-server.wasm`:** a Content component emitting a
   self-contained stateless MCP server (JS first, mirroring the browser
   generator) from a Content Recipe CSV.
4. **Form → MRTR elicitation**, and optionally docs/catalog as MCP
   **resources** (`resources/list` + `ttlMs`, `qip://` URIs; note the spec's
   `https://` scheme guidance — prefer a custom scheme when the client can't
   fetch directly).

## Open questions

- Should `tools/list` include per-component tools for the full 220-component
  set behind a flag, or stay curated-only like the finder?
- `x-mcp-header` (mirroring tool params into `Mcp-Param-*` headers for
  intermediaries) — probably irrelevant for QIP's use, but cheap to add for
  e.g. an output-MIME param if routing ever wants it.
- Tasks extension: QIP components are fast converters; skip unless whole-site
  WARC recipe runs become tool-callable.
