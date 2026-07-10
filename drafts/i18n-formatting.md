# Locales, Formatting, and i18n as QIP Components

Status: draft research, 2026-07-08

## Thesis

The README already names the enemy: QIP components "do not read the clock, locale, filesystem…". Internationalized formatting — dates, numbers, currencies, plurals, collation — is the software domain where hidden environmental inputs cause the most persistent, expensive, *unfixable-by-the-developer* drift. It is therefore the domain where QIP's "same component, same input, same output" contract is not a nice-to-have but the actual product. This doc inventories the pain, argues the strategic fit, and proposes a concrete module family.

## The pain inventory (what developers actually suffer)

1. **Environment drift in formatting output.** The same `Intl.DateTimeFormat` call produces different bytes on Chrome vs Safari vs Node, and across versions of each, because each embeds a different ICU/CLDR snapshot. The canonical war story: ICU 72 (late 2022) changed the space before AM/PM to U+202F NARROW NO-BREAK SPACE, silently breaking thousands of snapshot tests, string-matching parsers, and downstream regexes across the industry when browsers/Node upgraded. Nobody's code changed; everybody's output did.
2. **Two systems, two monoliths, two revisions.** The backend and the frontend each carry their *own* complete ICU/CLDR/tzdata snapshot — Node's baked ICU, the browser's baked ICU, the mobile OS's baked ICU — versioned independently and upgraded on unrelated schedules. So backend and frontend disagree on the precise bytes for a date, currency, or timezone rendering not because anyone made an error, but because the same question was asked of two different revisions of a monolith. The visible symptoms: SSR hydration errors (React's "text content did not match" with a timestamp in it is a meme), automated tests that pass locally and fail in CI, and subtle diffs that surface as user-reported "the app shows two different times." And it's worse than backend-vs-frontend: the client side is a *fleet* — every user's browser and phone carries whatever ICU revision it shipped with, which the developer cannot control, pin, or even enumerate.
3. **The OS-locale lottery.** Alpine/musl containers ship without locales (`LC_ALL: cannot change locale`); glibc vs musl vs macOS collate and case-map differently; CI formats differently than production. `sort` output depends on `LC_COLLATE` in ways that corrupt diffs and reproducible builds.
4. **Collation instability corrupts data structures.** The famous case: glibc 2.28's collation changes silently corrupted PostgreSQL indexes built with older sort order — locale behavior is load-bearing *inside databases*, and it version-drifts underneath them.
5. **Dead-code elimination structurally cannot work on locale data.** Applications use maybe 5% of the featureset yet carry the whole monolith (full ICU data is ~30 MB), and this isn't a tooling-maturity gap — it's architectural. Tree shakers operate on the static module graph, but locale behavior is reached through *runtime-keyed data lookup*: `new Intl.DateTimeFormat(userLocale, optionsBag)` gives static analysis nothing to prove dead, so every locale, calendar, and collation table stays reachable. Worse, ICU's data isn't in the code graph at all — it's a single opaque memory-mapped blob (`icudt*.dat`) that no linker can slice. The ecosystem's workarounds concede the point: `full-icu` vs `small-icu` Node builds, formatjs asking developers to hand-enumerate locale data imports, date-fns per-locale entry points — all *manual* DCE, which drifts out of sync with actual usage the moment someone adds a locale in a config file. Everyone pays for 300 locales to use three, because no tool can see which three.
6. **CLDR/tzdata churn is invisible.** Currency symbols, date patterns, first-day-of-week, plural rules, and timezone definitions change with each CLDR/tzdata release — correctly reflecting the world, but *silently*, with no diffable record of what your app's output will do after the upgrade.
7. **Locale-sensitive footguns in protocol code.** The Turkish-İ problem (`"i".toUpperCase()` → `İ` under `tr`), locale-dependent `parseFloat`-adjacent parsing, digit-shaping surprises (Eastern Arabic numerals) — case-mapping and number parsing that should have been locale-*independent* but silently weren't.
8. **Intrinsic complexity with poor testability.** Plural categories (Arabic has six), grammatical gender, RTL/bidi reordering, non-Gregorian calendars (Japanese era transitions — Reiwa broke real systems in 2019), currency rounding rules (JPY 0 decimals, BHD 3, CHF 0.05 cash rounding), Indian lakh/crore grouping. Testing across all of it requires mocking `Intl` per environment — which is exactly the thing you can't reliably do.

Pains 1–6 share one root cause: **locale behavior is an ambient, versioned dependency that applications cannot pin.** That is precisely the disease QIP was designed to cure.

## The strategic advantages QIP offers

