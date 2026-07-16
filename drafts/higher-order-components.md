# Research: Higher-Order QIP Components (`application/wasm` Output)

Question: what happens when a Content component's output content type is
`application/wasm` — a component that emits a component? What patterns does it unlock,
and does it break the security model?

This capability is not an accident of the contract — it has been a design intent since
near the beginning of QIP. The contract was shaped so that components are pure
byte-transforms with zero ambient authority precisely so that component bytes could one
day be *produced*, *verified*, and *moved between machines* like any other content.
This doc makes that intent explicit and works out the patterns and the policy.

Short answers up front:

- The right mental model is **staged computation / partial evaluation**, not closures.
  QIP components have no environment to capture, so the only way to "close over" a
  value is to bake it into the emitted binary. That restriction is exactly what keeps
  this safe and deterministic. It is Zig `comptime`, lifted to the component boundary.
- **Generation is already legal today and creates zero risk.** A component can emit
  wasm bytes right now (`qip run -i cfg.txt generator.wasm -o specialized.wasm`), and
  `wasm-safety-check.wasm` already *consumes* `application/wasm` as input. Emitted
  bytes are inert. All new risk lives at one point: the host **instantiating** the
  output. So the design surface is small: when may a host instantiate, under what
  policy, how many times.
- The security model survives because the QIP capability set is **closed under
  generation**: a generated component gets the same imports as every component — none.
  Unlike `eval` in JavaScript (generated code inherits page authority), a generated QIP
  component can't have *more* authority than its generator, because both have zero.
  The only assets at stake are host resources (CPU, memory, pipeline length), which is
  why the redirect-style depth limit plus the existing budgets are the complete
  mitigation, not a partial one.

## 1. Terminology

- **Generator**: a Content component whose output content type is `application/wasm`.
- **Follow**: the host act of taking a stage's `application/wasm` output,
  policy-checking it, and instantiating it as a new stage. Named after following an
  HTTP redirect: the `Location` header is inert until the client chooses to follow it,
  and clients cap how many times they will.
- **Depth**: number of follows consumed in one pipeline execution. Today's behavior is
  depth 0 — wasm output is just bytes. Depth stays 0 by default forever; follows are
  explicit host opt-in, never triggered by the content type alone.

## 2. Design patterns

### P1. Specializer / currying (the headline pattern)

Take configuration, emit a component with the configuration baked in.

- `qip-intl-subset.wasm`: input `en-AU,fr,ja` → emits a number-format component
  containing only those locales' tables (direct tie-in to the intl datagen plan — the
  datagen tool itself can eventually *be* a component).
- Palette → image-recolor component; stylesheet → HTML-wrapper component;
  banner text → text-render component.
- **Uniform sealing**: take a component + query args, emit the same component with the
  uniforms baked as constants and the setters removed. `?cols=120` becomes part of the
  artifact. Sealed components are fully input-deterministic, cache better,
  content-address cleanly, and strengthen the Immutable story: "this exact behavior,
  forever, no knobs."

### P2. Compilers as components

DSL in, machine in wasm out: regex → matcher, jq-ish query → JSON extractor, CSS
selector → HTML filter, grammar → parser, template → renderer. The compile cost is
paid once; the emitted component is small, fast, and — crucially — *simpler to verify*
than an interpreter, because the dynamic input's structure got compiled away.

### P3. Wasm→wasm transformers (input *and* output are `application/wasm`)

- Hardener: inject/verify a memory maximum, strip unused exports, reject on
  `memory.grow` (the knowledge in `internal/wasminspect` as a component).
- Instrumenter: add trace counters or render-time budgets.
- Adapter/shim: wrap a Content component to present another contract's exports.
- Optimizer/minifier stages.

These compose into wasm-processing pipelines where components are just content —
QIP's content-first philosophy eating its own tail, in a good way.

### P4. Linker / pipeline fuser

N components in (tar or WARC of wasm records) → one fused component out. A whole
recipe chain becomes a single distributable, benchable, pinnable artifact.

### P5. Certified generation (verify-then-instantiate)

```
qip run -i config.txt generator.wasm -- modules/application/wasm/wasm-strict-profile.wasm modules/application/wasm/wasm-bounded-loops.wasm
```

