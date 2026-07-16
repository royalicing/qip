# Plan: Compressed ICU/CLDR Locale Data As QIP Components

Goal: `Intl`-style formatting (numbers, dates, plurals, lists, display names) as QIP
components covering *all* CLDR modern-coverage locales (~350+), at a size that makes
"embed every locale" the obvious default rather than something you apologize for.

## 1. Correcting the premise slightly (it makes the plan better)

`en_AU.txt` in the ICU repo is already **vertically** delta-encoded: it only contains
overrides against its inheritance chain (`en_AU` → `en_001` → `en` → `root`), and ICU's
`.res`/`icudt.dat` format additionally has a shared string pool (`pool.res`). So ICU is
not naive. The verbose repetition you've seen is in the *resolved/distributed* forms:
cldr-json full trees, FormatJS per-locale JS bundles, per-locale JSON files apps ship.

The wins ICU leaves on the table — and the ones we go after — are:

1. **Horizontal sharing.** Vertical inheritance only captures parent/child redundancy.
   But `es_MX`, `pt_BR`, `fr_CA` etc. share enormous amounts of data with locales that
   are not their parents (identical month-name sets, identical number patterns,
   identical plural rules). ICU4X's `datagen` proved this: fully resolve every
   (locale, key) payload, hash-cons them, and unrelated locales collapse onto shared
   payloads at a rate vertical inheritance never sees.
2. **Field-level decomposition.** Two payloads that differ in one string are "distinct"
   to a payload-level dedup. Split payloads into fields and pool strings globally, and
   sharing jumps again.
3. **Domain-aware value encoding.** Date/number patterns come from a tiny grammar; the
   set of *distinct* date patterns across all locales is a few hundred. Plural rules are
   boolean expressions that compile to branches, not data.

So the pitch is: ICU compresses vertically; we add horizontal + structural + generative
compression, offline, and ship a dumb fast runtime.

## 2. Architecture: offline datagen, tiny deterministic runtime

This is the shape that fits QIP perfectly — all cleverness happens at build time, the
component is a fixed-memory table-lookup-plus-formatter with zero imports.

```
cldr-json (pinned version)
   │  resolve inheritance fully (root→lang→script→region + CLDR parentLocales)
   ▼
resolved corpus: (locale, keypath) → value
   │  measurement harness: redundancy stats per key family   ← Phase 0 output
   ▼
encoding pipeline (per key family, chosen by measurement):
   field decomposition → pattern tokenization → global string pool
   → payload dedup (hash-consing) → locale→payload index matrix
   → locale ordering by similarity + delta/RLE on the matrix
   → optional final tiny-LZ over the blob
   ▼
artifacts:
   - packed .bin blob + generated Zig (@embedFile or arrays) with accessors
   - size report per section (so regressions are visible in CI)
   ▼
Zig components: qip-intl-number.wasm, qip-intl-datetime.wasm, ...
   (BCP-47 parse → fallback walk → binary-search locale index → format)
```

The datagen tool lives in this repo (Go, so it's part of the normal toolchain; a Node
script under `test/` is the fallback if cldr-json ergonomics push that way). It must be
deterministic and pinned to a CLDR release so component bytes are reproducible.

## 3. The encoding toolbox (ordered by expected payoff)

Phase 0 measures which of these earn their complexity per key family; don't commit to
all of them up front.

