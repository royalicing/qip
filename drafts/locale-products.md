# Three Products: Directory, Emulator, SDK

Status: draft research, 2026-07-13. Synthesizes [locale-registry.md](./locale-registry.md), [locale-versions-survey.md](./locale-versions-survey.md), and [i18n-formatting.md](./i18n-formatting.md) into a product ladder. Those docs hold the technical designs; this one holds the product shapes and what's newly needed for each.

## The ladder

| # | Product | Job | Motion |
|---|---|---|---|
| 1 | **Directory** | *Diagnose*: "2017 Android phone in India — what will bite me?" | Free, public, SEO — the caniuse of locale behavior |
| 2 | **Emulator** | *Evaluate & test*: "show me exactly what that user sees" | Playground free; CI integration is the paid-shaped surface |
| 3 | **SDK** | *Cure*: ship your own pinned locale stack, any platform | The QIP components productized; paid/support |

Each rung generates demand for the next: the directory names your problem, the emulator proves it's real on your own strings, the SDK removes it. And each rung is independently useful to businesses that never take the next one — the honesty constraint from locale-registry.md.

## Product 1 — The Directory (registry + a known-issues database)

The registry draft already designed the coordinate lookup (device/OS/runtime → data family + revision, mapped + probe-verified). What the product needs on top is the **known-issues layer**: a curated database keyed by *(coordinate range × locale)* so a lookup returns not just "ICU 56 / CLDR 28" but *what that means for you*.

**Issue entry shape** (deliberately CVE-like, with stable citable IDs):

```
id: LQ-2019-0001                    # stable, linkable from bug trackers
title: Japanese era formatted as Heisei after 2019-05-01 (Reiwa missing)
mechanism: era-data                  # taxonomy, below
affects: icu < 64.2                  # coordinate range, any family
locales: ja, ja-JP-u-ca-japanese
symptom: era dates render 平成31年+ instead of 令和
probe: format(2019-06-01, ja-JP-u-ca-japanese, dateStyle=long)
  expected: 令和元年6月1日   observed-on-affected: 平成31年6月1日
workarounds: gregorian-only formatting; SDK (product 3)
fixed-in: icu 64.2 / cldr 35.1
```