This composes **today**: the generated component flows through the safety checker in
the same pipeline. This is the eBPF model — programs are loaded only through a
verifier — and QIP already owns both halves. A follow-enabled host should run the same
gate internally before instantiating anything.

### P6. Packed / self-extracting components

A compressed container component that emits the real component. Ship one packed intl
artifact; expand to the specialized per-locale component at install time. (Watch the
decompressor-vs-fixed-bound-loops tension noted in the intl plan.)

### P7. Form-driven component wizards

A Form component collects parameters; its result feeds a generator; out comes a
finished component. "Build your own QR style / chart theme / validator" without a
toolchain — the end-to-end flow is prompts → component.

### P8. Spec-to-comply generation

Feed a spec/fixture file to a generator that emits a `qip comply` module. Test
authoring becomes a content transform.

*Fun corollary:* a quine — a component that outputs itself — is a legal fixed point.
The depth limit turns it from a hazard into a party trick, which is a nice smoke test
that the policy design is right.

## 3. Security analysis

### What generation cannot do

A generated component is instantiated by the same host path as a static one: no WASI,
no imports, fixed memory, explicit input/output. There is no capability for the
generator to smuggle to its child because neither has any. The classic dynamic-code
disasters (JS `eval`, JVM classloaders, template-injection RCE) all share one root
cause — generated code inheriting ambient authority of its runtime — and that root
cause is structurally absent here. This is the confused-deputy analysis from the
architecture doc: the deputy is already as small as it gets, and generation doesn't
grow it.

Determinism also survives: generated bytes are a pure function of
(generator bytes, input bytes), so a tower of generators is exactly as reproducible as
a single component. Same inputs → same intermediate components → same final output.
`eval` never had that property; staged QIP does.

### What generation can actually threaten, and the mitigations

1. **Resource amplification (depth).** A generator emits a generator emits a
   generator… or a quine loops forever. Mitigation: `--follow-wasm <n>` depth budget,
   default 0. Legitimate patterns are shallow — depth 1 covers P1–P8; depth 2 covers
   generator-of-generator; recommend a hard ceiling around 4, not curl's 50, because
   nothing honest is that deep.
2. **Resource amplification (width/size).** One follow can still emit a max-size
   component, or a WARC full of them. Mitigation: nothing new — per-stage
   `--max-memory`/`--timeout-ms` already apply to every instantiated stage, and output
   caps bound emitted size. Add a total-follows-per-execution count (depth × width) in
   router contexts.
3. **Policy laundering.** Generated bytes contain `memory.grow`, ambient imports,
   shared memory, unbounded loops. Mitigation: **policy monotonicity** — a followed
   component passes the *same* gate as a static one, and the effective policy of a
   child is `min(parent policy, host flags)`; a follow can never loosen. Run the
   safety-check/wasminspect gate on every followed artifact before compilation.
4. **Auditability loss.** A static pipeline can be reviewed before running; a dynamic
   one materializes mid-flight. Mitigations: `--emit-stages <dir>` dumps every
   followed artifact; hosts log the content hash of each followed component; caching
   (below) makes the artifacts inspectable by default rather than ephemeral.
5. **Browser wrinkle (real deployment constraint).** Compiling wasm bytes produced at
   runtime requires CSP `wasm-unsafe-eval` (or `unsafe-eval`). Static components can
   ride stricter CSPs; a follow-enabled `<qip-preview>` cannot. Document this loudly:
   enabling `follow-wasm` in the browser is a CSP decision, not just an attribute.
6. **Verifier friendliness.** Generated code must pass the fixed-bound-loop check like
   everything else. Machine-emitted code is actually *easier* to keep verifier-clean
   than compiler output — generators should emit the blessed counter-loop shape by
   construction ("certified codegen" guideline for generator authors).

Net: the "maximum levels of components-within-components" knob is necessary and —
combined with the budgets that already exist — sufficient. The model doesn't crack; it
was built for this.

## 4. Distribution: generated wasm synced between machines

Everything above stays interesting on one machine. It becomes a different class of
capability once you notice that intermediate and final wasm artifacts are *ideal
network payloads*. Five properties line up:

- **Content-addressed**: the hash is the identity; caching, dedup, and pinning are free.
- **Deterministic**: any receiver can re-derive the artifact from
  (generator, input) and check it got the same bytes — provenance by recomputation.
- **Zero-capability**: receiving a component is safe by construction; a leaked or
  stolen component leaks logic, never credentials or reach.
- **Machine-verifiable**: the safety gate runs at arrival, eBPF-style. Trust the
  verifier, not the sender.
- **Small and budgeted**: fixed memory and output caps mean the receiver knows the
  cost ceiling before running anything.

The one hard rule for every pattern below: **verify at arrival, every time the bytes
cross a trust boundary.** The sender's gate doesn't count. Policy monotonicity applies
across machines exactly as it does across pipeline stages.

### D1. Client ⇄ server: write-once validation

The classic drift problem — validation logic written twice, in the server language for
authority and in JavaScript for UX, diverging forever. Instead: a generator compiles
the schema/rules once into a validator component; the **same bytes** run in
`<qip-preview>` on the client for instant feedback and in the server host as the
authoritative check. Byte-identical behavior on both tiers is not "kept in sync" — it
is the same artifact, pinned by hash. Reading-and-validating user input becomes: user
input bytes → the one true validator → errors or normalized value, on whichever
machine is convenient.

### D2. Send code to data

The reverse direction: a client (or coordinator) compiles a query/filter/transform
into a component and sends it to where the data lives; the server verifies and runs it
against bytes the client could never download. This is the pattern the industry keeps
rebuilding as one-off sandboxed DSLs — SQL, jq, CEL, Rego, Lua-in-Redis, eBPF — because
sending real code was historically too dangerous. A verified zero-capability component
is the general-purpose answer: the server decides exactly which bytes the visitor
logic sees, and the depth/budget policy bounds what it can cost.

### D3. CI: generate once, fan out to runners

A pipeline's first job runs the generator (specialized linter, schema checker, fixture
comparator) and publishes the wasm; N runners fetch by hash, verify, and run it
against their shard. No toolchain setup on runners, no version skew between them, and
the artifact cache is shared fleet-wide because keys are
`hash(generator) ⊕ hash(input)`. This is the hermetic, content-addressed build step
that Bazel/Nix achieve with heavy machinery — at the single-transform scale, with a
sandbox instead of a chroot.

### D4. Cloud fan-out and per-tenant specialization

Today distributed systems push either config (inert, interpreted by resident code) or
containers (heavy, privileged). A specialized component is the missing middle: push
small verified *behavior* with a fixed budget. Concretely: a coordinator seals
per-tenant or per-route transforms and broadcasts them to edge/worker nodes; each node
gates and runs them. Multi-tenant SaaS gets tenant-specific logic without tenant code
inside the trust boundary. And because execution is deterministic, any node's result
can be spot-checked by re-execution elsewhere — cheap byzantine auditing that
config-push and container-push can't offer.

### D5. Data that carries its own reader

Version skew between sender and receiver is normally solved by shipping schemas and
praying both ends interpret them identically. Alternative: the sender ships (or serves
by hash) the exact decoder component for its format alongside the data. WARC archives
plus recipe components already point this way; generation closes the loop — the
producer *derives* the reader from the same source of truth that shaped the bytes.

### D6. Data capsules: wasm as the serialization format

Take D5 to its conclusion and the reader and the data fuse into one artifact. The
flow: user input → encoder component → out comes a new component with the value baked
in (a **capsule**) → the capsule travels to a server, a mobile device, or back down to
a frontend → the receiver *executes* it and validates that the output bytes match the
format it needs. Nobody picked JSON vs Protobuf; the wire format is `application/wasm`
and the only agreement between sender and receiver is the **output contract**.

That last point is the honest version of "no serialization format": agreement is not
eliminated, it is *relocated*. Instead of both ends agreeing on wire encoding + schema
version (and upgrading in lockstep), the sender is free to encode however it likes and
the receiver validates decoded output. Version skew becomes a sender-side concern: an
old client's capsule emits the old shape, a new client's the new shape, and the
receiver accepts whatever its output validator accepts.

The routing variants are symmetric because a capsule is inert content:

- Client seals input → server executes + validates (untrusted-input ingestion).
- Server seals a value → frontend or mobile executes it (personalized/prepared state
  pushed down; the payload could even be an `Interactive` component).
- Any hop forwards the capsule *unchanged* — hash and integrity survive relay — or
  **re-seals**: execute, validate, emit a fresh canonical capsule it now vouches for.

**The capsule profile (key enabler).** The minimal constant component needs no loops
at all: `output_ptr()` points directly at the data segment and `render()` returns its
length — zero copies, provably O(1). That is a *statically recognizable* subset:
straight-line code, no loops, no indirect calls, data segment + trivial exports. So a
receiver can demand "capsule-profile only" and get execution cost guarantees stronger
than any JSON parser gives — a graded trust ladder: capsule profile ⊂ strict profile ⊂
general wasm. `wasm-make-constant.wasm` (Phase 1 demo) is exactly the capsule
primitive; encoder components are it plus canonicalization.

**Where capsules genuinely win:**

- **Canonicalization travels with the value.** A date typed in any locale convention
  arrives as a component that emits ISO 8601; the messy original never leaks past the
  encoder. (Direct tie-in: the intl components are natural encoder factories.)
- **One artifact, many tiers.** The same capsule validates on the server and renders
  on mobile; uniforms can select representations (compact vs pretty, subset views)
  without re-serializing.
- **Long-lived stored values.** An event-sourcing log of capsules stays executable and
  re-interpretable years later — Immutable applied to data. No "we can no longer parse
  v2 records" archaeology.
- **Fleet version skew** (as above) — the strongest practical argument.
- **Uniform infrastructure**: one content type, one integrity scheme (hash), one gate,
  one budget model for every payload in the system.

**Where capsules lose, stated plainly:**

- **Envelope overhead.** A wasm module wrapping three form fields costs a few hundred
  bytes of header/exports where JSON costs ~zero. Fine for documents and rich values;
  silly for tiny hot-path RPC fields at high QPS.
- **Per-payload execution cost.** Instantiate + run + validate beats a JSON parse only
  rarely. Mitigation: capsule-profile execution is near-free, and output caches by
  component hash — but it's still more machinery than `JSON.parse`.
- **Opacity.** JSON is greppable, diffable, loggable, WAF-inspectable. A capsule is
  opaque until executed. Determinism softens this (log the executed output; `qip run
  capsule.wasm` is one command) but ops tooling has to learn the shape.
- **Validation is still mandatory and the pattern can seduce you into skipping it.**
  Executed capsule output is untrusted bytes, exactly like a parsed JSON body — the
  architecture doc's rule ("component output is untrusted until the next boundary
  validates it") applies with zero discount. A receiver that trusts output because
  "it came from wasm" has recreated the deserialization-gadget bug class in a new
  costume. This warning belongs in any published doc in bold.
- **Attacker-supplied compute.** Executing sender-chosen code is the whole point, and
  the whole risk. The strict profile was built for precisely this (fixed memory, no
  imports, bounded loops, timeouts) and the capsule profile reduces it to ~nothing,
  but the receive-side gate must be mandatory, not advisory, for network ingress.
- **Ecosystem reach.** JSON runs everywhere; capsules need a QIP host at every
  endpoint that touches them.

Rule of thumb: capsules earn their keep when the value is *rich* (needs
canonicalization, multiple representations, longevity, or cross-tier identity) or the
fleet is *skewed*; plain JSON keeps winning for small, hot, human-debugged payloads.
The exploration task is mapping that frontier with real measurements, not defending
either extreme.

## 5. Hard problems this helps solve

The honest pitch, mapped to industry-scale pain:

1. **Supply-chain trust.** Reusable code today means installing packages *inside* your
   trust boundary with your process's full authority — the xz/left-pad problem.
   Components (and generated components) are inert, zero-capability, machine-gated
   artifacts. Reuse stops implying trust.
2. **The mobile-code problem.** Java applets, ActiveX, and mobile agents all died on
   the same rock: transported code inherited runtime authority. Forty years of
   workarounds produced today's zoo of purpose-built sandboxed DSLs (D2's list). A
   verified, deterministic, zero-capability artifact is the reusable substrate those
   DSLs keep approximating.