**T1. Full resolution + payload hash-consing (ICU4X's trick).**
Resolve every locale completely, then dedup identical payloads and keep a
`locale → payload-id` map per key. Runtime does *no* inheritance resolution for data —
it just needs the fallback chain to find which locale row to use when the requested one
is absent. Simple runtime, big wins. This is the baseline encoding; everything else
layers under it.

**T2. Field decomposition + global string pool.**
Break payloads into typed fields; all strings go into one pool, sorted and front-coded
(shared-prefix compression), referenced by varint index. Month names, currency symbols,
day-period strings collapse hard here.

**T3. Column transposition + tiny dictionaries.**
For each field, store the vector over all locales of value-ids (a "column"). Most
columns have very few distinct values (e.g., decimal separator: `.` `,` `٫` and a
handful more), so each column becomes a small dictionary + a per-locale index stream.

**T4. Locale ordering by data similarity.**
Order the locale rows not alphabetically but by clustering on actual payload similarity
(greedy nearest-neighbor / TSP-ish on hamming distance of the payload-id vectors). Then
the index matrix from T3 becomes long runs → RLE/delta encodes brutally well. This is
the "novel encoding" angle: nobody orders locales this way because file-per-locale
layouts can't benefit; a single packed blob can.

**T5. Pattern bytecode.**
CLDR date/number patterns (`"d/M/y"`, `"#,##0.00 ¤"`) tokenize into a small alphabet.
Store patterns as compact bytecode; the runtime formatter is a bytecode interpreter,
which is *also* smaller and simpler than a pattern-string parser. Distinct patterns are
dictionary-shared across locales (there are only a few hundred distinct date patterns in
all of CLDR).

**T6. Rules as code, not data.**
Plural rules (cardinal + ordinal) are boolean expressions over `n, i, v, f, t`. Compile
them to Zig functions at datagen time. All ~350 locales' plural rules should land in
single-digit KB of code, versus the multi-KB-per-locale rule text.

**T7. Final generic LZ pass — probably skip, but measure.**
A trained-dictionary zstd pass would win more bytes on the wire, but: web delivery
already gzips wasm; a decompressor means data-dependent loops that fight the
fixed-bound-loop verifier (`qip score` / `wasm-safety-check`); and it needs scratch
memory inside the fixed budget. If T1–T5 get us to target, keep the blob directly
readable (mmap-style: binary-search-friendly, no decompression step, no init cost).
Only reach for a bounded custom LZ (window and output both capped by static buffer
sizes, loops bounded by output cap so the verifier can prove them) if measurement says
the last 2–3x matters.

## 4. Component shape under the QIP contract

**Granularity: one component per Intl feature, all locales embedded.** That's the whole
point — the compression makes "all locales" cheap. Per-locale generated components stay
possible as a datagen flag (`--locales en-AU`) and serve as the size baseline to beat,
but they're not the product.

**Locale selection:** uniforms are numeric-only, so the locale travels in the input
bytes. Proposed Content contract, batch-friendly and pipeline-friendly:

```
input  (utf8):  line 1: locale tag + options   e.g.  en-AU style=currency currency=AUD
                lines 2..n: one value per line
output (utf8):  one formatted result per line
```

Batch TSV-ish input matches QIP's content-first philosophy and amortizes instantiation.
Numeric options that make sense as uniforms (`?min_fraction_digits=2`) can also be
uniforms; the input header wins when both are present.

**Fallback at runtime:** BCP-47 truncation (strip variant → region → script) *plus* the
CLDR `parentLocales` exception table (e.g., `es_AR → es_419 → es`, `en_AU → en_001 → en`)
— that table is small and must be embedded, or fallback is wrong in exactly the cases
people notice.

**Memory:** blob lives in data segments; fixed buffers; compile with
`--initial-memory=--max-memory`, pass the default runtime policy and the safety checker.
Binary-search + direct-offset access means no unpack step and no heap.

## 5. Scope ladder (which Intl features, in order)

| Phase | Feature | Why this order |
|---|---|---|
| 1 | **PluralRules** | Tiny (T6 alone), proves the datagen→Zig pipeline end to end, and NumberFormat/RelativeTimeFormat need it anyway. |
| 2 | **NumberFormat** (decimal, percent, basic currency, grouping) | Medium data (symbols + patterns), high utility. Exercises T1–T5. Compact notation as a stretch. |
| 3 | **DateTimeFormat** (dateStyle/timeStyle presets only, Gregorian only) | The big data: months/weekdays/eras/dayPeriods + patterns. Where T3+T4 either shine or don't. Explicitly *not* full skeleton matching in v1. |
| 4 | **ListFormat, RelativeTimeFormat** | Cheap once 1–3 exist; small data, reuse plurals. |
| 5 | **DisplayNames** (language/region names) | Pure string tables — a pure test of T2/T4. |
| ✗ | **Collator, Segmenter** | Out of scope. UCA tables + tailorings are megabytes and algorithmically a different project. Say so in the docs so nobody waits for it. |

## 6. Phase 0 first: measure before encoding (the "brute force" part)

Before designing any format, build the measurement harness and let the corpus decide:

1. Pin a CLDR release; pull cldr-json; fully resolve all locales.
2. For each key family emit: total raw bytes; unique-payload count and bytes (T1 win);
   unique-field/string counts (T2 win); per-column distinct-value counts (T3 win);
   index-matrix entropy before/after similarity ordering (T4 win); distinct-pattern
   counts (T5 win).
3. Also try the dumb thing on the whole resolved corpus: `zstd -19 --train-dict` — that
   number is the "information content" floor to sanity-check the structured encodings
   against. If a structured encoding isn't within ~2x of the zstd floor, it's leaving
   too much on the table; if zstd barely beats it, we're done.

This report drives every subsequent encoding decision, and it's cheap: a weekend of
scripting, no runtime code.

**Success targets (falsifiable, revise after Phase 0):**
- PluralRules, all locales: **< 16 KB** wasm.
- NumberFormat (decimal/percent/currency-basic), all locales: **< 96 KB** wasm.
- DateTimeFormat (style presets, Gregorian), all locales: **< 256 KB** wasm.
- Every component passes `qip run --max-memory` and the safety checker.
- Correctness oracle: differential test against Node's `Intl` (which is ICU) over a
  generated matrix of (locale × options × values); snapshot the outputs as comply-style
  fixtures so components are testable without Node afterward.

Reference points to beat: full ICU data ~30 MB; Chrome's filtered icudtl ~10 MB;
FormatJS ships tens of KB *per locale per feature*. ICU4X's blob format is the honest
competitor — worth reproducing their numbers with their `datagen` as part of Phase 0 to
know exactly what "state of the art" is before claiming to beat it.

## 7. Alternative packagings considered (and why not)

- **Data pack as pipeline input** (tiny formatter wasm + locale blob passed as input
  bytes): keeps components small and lets hosts subset locales, but QIP's single-input
  model makes "data + query" two-input composition awkward today, and it breaks the
  Immutable value — the component alone wouldn't work. Revisit if a multi-input or
  resource-attachment story lands in the contract.
- **One mega `intl.wasm`**: better cross-feature string sharing, but violates the
  small-focused-component ethos and makes every user pay for DateTimeFormat's tables.
  The string pool can still be shared *at datagen time* (same pool layout, subset per
  component) to keep most of the benefit.
- **Per-locale components only**: simplest runtime, no fallback logic, but it's the
  status quo we're arguing against; kept only as the baseline measurement.

## 8. Risks / open questions

- **CLDR licensing**: Unicode license is permissive; embed the notice in generated
  sources and the docs page.
- **Skeleton matching** (DateTimeFormat with arbitrary component sets) is the feature
  cliff — presets first, and be loud about it.
- **Non-Gregorian calendars, numbering systems beyond latn + native digits**: datagen
  should keep them *representable* in the format (key families are open-ended) even
  though v1 only emits a subset.
- **CLDR upgrades change bytes**: pin the version in the artifact name/docs
  (`qip-intl-number.cldr46.wasm`-style), matching QIP's Immutable framing — a locale
  component is a snapshot of the world's conventions at a date, and that's a feature.
