# ICU/CLDR Versions Across Popular Platforms — Survey

Status: draft research, surveyed 2026-07-12. Seed dataset for [drafts/locale-registry.md](./locale-registry.md) (Source 1: version mapping). Provenance labels: **[verified]** = checked against a primary source this week; **[infer]** = well-established pattern, needs probe/primary-source confirmation before registry publication.

## Reference: ICU release → CLDR/Unicode baseline

From the [official ICU download page](https://unicode-org.github.io/icu/download/):

| ICU | Released | CLDR | Unicode |
|---|---|---|---|
| 78.3 (current) | 2026-03 | 48 | 17 |
| 78 | 2025-10 | 48 | 17 |
| 77 | 2025-03 | 47 | 16 |
| 76 | 2024-10 | 46 | 16 |
| 75 | 2024-04 | 45 | 15.1 |
| 74 | 2023-10 | 44 | 15.1 |
| 73 | 2023-04 | 43 | 15.0 |
| 72 | 2022-10 | 42 | 15.0 — **the U+202F release** |
| 70 | 2021-10 | 40 | 14 |
| 68 | 2020-10 | 38 | 13 |
| 67 | 2020-04 | 37 | 13 |
| 60 | 2017-10 | 32 | 10 |

Cadence: two ICU/CLDR releases per year (spring/fall). Every row below is some platform frozen at one of these.

## Browsers / JS engines

| Platform | ICU | CLDR | Notes |
|---|---|---|---|
| Chrome (Chromium main, mid-2026) | 78.2 **[verified]** | 48 | [README.chromium](https://chromium.googlesource.com/chromium/deps/icu/+/refs/heads/main/README.chromium) says 78-2. Notable: Chromium sat **frozen on ICU 74-2 for ~2 years**, jumped to 77-1 around Dec 2025, then 78-2 — so the Chrome fleet crossed 4 CLDR releases in months after years of stasis. Edge, Brave, Electron, and anything Chromium-based inherit this per their base version. |
| Firefox (2026) | 78 → 78.2 **[verified]** | 48 | Updated early 2026; needed 78.2 specifically for Europe/Dublin and Africa/Windhoek timezone fixes ([nixpkgs issue](https://github.com/nixos/nixpkgs/issues/484824)). Mozilla carries local patches in `intl/icu-patches` and is [migrating parts of Intl to ICU4X](https://firefox-source-docs.mozilla.org/intl/icu4x.html) — meaning Firefox Intl output is *not* pure ICU even at a known version. |
| Safari | Apple system ICU (see Apple row) | — | JavaScriptCore uses the OS ICU on Apple platforms, so Safari's Intl output is pinned to the *OS version*, not the browser version — a different update cadence than Chrome/Firefox entirely. |

## Server-side JS runtimes

| Runtime | ICU | CLDR | Notes |
|---|---|---|---|
| Node 22 (LTS) | 76.1 (at 22.11) **[verified]** | 46 | Node bundles full-icu by default since 13; exposes `process.versions.{icu,cldr,tz,unicode}`. |
| Node 24.0 | 77.1 **[verified]** | 47 | [v24.0.0 release notes](https://nodejs.org/en/blog/release/v24.0.0). |
| Node 24.13 → 24.16 (LTS) | 78.2 → 78.3 **[verified]** | 48 | **ICU is upgraded *within* an LTS line** ([24.16.0](https://nodejs.org/en/blog/release/v24.16.0)) — a Node patch update can change formatting output. See [nodejs#58870](https://github.com/nodejs/node/issues/58870): "ICU behavior discrepancy in Current and LTS Node.js versions and latest browsers." |
| Node 26.0 | 78.3 **[verified]** | 48 | [v26.0.0 release notes](https://nodejs.org/en/blog/release/v26.0.0). |
| Deno | follows bundled V8 ≈ Chromium's ICU **[infer]** | — | No `process.versions.icu` equivalent surfaced; needs probing per release. Inherited Chromium's long ICU-74 freeze. |
| Bun | JavaScriptCore + platform-dependent ICU **[infer]** | — | JSC engine, not V8 — a different Intl implementation *and* a different ICU copy (WebKit-bundled/system depending on platform). The runtime most likely to diverge from the V8 family byte-for-byte; high-value probe target. |

## Operating systems

| Platform | ICU | CLDR | Notes |
|---|---|---|---|
| macOS 26 Tahoe / iOS 26 | Apple ICU **76142** (ICU 76 base) **[verified]** | 46 | [apple-oss-distributions/ICU](https://github.com/apple-oss-distributions/ICU/tags) newest tags ICU-76142.x (Feb–Jun 2026). Tag scheme: leading digits = upstream ICU major. **Apple is a fork with patches** — version mapping alone understates divergence; probes required. |
| macOS 15 Sequoia / iOS 18 | Apple ICU 74-based **[infer]** | 44 | Prior tag family; confirm from repo history. |
| Windows 11 | **undocumented** | — | icu.dll shipped in-box since Win10 1903 (libs since 1703) per [Microsoft's ICU page](https://learn.microsoft.com/en-us/windows/win32/intl/international-components-for-unicode--icu-) — but Microsoft **does not document which ICU version any Windows release carries**, and it changes via servicing. Community observations put Win11 builds in the ICU 68–72 range. This opacity is itself a registry selling point: the only way to know is `u_getVersion()` probes per build. Note the cascade: **.NET 5+ on Windows ≥1903 uses this OS icu.dll by default**, so .NET formatting output is tied to the user's Windows patch level. |
| Android 15 (API 35) | 75.1 **[verified]** | 45 | Official table at [developer.android.com](https://developer.android.com/guide/topics/resources/internationalization) — the *only* major platform publishing a first-party ICU/CLDR/Unicode mapping. Full history: API 24→ICU 56/CLDR 28 · API 28→60.2/32 · API 29→63.2/34 · API 30→66.1/36 · API 31/32→68.2/38.1 · API 33→70.1/40 · API 34→72.1/42 · API 35→75.1/45. |
| Android 16 (API 36) | ~77 **[infer]** | 47 | Not yet in the fetched table; follows the one-ICU-per-release cadence. OEM patches (Samsung et al.) apply on top — probe territory. |

## Linux distributions (system libicu — what PostgreSQL, PHP `intl`, PyICU, and `--with-system-icu` builds link)

From [repology](https://repology.org/project/icu/versions):

| Distro | ICU | CLDR |
|---|---|---|
| RHEL/Alma 8 (supported until 2029!) | 60.3 | 32 (2017) |
| RHEL/Alma 9 | 67.1 | 37 (2020) |
| RHEL/CentOS Stream 10 | 74.2 | 44 |
| Debian 12 bookworm | 72.1 | 42 |
| Debian 13 trixie | 76.1 | 46 |
| Ubuntu 22.04 LTS | 70.1 **[infer]** | 40 |
| Ubuntu 24.04 LTS | 74.2 **[infer]** | 44 |
| Alpine 3.20 | 74.2 | 44 |
| Alpine edge | 78.1 | 48 |
| Fedora 42 / 43–44 | 76.1 / 77.1 | 46 / 47 |
| Arch | 78.3 | 48 |

**The spread across currently-supported systems is ICU 60 → 78: eighteen major versions, nine years of CLDR drift, all live in production today.** A PostgreSQL cluster on RHEL 8 collates with 2017's understanding of locale order while the app tier on Arch formats with 2026's.

## Non-ICU and partially-ICU stacks (registry must model these too)

| Stack | Data source | Notes |
|---|---|---|
| Java (OpenJDK) | CLDR directly, no ICU4C | JEP 252; JDK 21 → CLDR 43, JDK 22 → 44, JDK 24 → 46 ([JDK-8333582](https://bugs.openjdk.org/browse/JDK-8333582)); one CLDR bump per feature release, **never backported into a JDK line** ([JDK-8327259](https://bugs.openjdk.org/browse/JDK-8327259)) — the opposite policy from Node's within-LTS upgrades. ICU4J exists as a separate, app-bundled option. |
| .NET 5+ | System ICU (OS icu.dll on Windows, distro libicu on Linux) with app-local ICU opt-in | [Microsoft's globalization-icu docs](https://learn.microsoft.com/en-us/dotnet/core/extensions/globalization-icu). Same binary, different bytes per host OS — unless the app opts into app-local ICU, which is the .NET ecosystem independently reinventing the "pin the data in the artifact" move. |
| Go | `golang.org/x/text`, CLDR-derived tables | No ICU at all; parts of x/text (notably collation) are famously stale — pinned, but pinned *old*. Different failure mode: stable-but-wrong vs drifting-but-current. |
| Python | C library locale + optional PyICU (system ICU) | stdlib `locale` output depends on the OS locale database; PyICU inherits the distro libicu row above. |
| formatjs / polyfills | CLDR at package publish time | JS userland pins CLDR per npm version — deterministic only if the lockfile is, and still disagrees with the host `Intl` beside it. |

## What the survey proves (for the registry and the i18n components)

1. **Every cell in these tables is a distinct formatting oracle.** The two-monoliths pain from drafts/i18n-formatting.md is really an N-monoliths reality: a typical product today spans Chrome 78-era CLDR 48, an iPhone on Apple-forked CLDR 46, a Node LTS that silently moved 47→48 in a patch release, a RHEL 9 Postgres collating at CLDR 37, and a JDK 21 service on CLDR 43 — five revisions of "the truth" in one request path.
2. **Update policies differ in kind, not just speed:** Node upgrades ICU inside LTS lines; Java never does; Chrome froze for two years then jumped four CLDR releases; Windows updates silently and undocumentedly; Apple ships a patched fork on an OS cadence; Go pins forever. No amount of "keep everything updated" discipline can synchronize policies this different — which is the strongest argument yet that pinning data *in the artifact* (the QIP move) is the only convergence point.
3. **Registry coordinates need more than a version number:** Apple and Android require fork/OEM deltas (probes), Windows requires probes because the version is undocumented, Firefox requires patch-set awareness (icu-patches + partial ICU4X). The Source-2 fingerprinting design in locale-registry.md is not optional garnish; for four of the biggest platforms it's the only reliable source.
4. **Best-documented platform: Android** (first-party table); **worst: Windows** (in-box, undocumented, servicing-updated). The registry's initial coverage should mirror where documentation is weakest and fleet share is highest: Windows builds and Apple OS versions first.

Sources: [ICU download/release history](https://unicode-org.github.io/icu/download/) · [Chromium deps/icu README](https://chromium.googlesource.com/chromium/deps/icu/+/refs/heads/main/README.chromium) · [Node v24.0.0](https://nodejs.org/en/blog/release/v24.0.0), [v24.16.0](https://nodejs.org/en/blog/release/v24.16.0), [v26.0.0](https://nodejs.org/en/blog/release/v26.0.0), [nodejs#58870](https://github.com/nodejs/node/issues/58870) · [Android internationalization table](https://developer.android.com/guide/topics/resources/internationalization) · [apple-oss-distributions/ICU tags](https://github.com/apple-oss-distributions/ICU/tags) · [Microsoft Win32 ICU](https://learn.microsoft.com/en-us/windows/win32/intl/international-components-for-unicode--icu-) · [.NET globalization & ICU](https://learn.microsoft.com/en-us/dotnet/core/extensions/globalization-icu) · [repology icu](https://repology.org/project/icu/versions) · [Firefox ICU docs](https://firefox-source-docs.mozilla.org/intl/icu.html), [ICU4X in Firefox](https://firefox-source-docs.mozilla.org/intl/icu4x.html), [nixpkgs#484824](https://github.com/nixos/nixpkgs/issues/484824) · [JDK-8333582](https://bugs.openjdk.org/browse/JDK-8333582), [JDK-8327259](https://bugs.openjdk.org/browse/JDK-8327259), [JEP 252](https://openjdk.org/jeps/252)