3. **Dual-implementation drift.** Client/server validation, prod/CI checks, mobile/web
   formatting — anywhere the same logic is written twice in two languages, it diverges.
   One generated artifact, one hash, every tier (D1).
4. **Non-hermetic builds and flaky CI.** "Works on my machine" is ambient authority in
   disguise. Deterministic budgeted transforms are hermetic by construction and cache
   globally by content hash (D3).
5. **Config-vs-code deployment.** Fleets push YAML because pushing code is scary; then
   the YAML grows a Turing-complete interpreter anyway. Push small verified behavior
   instead (D4).
6. **Deploying AI-generated code.** Generation is no longer the bottleneck; trusting
   the output is. An agent's deliverable becomes a sealed, hash-pinned, verifier-passed
   artifact with a fixed budget — reviewable as a transform, not trusted as app code.
   With generator components, even the *generation step* is deterministic and
   auditable.
7. **Every app reinventing plugins.** VS Code, Figma, browsers — each solved plugin
   sandboxing from scratch. A host that accepts gated components gets a plugin system
   whose API is "bytes in, bytes out" and whose security review is the QIP profile.
8. **Format version skew.** Ship the decoder, not the schema (D5).
9. **The serialization-format treadmill.** XML → JSON → Protobuf → whatever's next,
   each migration a fleet-wide lockstep upgrade. Capsules (D6) move the agreement from
   wire encoding to validated output contract, so sender and receiver stop needing to
   version their encodings together.

## 6. Host surface proposal

**Phase 1 — bless what works, add nothing to the runtime.**
Document the pattern; `qip run -i cfg generator.wasm -o out.wasm` is already the
human-in-the-loop "expand" flow (optionally wrap it as `qip expand` for
discoverability, with the safety gate built in). Ship two demo generators:

- `wasm-make-constant.wasm` — the K combinator of QIP: input any bytes, emit a
  component that outputs exactly those bytes with the right content type. Trivial,
  wildly illustrative, and implementable without a compiler: splice the payload into a
  prebuilt wasm template's data segment and patch the LEB128 lengths. Establishes the
  template-splicing technique every Zig generator will reuse.
- `wasm-seal-uniforms.wasm` (P1 sealing) or a `wasminspect`-based hardener (P3) as the
  wasm→wasm example.

**Phase 2 — follows in the CLI.**
`qip run --follow-wasm <n>` (echoes `curl --max-redirs`; default 0): when a stage's
output content type is `application/wasm` and depth budget remains and there are no
further static stages consuming wasm as bytes, the host gates the bytes
(policy monotonicity + safety check), instantiates, and continues the pipeline through
the new stage. Add `--emit-stages <dir>` for audit. Input semantics stay linear: the
follow covers transformers/expanders/fusers (the wasm output *is* the payload);
config-then-payload specialization keeps using the two-step expand flow rather than
inventing multi-input pipeline syntax now.

**Phase 3 — browser and router.**
`<qip-preview follow-wasm="1" max-memory=...>` with the CSP caveat
documented; recipes that emit `application/wasm` let the router build per-route
specialized components. Add content-addressed memoization everywhere: cache key =
`hash(generator) ⊕ hash(input)` → generated component. Specialization becomes
pay-once, and the cache doubles as the audit trail.

## 7. Prior art worth citing in the doc

- **Futamura projections / partial evaluation** — P1 is the first projection;
  a self-applicable specializer is the (distant) third.
- **Zig `comptime` / MetaML / LMS** — staged programming; QIP components are written
  in Zig, so "comptime at the component boundary" will land with the audience.
- **eBPF** — verify-then-load as a hard architectural rule; P5 is exactly this.
- **HTTP redirects** — inert-until-followed plus a follow cap; the user-facing analogy.
- **JVM classloaders** — the cautionary tale: dynamic loading *with* ambient authority.
  QIP's zero-capability closure is the structural fix.

## 8. Deeper cuts

### 8.1 Security, round two