1. **One artifact, every host — skew becomes structurally impossible.** A QIP formatter bakes its CLDR/tzdata slice *into the artifact*, and the *same bytes* run on the backend (wazero/native), in the browser, and on mobile. There is no second copy to be at a second revision; the host's own ICU is never consulted, so the uncontrollable client fleet's ICU version becomes irrelevant. `format-date.de.wasm` produces the same bytes in a browser, in CI, on a server, in 2030. Snapshot tests never flake; hydration mismatch isn't fixed but *deleted as a category*. No other mainstream approach offers this — not Intl (two monoliths, two revisions), not server-only formatting (loses client interactivity), not JS libs (their data drifts on update, and they still disagree with the server unless versions are locked in two places and every user has updated).
2. **Upgrade-as-diff instead of drift.** Because a CLDR update is a *new component file*, upgrading becomes: run old and new over your corpus, diff the outputs, review the changelog of actual behavior changes. The duel harness from drafts/photocopy.md is exactly this machine. "CLDR 47 changes 214 of your 10,000 rendered strings, here they are" is an enterprise-grade story nobody else can tell — the U+202F incident becomes a reviewed one-line diff instead of a production surprise.
3. **The component boundary is the dead-code-elimination boundary.** QIP doesn't make tree shaking smarter — it moves the selection problem to where it's trivially solvable. DCE fails on locale monoliths because selection happens at *runtime* via data lookup (pain 5); QIP components make selection happen at *composition time* via which `.wasm` files you ship. The "which 5% do we use?" question stops being an unanswerable static-analysis problem and becomes a visible list of artifacts in a directory. Instead of 30 MB of ICU, ship `currency-format.eur-de.wasm` at tens of KB — one locale's date patterns, plural rules, and number symbols are kilobytes in CLDR, so a single-locale, single-task formatter lands in the same size class as existing repo modules. And unlike formatjs-style manual locale enumeration, the shipped set can't drift from the used set, because the artifact *is* the capability: if it's not shipped, calls to it fail loudly at composition, not quietly with fallback-locale output.
4. **Explicit inputs end the lottery.** Timezone, locale, and clock arrive as data (input bytes or the component's identity), never from the environment. Pain 3 and 7 vanish by construction — there is no `LC_ALL` to consult. A `casefold-ascii-identifier.wasm` is Turkish-safe because locale *can't* leak in.
5. **Stable collation as an artifact.** A collator component emitting sort keys gives databases/apps an ordering pinned to component bytes — pain 4's fix. Rebuilding indexes becomes a deliberate component-swap event, not a glibc upgrade side effect.
6. **It compounds existing roadmap items.** The Prompt contract's i18n story ("localized module variants"), the split interactive pipeline's locale renderer variants, and the existing `calendar-gregorian.zig` module all already point here; this research names the through-line.

## Design constraints (and the stance they suggest)

- **Uniforms are numeric; there is no string parameter channel.** A locale tag can't arrive as `?locale=de-AT`. Three options: (a) locale-in-input (structured first line/header), (b) numeric locale enum uniform (fragile, registry-shaped, rejected), (c) **locale as component identity** — `date-format.de.wasm` *is* the German date formatter, the way `dejavu_sans_mono_56_latin1` *is* a specific font at a specific size. Recommend (c) as the default stance: it matches QIP's "small pieces" philosophy, makes payloads minimal, and makes behavior auditable per artifact. Use (a) only for genuinely multi-locale hosts (a CMS rendering 40 languages), via a documented header convention, with the module still shipping only the locales it declares.
- **Single input, so composite requests need a wire shape.** "Format this timestamp" needs (value, timezone, style). Values and IANA zone arrive in the input (e.g. `2026-07-08T14:31:24Z|Australia/Melbourne` or a small structured form); numeric style knobs (date style enum, fraction digits, grouping on/off) fit uniforms perfectly. Where the tensor draft (drafts/tensor-outputs.md) lands, epoch-millis batches become a `i64[n]` tensor in → UTF-8 lines out — bulk formatting as a pipeline stage.
- **Determinism forces a "who owns *now*" answer.** Relative time ("3 hours ago") needs the current instant — passed explicitly, like the Prompt contract's `now_ms`. This is a feature: relative-time rendering becomes testable with frozen clocks by default.

## Approaches for sourcing the locale logic and data

### Approach A — CLDR-to-Zig codegen, narrow tasks (recommended start)

A build-time generator (Go, in `tools/`) reads CLDR JSON (and tzdata where needed), emits Zig source tables per (task, locale), which compile into ordinary QIP modules with the existing Makefile flags. Deterministic codegen, reviewable output, no new runtime dependencies, sizes stay tiny because each module carries only its slice. Start with tasks whose data footprint is small and pain is high: date/time patterns, number/currency symbols and grouping, plural rules (CLDR's plural rules compile to a few branches). The generator's inputs (CLDR version) are pinned in the repo, making every module's provenance explicit.

### Approach B — ICU4X compiled to the QIP shape

ICU4X is the closest prior art in spirit: Rust, `no_std`, modular per-locale/per-feature data slicing (`icu4x datagen`), designed for wasm. Wrapping ICU4X calls in a QIP contract shim and compiling with sliced data would deliver conformant collation, segmentation, and MessageFormat 2 far faster than hand-writing them. Costs: a Rust toolchain enters the build (the repo is Zig/C-centric — though the *contract* is language-agnostic and artifacts are what ship; a sibling builder repo could own this), and binary sizes will be larger than Approach A's hand-rolled tables (still tens-to-hundreds of KB with aggressive slicing, not 30 MB). Right tool for the *hard* tasks: collation sort keys, MF2, segmentation.

### Approach C — Wrap host `Intl` (rejected)

A JS-host-only shim calling `Intl` defeats every advantage: output drifts with the host again, and non-JS hosts get nothing. Named only to be rejected — the entire value is that the component *doesn't* delegate to the environment. (Host `Intl` remains useful as a *duel opponent*: run the QIP formatter against the host's `Intl` over a corpus to document exactly where and why they diverge, turning conformance into a report instead of an assumption.)

**Recommendation:** A for the first wave (formatting, plurals — small data, huge pain relief), B evaluated seriously for collation and MessageFormat 2 (large data/logic where reimplementation is a trap), C never — except as a test oracle.

## Proposed module family (first wave)

| Module | In → Out | Pain addressed |
|---|---|---|
| `date-format.{locale}.wasm` | ISO-8601 or epoch-ms + zone → localized string; style via uniforms | 1, 2, 6 |
| `number-format.{locale}.wasm` | decimal string → grouped/localized string | 1, 5 |
| `currency-format.{currency}-{locale}.wasm` | minor-units integer → formatted amount (correct decimals baked per currency: JPY 0, BHD 3) | 1, 6, 8 |
| `plural-select.{locale}.wasm` | number → CLDR category (`one`/`few`/`many`/…) | 8 |
| `relative-time.{locale}.wasm` | epoch-ms pair (then, now) → "3 hours ago" | 2, plus frozen-clock testability |
| `casefold-ascii-identifier.wasm` | bytes → locale-*independent* casefold | 7 (the anti-locale module — belongs in the family precisely because it refuses locale) |
| `collate-sortkey.{locale}.wasm` (wave 2, likely ICU4X) | UTF-8 lines → binary sort keys (tensor of offsets pairs well) | 3, 4 |
| `mf2-format.{locale}.wasm` (wave 2) | MF2 message + args → string | 8, translation workflows |

Each `{locale}` variant comes from the same codegen; the site gets a demo page formatting one timestamp through six locale modules side by side — a visceral, visible pitch for the whole thesis, and it directly satisfies the existing "Add localized example in multiple languages" TODO.

## Plan

1. `tools/cldr-gen/`: pin a CLDR version, generate Zig tables for date patterns + number symbols + plural rules for an initial locale set (en, de, fr, ja, ar, hi — chosen to force RTL digits, non-Latin, and plural-rule diversity early).
2. Ship `date-format.{en,de,ja}.wasm` + `plural-select.ar.wasm` with golden-output tests (goldens are stable *by construction* — the tests double as the marketing claim).
3. Duel-vs-`Intl` conformance report in `test/` (Node host): documented divergences or byte-agreement, either way explicit.
4. Site demo page (multi-locale timestamp) + a docs page making the "pinned formatting" and "upgrade-as-diff" arguments with the U+202F story.
5. Evaluate ICU4X for collation sort keys as wave 2; decide sibling-repo vs in-repo Rust based on artifact size results.

## Risks & open questions

- **Scope discipline.** "Reimplement ICU" is a tar pit; the strategy only works while each module is a narrow task with a bounded CLDR slice. The codegen tool must make adding a (task × locale) cheap, and the roadmap must resist "general formatter with options" — that's Intl again, in wasm.
- **Correctness vs CLDR intent.** Hand-rolled pattern interpretation (Approach A) can misread CLDR edge cases (era handling, negative-currency patterns, `h11/h23` cycles). Mitigation: the Intl duel in CI over a large generated corpus per locale; divergences either fixed or documented as intentional.
- **Locale explosion in the repo.** 8 tasks × 30 locales = 240 artifacts. Fine for consumers (they take three files), heavy for the repo. Likely answer: repo carries the generator + a demonstration set; full matrices are generated on demand or published as a separate artifact collection. Decide before wave 2.
- **Timezone data.** Zone-aware formatting needs tzdata slices; per-zone data is small but the *choice* of zones to bake per module needs a convention (UTC-only default + `{zone-group}` variants?). Could also split design: a `tz-convert.wasm` stage (epoch+zone → local wall time) ahead of a zone-agnostic formatter — composition doing the modularization, which is the more QIP-native answer.
- **Parsing (the other direction)** — locale-aware *input* parsing (user-typed "1.234,56") is a distinct, harder family with real product value; explicitly out of scope for wave 1, noted so it isn't accidentally promised.

## See also

- [drafts/locale-registry.md](./locale-registry.md) — a secondary, non-adoption offering: a queryable registry of which ICU/CLDR/tzdata revisions each device/runtime carries and what bytes it would produce, with historical locale stacks compiled as QIP oracle components. The registry quantifies the fleet drift described in pains 1–2; the components here are the cure it markets.
