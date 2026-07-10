# Retiring `Form`: A Cross-Host `Prompt` Contract

Status: draft research, 2026-07-08

## Goal (from README TODO)

Retire the web-shaped `Form` framing in favor of a future cross-host `Prompt` contract: sequential prompts with recoverable failure, `submit(input_size, now_ms)` for state changes, and `render(0)` for the current semantic projection/output.

## Why Form is the wrong shape

The current Form ABI (`docs/form_abi.md`) exports web-form furniture: `input_key`, `input_label`, `error_message_ptr/size`, all driven through `render(input_size)`. Three structural problems:

1. **It's presentational.** Keys and labels presume a fields-on-a-page UI. A terminal wizard, a chat surface, or a voice host has no "fields"; they have *turns*. The contract should carry semantics (what is being asked, what state we're in) and leave presentation to the host — the same division Interactive draws between scene state and pixels.
2. **It's static.** A form is a fixed set of named inputs. Real interactions branch: the answer to "encrypt output?" determines whether a passphrase is asked at all. Sequential prompts subsume forms (a form is a wizard with no branches) but not vice versa.
3. **It overloads `render`.** One function both mutates state and reports it, so hosts can't re-display without side effects, and "validate this input" is indistinguishable from "show me where we are."

## Core design

A Prompt component is a deterministic state machine driven by an explicit event loop. Separating command from query is the heart of it:

- **`submit(input_size: i32, now_ms: i64) -> i32`** — the only state mutation. Host writes the user's answer (UTF-8) at `input_ptr`, passes the current time explicitly, and gets a result code:
  - `0` — accepted; state advanced.
  - `>0` — **recoverable failure**: input rejected, state unchanged, a module-chosen reason code (host may localize/map; `error_message_ptr/size` optionally carries module text as today). The user re-answers.
  - **trap** — contract violation or broken invariant. Unrecoverable, matching QIP's trap-loudly philosophy: recoverable errors are for *user input*, traps are for *bugs*.
- **`render(0) -> i32`** — pure projection of current state into the output buffer. No input consumed (`input_size` fixed at 0), no state change, callable any number of times, idempotent. Hosts re-render freely: after every submit, on resize, on reconnect.
- **`prompt_state() -> i32`** — the tiny machine-readable phase enum so hosts don't parse output to branch: `0 awaiting_input`, `1 complete`, `2 failed_terminal`. Everything else lives in `render(0)`'s projection.

Plus the standard buffer plumbing (`input_ptr`/`input_utf8_cap`, `output_ptr`/`output_utf8_cap`) unchanged from Content, and zero-arg function exports only, per the ongoing migration.

### `now_ms` is the interesting parameter

Prompt modules never read a clock — time arrives as an explicit argument, exactly once per state change. This keeps the QIP determinism law intact in the presence of interaction: **a session is fully described by its transcript** `[(answer_bytes, now_ms), …]`, and replaying a transcript reproduces every intermediate state and the final output, bit for bit, on any host. Consequences worth designing around rather than merely permitting:

- **Testing:** a transcript file *is* a test fixture. `qip prompt run wizard.wasm --transcript session.txt` in CI asserts the final `render(0)` bytes. No mocking, no flakes.
- **Undo/back:** no snapshot machinery needed — re-instantiate and replay the transcript minus the last entry. Determinism makes time travel a for-loop. (Memory snapshotting would be faster for huge sessions; it's an optimization, not the model.)
- **Resume/handoff:** a half-finished session moves between hosts (start in CLI, finish in browser) by shipping the transcript, not memory images.
- Hosts SHOULD pass real wall-clock ms; modules MUST treat it as opaque monotonic-ish data (timestamps in results, timeout logic like "code expired"), never as entropy. Randomness stays a separate concern (the `random_ptr` TODO).

### What does `render(0)` output? The projection format question

Three candidates:

- **(a) Plain UTF-8 prompt text.** Maximally simple; but hosts can't distinguish prompt from progress from final result without `prompt_state`, and structured needs (choices, defaults, input hints) get smuggled into prose.
- **(b) Full JSON document** (state, prompt, choices, error, result). Machine-friendly; but every module now embeds a JSON *encoder* (fine) and every host a parser (fine), while simple echo-style hosts lose the ability to just print the bytes. Heavier than most wizards need.
- **(c) Line-oriented semantic text** — first line is a directive, rest is content:

  ```
  ask: Passphrase (min 12 chars)
  ```
  ```
  choose: Output format | json | yaml | toml
  ```
  ```
  done
  <final output bytes follow on subsequent lines / or via a final content-type>
  ```

Recommendation: **(c)**, with the directive vocabulary deliberately tiny (`ask`, `ask-secret`, `choose`, `confirm`, `note`, `done`). It reads as plain text in the dumbest host (`cat`-able), parses with `splitN` in the smartest, and grows by adding directives without versioning pain. JSON (b) remains expressible later as an alternate projection selected by a uniform if a host genuinely needs it — the contract doesn't have to choose forever, because `render(0)` is pure and cheap to call.

When `prompt_state() == complete`, `render(0)` returns the session's *result* — which may declare a content type via the standard optional exports. This is the quiet superpower: **a completed Prompt component is a pipeline source.** `qip run wizard.wasm config-validate.wasm html-page-wrap.wasm` becomes "interactively gather, then transform" with no new composition rules.

## Approaches for getting there

### Approach A — New contract, clean break (recommended)

Define Prompt as a new contract in `component-contract.md` + `docs/prompt_abi.md`; add `qip prompt` (readline loop + `--transcript` replay) as the reference host; port the existing Form examples; keep Form *detection* working but frozen ("legacy, see Prompt") for one deprecation cycle, then delete `formcommand.go` and `form_abi.md`. Clean because the semantics genuinely differ — `render(input_size)`-as-mutator vs `render(0)`-as-projection cannot coexist in one export set without flags and sadness.

### Approach B — Evolve Form in place (rejected)

Keep the Form ABI, add `submit`, reinterpret `render`. Rejected: every existing Form module would be half-migrated forever, detection needs to disambiguate old-render from new-render behavior on identical export names, and the web furniture (`input_key`/`input_label`) lingers as contractual appendix. The installed base is small (this repo's own examples); a break is cheap *now* and expensive later.

### Approach C — Prompt core + optional semantic-hint exports (fold into A)

The one thing Form's `input_key` did well: autofill and accessibility hints (`username`, `email`) that browser hosts map to `autocomplete` attributes. Rather than losing that, allow an *optional* hint in the projection itself — `ask: Email address @hint=email` — keeping hints per-prompt (where they belong; a key-per-module export can't describe a branching wizard's third question anyway). This is a detail of (c)'s directive grammar, not a separate contract surface. Fold into A.

**Recommendation:** A with C's hint grammar. B dies.

## Host mapping sketches

- **CLI (`qip prompt`):** loop { `render(0)` → print; `ask-secret` → no-echo read; `choose` → numbered menu; read line → `submit(n, now)`; nonzero → print error text, repeat } until `complete`; then `render(0)` to stdout (or into a pipeline). `--transcript in.txt` replays; `--record out.txt` captures.
- **Browser (`<qip-prompt>` element):** same loop; directives map to input types (`ask-secret` → `type=password`, `choose` → radio/select, hints → `autocomplete`). One live instance, `render(0)` after every interaction — mirroring how the Interactive runtime already keeps one instance and re-renders.
- **CI/scripted:** transcripts, as above. Also `echo -e "answer1\nanswer2" | qip prompt run w.wasm` for the unix-brained.

## Migration & implementation plan

1. Spec: `docs/prompt_abi.md` + a Prompt section in `component-contract.md`; directive grammar with test vectors (including the `@hint` and multi-byte UTF-8 cases).
2. `internal/promptcommand.go` + contract detection (`submit` + `prompt_state` exports distinguish Prompt from Content/Form unambiguously).
3. Reference module in Zig (a 3-step wizard with one branch and one validation failure path) + transcript-replay tests, including the invalid-then-valid recovery pattern the validator TODO already calls for.
4. Port Form examples; mark Form ABI docs legacy.
5. Browser element in the client runtimes; site demo page.
6. Removal release: delete Form command/detection/docs.

## Open questions

- **Composite screens:** some hosts want to show 3 related questions at once. v0 stance: one prompt per turn; a host MAY look ahead by speculatively submitting? No — speculation mutates. Honest answer: batching is a host presentation trick over sequential semantics (collect three answers, submit serially); if a real need for atomic multi-field turns emerges, add a `group:` directive later rather than complicating v0.
- **Timeout semantics:** can a module *expire* (`submit` after too long → recoverable failure)? Yes, trivially, since it sees `now_ms` — but hosts should be told via a directive (`note: expires in 60s`) rather than discovering it by rejection. Convention, not contract.
- **i18n:** module owns its text, so localization = localized module variants or a `uniform_set_locale` selecting embedded strings. Same story as every other QIP component; no special machinery.
- **Secret handling:** `ask-secret` answers land in `input_ptr` like any bytes and persist in module memory until overwritten. For the CLI host, `--record` MUST redact secret-directive answers by default (`@redacted` placeholder breaks replay unless `--record-secrets` is explicit). Worth a line in the security model doc.