- **The compiler is the new attack surface.** Executing untrusted wasm means
  *parsing and compiling* untrusted bytes first, and wasm engines have had
  validation/compilation CVEs. The gate order matters: run `wasminspect`-style
  structural checks (in memory-safe Go) *before* handing bytes to the engine, and
  bound compilation resources, not just execution — a compile bomb (deeply nested
  blocks, giant type sections, thousands of locals) attacks the receiver before
  `render` ever runs. Module-size and section-count caps belong in the remote profile.
  The capsule profile helps here too: less grammar accepted → less parser surface.
- **Canonicalize, don't just verify.** Custom sections (names, producers, arbitrary
  vendor sections) are a covert channel through any system that relays capsules. The
  ingress gate should *normalize*: strip custom sections and re-encode
  deterministically, so what gets stored/forwarded is the canonical form of the
  behavior, nothing more. Bonus: canonical form makes content-addressing stable across
  toolchain noise.
- **Hash pinning is integrity, not authorization.** Content addressing proves "these
  are the bytes"; it says nothing about *who may submit them*. Server→client pushes
  want a signed manifest over hashes; client→server ingress relies on the gate plus
  rate/size limits, same as any upload endpoint. Don't let the hash's cryptographic
  smell stand in for an authz decision.
- **Declared output content type is a claim, not a fact.** A hostile capsule can
  export `output_content_type = text/html`. Receivers must match declared type against
  what the pipeline position *expects*, and still treat the bytes as untrusted for
  that type (sanitize HTML, validate JSON). Type laundering into a privileged sink is
  the realistic attack, not sandbox escape.
- **Never enable follow on ingress paths.** Untrusted-source pipelines should run
  with depth 0 unconditionally — a user payload that emits wasm must terminate as
  bytes. Follow budgets should be assignable per input source, not just per
  invocation.
- **Multi-tenant timing.** Components hold no secrets, but a host running attacker
  capsules in-process with secret-bearing code inherits ordinary Spectre-class
  wasm-multi-tenancy concerns. The boring fix applies: process-isolate execution of
  network-received components when the host handles secrets.

### 8.2 Performance

- **The template-recognition fast path is the big one.** Instantiation/compilation,
  not execution, dominates per-payload cost. But capsules from the same encoder share
  their entire code section and differ only in data. So: cache compiled code keyed by
  *code-section hash* (not module hash), and for known templates skip the engine
  entirely — recognize `wasm-make-constant`'s code section by hash and memcpy the data
  segment out. Capsules then degrade gracefully to the speed of a plain serialization
  format when the receiver knows the template, while keeping component semantics for
  receivers that don't. This single optimization likely decides whether D6 is viable
  at request rates.
- **One instance, many renders.** The contract already blesses repeated `render()`
  calls on a live instance. A server validating a stream of same-schema payloads
  should instantiate the validator once and feed it inputs — amortizing instantiation
  exactly like a prepared statement.
- **Memory floor.** A 1 MiB default linear memory per instance is heavy at high QPS;
  capsules should declare one 64 KiB page unless the payload needs more. Budget
  defaults for the remote profile should be small-first.
- **Fleet AOT.** D4 nodes can AOT-compile received components once and cache native
  code by content hash — the eBPF JIT model. Matters most where JIT is restricted
  (below).
- **Measure against the honest baseline.** `qip bench` should grow a mode comparing
  capsule ingest (gate + instantiate + render + validate) against `JSON.parse` +
  schema-validate for the same logical payload, across sizes. That produces the
  crossover chart §8's open question asks for.

### 8.3 Cross-platform

- **Bit-identical execution is achievable but must be specified.** Core wasm's only
  real nondeterminism is NaN bit patterns (and relaxed SIMD, which the strict profile
  must simply ban). Pin the QIP feature set explicitly — MVP plus an enumerated short
  list (e.g., bulk memory?) — so generators emit lowest-common-denominator modules and
  "runs identically everywhere" is a spec claim backed by a determinism comply module,
  not folklore. Little-endian-everywhere is one of the quiet reasons wasm-as-format
  works at all.
- **Engine limits differ.** Browsers restrict synchronous compilation on the main
  thread (use `instantiateStreaming`); engines differ on module size, local counts,
  and stack depth. The canonical-form gate can enforce conservative structural limits
  so a capsule accepted anywhere runs everywhere.
