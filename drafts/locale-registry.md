# The Locale Registry: Query What Any Device Would Format

Status: draft research, 2026-07-08. Companion to [drafts/i18n-formatting.md](./i18n-formatting.md); deliberately a separate, secondary offering. A first real dataset for Source 1 now exists: [drafts/locale-versions-survey.md](./locale-versions-survey.md).

## The idea

A queryable registry answering two questions no one can answer today without owning the hardware:

1. **"What locale datasets does a Google Pixel 3 have?"** → ICU 60 / CLDR 32 / tzdata 2018e (per Android version and per runtime on that device — Chrome, WebView, and the OS format APIs differ).
2. **"What would it produce?"** → submit a formatting request (`Intl.DateTimeFormat('de-AT', {dateStyle:'full'})` on epoch X in zone Z) against a device/OS/runtime coordinate and get the exact output bytes back.

The strategic role: businesses extract value *before* adopting QIP components. The registry **quantifies the drift** that pinned formatters eliminate — "your supported device matrix renders this one timestamp 14 different ways, here they are" is simultaneously a useful QA product and the sales pitch for the cure. Classic wedge: diagnose first, prescribe second, and every query result can end with "…or ship one QIP formatter and get one answer everywhere."

## Who pays the pain this relieves (without adopting anything)

- **Bug triage.** "User on a Galaxy S9 says the date is wrong." Today: find a Galaxy S9. With the registry: paste the user agent, see that device's ICU revision and the exact rendering, confirm it's known fleet drift in minutes, close as explained or fix the format choice.
- **Pre-ship format audits in CI.** Assert "this dateStyle/currency call renders identically across our device matrix" — or get the variant list *before* users report it. Formats that are fleet-unstable (AM/PM spacing, narrow month names, currency symbol vs code) get flagged at review time.
- **Snapshot testing honesty.** Instead of one golden that flakes as CI's ICU upgrades, per-coordinate goldens ("this output on Node 20, that on Chrome ≥110"), generated from the registry rather than discovered through failure.
- **Support/analytics enrichment.** A tiny fingerprint snippet (below) attached to bug reports and RUM telemetry turns "date looks weird" tickets into tickets carrying the exact locale-stack revision.

## Architecture: two data sources that check each other

### Source 1 — Version mapping (cheap, broad)

Device → OS/runtime → dataset versions is largely public knowledge: AOSP release notes pin ICU per Android version, Chromium's DEPS pins ICU per Chrome release, Node documents its ICU per major, Apple OS releases map to their (forked) ICU snapshots. A scraper + curated table gets wide coverage fast. But mapping alone is insufficient — OEMs patch ICU (Samsung ships locale tweaks), Apple's fork deviates from upstream, and backported security updates occasionally touch tzdata. Mapping gives the *claimed* coordinate; behavior needs verification.

### Source 2 — Probe fingerprints (authoritative, sampled)

A canonical **probe corpus**: a few hundred formatting calls chosen to maximally discriminate between dataset revisions — dates straddling DST transitions and era boundaries, the U+202F-sensitive time formats, currencies with symbol/code churn, plural boundary values, collation triples that reordered between CLDR releases. Run on real devices (device-farm services, plus a public "fingerprint my browser" page that crowdsources coverage the way caniuse/browserslist data gets gathered). Two products fall out:

- **Verification:** probe outputs either match the version-mapped prediction or reveal a vendor deviation worth recording as such.
- **Fingerprinting:** the hash of probe outputs identifies a locale stack *without* trusting the user agent — run the probes on an unknown device and look up which revision produces that fingerprint. This is the snippet businesses embed in QA and error reporting.

### The oracle: historical locale stacks as QIP components (the dogfood move)

"Query what it would produce" must not require a live device per query. The answer: **compile each historical ICU/CLDR/tzdata revision into a pinned wasm component** — `locale-oracle.cldr32.wasm`, `locale-oracle.cldr44.wasm`, … Each is a deterministic, hostable-anywhere emulation of one revision of the monolith. Then:

- The registry's "what would it produce" endpoint is just `qip run` against the right oracle component — infinitely scalable, no device farm in the hot path, and *runnable client-side*: the lookup site can execute the oracle in the visitor's own browser, which is a irresistible demo of the whole QIP thesis.
- Oracles are **validated by duel** against real-device probe outputs (the drafts/photocopy.md harness, again): divergences are precisely the vendor patches, which get recorded as per-device deltas on top of the base revision. The duel report *is* the registry's data-quality process.
- The i18n doc's "upgrade-as-diff" story gets its data source for free: diff two oracle components over your corpus to preview a CLDR upgrade.

This is the part only QIP can do cheaply: everyone else answering "what would ICU 60 say" maintains a zoo of Docker images with pinned ICU builds; here it's a directory of wasm files that run identically on the server, in CI, and in the reader's browser tab.

## Data model sketch

```
coordinate:  (device model | UA | fingerprint-hash)
             → { os, runtime, icu, cldr, tzdata, unicode,
                 provenance: mapped | probe-verified | vendor-delta,
                 oracle: locale-oracle.cldr32.wasm + delta-id? }

query:       (coordinate, formatting-request) → output bytes
fleet query: (UA distribution or fingerprint histogram, formatting-request)
             → distinct renderings + share of fleet per rendering
```

The fleet query is the money feature for businesses: upload the UA mix from analytics, get back "your users see 3 variants of your checkout total, 0.4% see the broken one."

## Prior art (and the gap)

caniuse.com and MDN BCD record feature *support*, not behavioral *output*; wpt.fyi is closest in spirit (recorded behavior across engines) but stores pass/fail, not bytes, and doesn't cover dataset revisions or devices. Nothing publicly answers "what bytes does device X produce for this format call." The gap exists because without a deterministic emulation layer the operating cost is a permanent device farm — which is exactly the cost the oracle components remove.

## Scope discipline

- Locale/formatting behavior only (Intl surface + OS format APIs). Not a general browser-behavior registry — that's wpt's job and a tar pit.
- Device matrix: start with the coordinates businesses actually name in bug reports — recent iOS/Android major versions × (Safari/Chrome/WebView), Node LTS lines, common CI images. The long tail is crowdsourced via fingerprints, never hand-maintained.
- The oracle needs *enough* of each revision's surface to answer formatting queries, not all of ICU: dates, numbers, currencies, relative time, plurals first; collation later (bigger data, fewer registry-style queries).

## Sequencing (kept honest: this is secondary)

1. **Probe corpus + fingerprint page** — smallest useful artifact, starts data collection, and the corpus design work is shared with the i18n components' Intl-duel tests (same discriminating inputs).
2. **Version-mapping tables** for the top ~30 coordinates, published as a static, linkable site (caniuse-shaped; SEO is the marketing).
3. **First two oracle components** (one old Android-era CLDR, one current) + duel-vs-device validation of both — proves the emulation claim end to end.
4. **Query API + fleet reports** — the first paid-shaped surface, only if 1–3 show pull.

Step 1 costs days, not months, and steps 1–2 deliver standalone value even if the oracle never ships.

## Risks & open questions

- **Data staleness is the product risk.** A registry that lags OS releases by months loses trust; the crowdsourced fingerprint page and automated scraping of Chromium/AOSP pins are the mitigations, and "probe-verified vs mapped" provenance labels keep honesty explicit.
- **Building historical ICU revisions to wasm** may fight old build systems; the pragmatic fallback per stubborn revision is codegen from that revision's CLDR JSON into the Approach-A Zig formatters (emulating the *data* at the right revision under one engine), accepting engine-level divergences where the duel reveals them.
- **Vendor deltas' long tail:** OEM patches are discoverable only by probing; the registry should present deltas as confidence-scored, not authoritative, until multiple fingerprint submissions agree.
- **Privacy:** fingerprints are locale-stack hashes, not user identifiers — but the fingerprint page must say so, and fleet queries should accept aggregated histograms rather than raw telemetry.
- **Naming the wedge honestly:** this is a diagnosis product that markets a cure the same party sells; that's fine (it's the caniuse→Babel dynamic), but the registry must stay useful to businesses that never adopt QIP, or it becomes content marketing and dies.