**Issue taxonomy** (from the survey's market analysis): `missing-locale` (hi-Latn on old stacks), `wrong-fallback` (zh-Hant chains), `digit-system` (ar regional defaults), `calendar-day` (Umm al-Qura shifts), `era-data` (Reiwa), `grouping` (lakh/crore), `segmentation` (Indic graphemes, Thai dictionaries), `collation-order` (UCA jumps, pinyin/stroke), `identifier` (in→id), `spacing-punctuation` (U+202F class), `compliance` (GB18030-2022).

**The query the user described, end to end:** "2017 Android phone, India" → resolve coordinate (Android 7 / API 24 → ICU 56 / CLDR 28, OEM deltas flagged) → filter issues by market locales (hi, bn, ta, te, mr…) → ranked checklist: hi-Latn missing entirely; lakh grouping unreliable; Indic grapheme handling at Unicode 8; ₹ formatting quirks — each with probe repro and workaround. That checklist *is* the product; the version number alone was never the point.

**Sourcing issues:** seed editorially from the survey's market analysis (a dozen flagship entries: Reiwa, U+202F, hi-Latn, ar digits, uca1400/0900, glibc 2.28); then semi-automate — every divergence the emulator's duel validation finds between adjacent data revisions is a *candidate issue* with the probe already attached. The oracle components make issue discovery a diff job, not archaeology.

**New build surface:** issue schema + curation workflow + the lookup UX. Everything else (coordinates, probes, fingerprints) is the registry draft.

## Product 2 — The Emulator (oracle components, productized)

The registry draft invented the mechanism: historical locale stacks compiled to deterministic wasm oracle components, duel-validated against real devices. The product wraps three UXes around it:

1. **Playground** (browser): pick a device from the directory → type a value/locale/options → see the exact bytes that device produces, running the oracle *client-side in the visitor's tab* (the wasm components make the demo be the product). Side-by-side mode: this device vs latest vs your current browser — three renderings of your own example, with diffs highlighted and any matching known-issue IDs linked. This page is the directory's conversion engine.
2. **Matrix mode**: one formatting call × your supported-device list → table of distinct outputs with fleet-share weighting (the registry's fleet query, given a face). Exportable as the "14 renderings of your checkout total" report.
3. **CI package** (the sleeper hit): a test-runner integration wrapping the same oracles —

   ```js
   import { deviceIntl } from "@…/emulate";
   const nf = deviceIntl("android-7-in", "hi-IN");   // ICU 56 oracle, wasm
   expect(nf.NumberFormat({currency:"INR"}).format(12345678))
     .toMatchSnapshot();                              // golden per device class
   ```

   Deterministic by construction (it's a QIP component), so these snapshots *never flake* — which is precisely what per-device formatting tests could never offer before. Ship presets like `oldest-supported-android`, `current-ios`, `wechat-webview` so teams encode their support matrix once.

**Trust model carries over from the registry draft:** every oracle result is labeled `probe-verified` (duel-matched against hardware) or `emulated-from-version` (confidence-scored), and Apple/OEM/WeChat coordinates stay honest about delta uncertainty.

**New build surface:** playground + matrix UI, the npm test package, device-preset curation. The oracles and validation harness are the registry draft; the duel machinery is photocopy's.

## Product 3 — The SDK (pinned formatting, any platform, developer-chosen version)

The i18n-formatting draft designed the components; the SDK is their delivery vehicle: *"don't inherit the platform's locale stack — ship your own."* Developer picks the data version (usually latest), the SDK guarantees identical bytes on every platform the app touches, ending both the fleet problem (old devices) and the N-copies problem (survey's intra-machine section) at once.

**What's in the box:**

- The formatter components (date/number/currency/plural/relative-time…), per-locale artifacts — the app ships only its shipping locales, Blazor/ICU4X/Unreal-preset style, tens of KB per locale not 30 MB.
- **Thin idiomatic wrappers** per host: a TS API mirroring `Intl` (drop-in-shaped: `new PinnedIntl.NumberFormat("hi-IN", …)`), Kotlin and Swift equivalents, so adoption is a formatting-call swap, not a framework migration.
- **Upgrade-as-diff tooling**: bumping the SDK's data version runs old-vs-new over the app's own string corpus and emits the human-reviewable changelog (the machinery is the duel harness; the report format exists in the i18n draft). This is the anti-Reiwa, anti-x/text feature: pinned *with* a first-class upgrade path.
- Directory/emulator integration: the SDK docs for each locale link the known issues it makes moot on each coordinate.

**The "how does wasm run there?" answer, per host — this is the part not yet in any draft:**

| Host | Execution |
|---|---|
| Web / Electron / Node | native WebAssembly — zero friction |
| Android | tiny interpreter (WAMR/wasm3-class, ~100 KB) behind the Kotlin wrapper — formatting workloads are microseconds even interpreted |
| iOS | interpreter (JIT restrictions don't bite interpreters) — or the AOT route below |
| Consoles / Unreal / strict platforms | **wasm2c**: transpile the components to portable C at build time, compile into the title as a static lib. No runtime, no JIT, NDA-toolchain-friendly — and the C is generated from the *same audited artifact* every other host runs |

The wasm2c route matters strategically: it means "QIP component" and "runs on PlayStation" are compatible sentences, and the determinism claim survives because the C is mechanically derived from the pinned wasm. (It also hands Unreal titles a fix for the survey's ICU-53/Reiwa embarrassment without touching the engine's ICU.)

**Positioning vs incumbents:** formatjs polyfills are JS-only and still just move the pin into `package.json`; ICU4X is a library per-language ecosystem, not one artifact across all of them; app-local ICU (.NET) is single-runtime. The SDK's differentiator is the one thing none of them structurally can do — *the same bytes from the same artifact on web, Android, iOS, server, and console* — plus the emulator/directory halo (test against the problem, then ship the cure, in one toolchain).

## Shared spine and sequencing

All three products stand on the same four assets, all already designed: the **survey/version tables** (directory data), the **probe corpus + fingerprints** (verification everywhere), the **oracle components** (emulator + issue discovery), and the **duel harness** (validation + upgrade-as-diff). Build order follows the ladder because each rung's asset feeds the next:

1. Directory MVP: survey tables + ~12 flagship issue entries + lookup UX (static site; days-to-weeks).
2. Playground with two oracles (one old-Android-era CLDR, one current) — proves the emulation claim publicly.
3. CI emulate package (small; highest developer-love-per-line-of-code in the plan).
4. SDK wave 1: web + Node hosts only (zero-friction wasm), TS wrapper, 7 proof locales (en, de, fr, ja, ar, hi, id per the i18n draft).
5. SDK wave 2: Android/iOS wrappers; wasm2c spike for one console/engine target.

## Risks

- **The issues database is editorial work forever.** Mitigation: oracle-diff candidate generation + community submissions with probe-repro required (an issue without a reproducing probe isn't accepted — keeps quality mechanical).
- **Emulator fidelity on forked stacks** (Apple, OEM, WeChat): confidence labels are load-bearing; overclaiming once poisons the directory's trust. Never present `emulated-from-version` as ground truth.
- **SDK inertia:** developers default to platform `Intl` because it's free and already there. The wedge is not evangelism, it's the directory/emulator naming a bug they already have, with the SDK one click away as its fix — every issue entry's `workarounds:` field is a sales channel.
- **Scope gravity toward "reimplement ICU":** the SDK ships formatting tasks, in the i18n draft's narrow-module discipline; collation/segmentation arrive only via the ICU4X-based wave, or not at all.