- **iOS and JIT-restricted environments.** Platforms without JIT permission fall back
  to interpreters (wazero interpreter mode, wasm3, JSC constraints inside apps).
  Interpreted execution magnifies per-payload cost — which makes the capsule profile
  and the template fast path *more* valuable on mobile, not less: the fast path never
  invokes the engine at all.
- **The host matrix is the product surface.** CLI (Go/wazero), browser elements, Swift
  native, mobile. Each needs the same gate semantics; a shared conformance suite
  ("does this host enforce the remote profile identically?") is what keeps
  "sync it to mobile" from meaning "debug it on mobile."

### 8.4 Testing

- **Generators need two-level tests, and the levels disagree on golden strategy.**
  Level 1: generator output bytes (byte-goldens — brittle but exactly what
  reproducibility CI wants). Level 2: *behavior* of the emitted component (execute it,
  snapshot outputs — stable across generator refactors). Keep both; they catch
  different regressions.
- **The specializer equation is the master property.** For a specializer `gen`:
  `run(gen(config), x) == run(general, config ⧺ x)` for all inputs — the emitted
  component must agree with the general component it specializes. This is
  property-testable with random `config`/`x`, is the Futamura correctness statement in
  executable form, and `qip comply` is its natural home.
- **Hereditary safety is a fuzz target, not a promise.** Fuzz generators with
  arbitrary config; assert every emitted module passes `wasm-safety-check`. Separately,
  fuzz the gate itself with wasm-smith-style arbitrary modules: it may accept or
  reject, it must never crash or hang — the gate is security-critical code and
  deserves security-critical fuzzing.
- **Round-trip property for capsules:** value → seal → gate → execute → validate ≡
  value, for arbitrary values including hostile ones (embedded nulls, wasm magic bytes
  inside the payload, max-cap sizes).
- **A standing red-team corpus in `test/`:** the quine, a generator-of-generators, a
  compile bomb, a max-size emitter, a custom-section smuggler, a content-type
  launderer. Depth limits, budgets, and normalization each get a permanent adversary
  that CI runs forever.
- **Cross-host determinism matrix in CI:** execute the same artifacts under wazero,
  Node, and a headless browser; compare output hashes. This turns the determinism
  claim from §4 into a regression test.

## 9. Open questions

- Should the spec define **hereditary safety** — a normative line that a conforming
  generator's output must itself satisfy the strict profile — or leave it as host
  policy only? (Leaning: host policy enforces, spec recommends; generators advertise
  it via comply modules.)
- Uniform pass-through: when a follow inserts a generated stage, do query-arg uniforms
  apply to it? (Leaning: no — sealed/generated components should be knob-free; that's
  the point.)
- Router cache invalidation: generated artifacts are pure, so the only invalidation is
  generator-hash or input-hash change — but the cache needs a size/GC policy before
  router use.
- Does `Interactive`/`Tile`/`Form` output ever make sense from a generator? Nothing in
  the analysis is Content-specific; the follow gate should classify the emitted
  contract with the existing deterministic export detection.
- Transport/registry story for synced artifacts: fetch-by-hash over plain HTTP is
  enough to start (the hash *is* the integrity check), but do we eventually want an
  OCI-artifact or content-addressed registry convention so hosts, CI runners, and
  browsers share one resolution scheme?
- Receive-side policy defaults: a host accepting components over the network should
  probably gate harder than a local `qip run` (mandatory safety check, mandatory
  fixed memory, tighter timeouts). Is that a named profile — e.g. a "remote
  profile" — in the docs?
- Determinism-based auditing (D4) assumes bit-identical wasm execution across
  runtimes; that holds for the strict profile (no NaN-payload games, no threads), but
  it deserves a comply module that proves it per host.
- Should the **capsule profile** (D6: loop-free, no indirect calls, direct
  data-segment output) be a formally specified verifier tier — checkable by
  `wasm-safety-check` / `qip score` — so receivers can require it by name? It's the
  piece that makes "execute untrusted payloads at ingress" defensible at scale.
- Capsule economics need measurement, not argument: envelope bytes vs JSON for
  realistic payload sizes, instantiate+execute+validate latency vs `JSON.parse`, and
  where the crossover sits. A benchmark page would settle the "when to use this"
  question empirically.
