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

These stacks prove the registry needs to model **data-source families**, not just ICU versions: some use ICU, some use CLDR without ICU, some use *their own* locale data that never came from CLDR at all, and some have no locale awareness whatsoever.

### Managed runtimes

| Stack | Data source | Version fetch method | Notes |
|---|---|---|---|
| Java (OpenJDK) | CLDR directly, no ICU4C | `LocaleServiceProvider` javadoc per release; [cr.openjdk.org doc-versions table](https://cr.openjdk.org/~jjg/doc-versions/jdk.html); search bugs.openjdk.org "Upgrade CLDR to" | JEP 252 (CLDR default since JDK 9). LTS ladder: JDK 8 → legacy JRE data by default (CLDR opt-in!), JDK 11 → CLDR 33 **[infer]**, JDK 17 → CLDR 39 **[verified]**, JDK 21 → 43, JDK 25 → 47 **[infer]**; interim: 22 → 44, 24 → 46 ([JDK-8333582](https://bugs.openjdk.org/browse/JDK-8333582)). One CLDR bump per feature release, **never backported into a JDK line** ([JDK-8327259](https://bugs.openjdk.org/browse/JDK-8327259)) — the opposite policy from Node's within-LTS upgrades. So the common enterprise pair (JDK 11 service + JDK 21 service) spans a *decade* of CLDR. ICU4J exists as a separate, app-bundled option, adding a second family inside one JVM when present. |
| C# / .NET 5+ | System ICU (OS icu.dll on Windows ≥1903, distro libicu on Linux, system on macOS); app-local ICU opt-in | Probe the OS row; app-local: the `Microsoft.ICU.ICU4C.Runtime` NuGet version *is* the ICU version; ICU-vs-NLS mode via the documented `GlobalizationMode` reflection snippet in [globalization-icu docs](https://learn.microsoft.com/en-us/dotnet/core/extensions/globalization-icu) | Same binary, different bytes per host OS — unless app-local ICU is used (the .NET ecosystem independently reinventing "pin the data in the artifact"). |
| C# / .NET Framework 4.x | **NLS** — Windows' own locale data, no CLDR lineage at all | tied to the Windows build; no version API | A whole separate data family: enterprise apps on .NET Framework format with Windows-native tables that never agreed with CLDR in the first place. |
| C# / Blazor WebAssembly | Bundled, **sharded** icudt (`icudt_EFIGS.dat` etc.) + invariant-globalization mode | dotnet SDK version → runtime repo's icu pin | Microsoft slicing ICU data per locale-group for wasm payload size — the closest existing product to the QIP per-locale-artifact idea, and strong prior art for it. |
| Erlang/OTP | **None in stdlib** — no locale-aware formatting exists; `string` module implements Unicode algorithms (case, grapheme) at a Unicode version pinned per OTP release | OTP release notes state Unicode data updates; `unicode` module docs per release | The BEAM's answer to locale drift is to not play: formatting is delegated to libraries or left to the caller. |
| Elixir (ex_cldr) | CLDR JSON embedded per Hex package release | ex_cldr changelog/README documents its CLDR version per release; data compiled into the app | Community-built, CLDR-complete, and *pinned in the artifact* — philosophically the closest ecosystem neighbor to the QIP approach, worth studying for API shape (backends, locale slicing at compile time). |
| Go | `golang.org/x/text`, CLDR-derived tables; **stdlib is locale-blind** (`time.Format` hardcodes English) | grep `CLDRVersion` in `x/text/unicode/cldr`; module version in `go.mod` — data is compiled in | No ICU at all. Deterministic and pinned (good!) but parts — notably collation — are famously stale. The failure mode QIP must avoid: pinned-but-abandoned. Go proves pinning without a data-refresh pipeline decays. |
| Python | stdlib `locale` = C library data; **Babel** = embedded CLDR per PyPI release; **PyICU** = system ICU | Babel changelog documents CLDR version per release; PyICU: `python -c "import icu; print(icu.ICU_VERSION)"` | Three different data families reachable from one interpreter, all disagreeing with each other. |
| Ruby | stdlib: none; rails-i18n = **hand-maintained YAML, not CLDR**; twitter-cldr-rb = embedded CLDR (stale) | gem versions + changelogs | rails-i18n is the reminder that a huge ecosystem runs on locale data with no CLDR lineage — community-edited formats that drift from *everything*. |
| Rust | **ICU4X**: CLDR baked into versioned `icu_*_data` crates; chrono is locale-blind | ICU4X release notes state CLDR version; `gh api repos/unicode-org/icu4x/releases`; data crate version in `Cargo.lock` | Unicode's own pin-the-data-in-versioned-artifacts design — the second-strongest external validation of the QIP move after Blazor's sharding, and the planned Approach-B source for QIP collation/MF2 components. |
| PHP | `intl` extension → ICU (system libicu on Linux; **bundled** ICU in php.net Windows builds, per-build) | `php -i \| grep -i icu`; constants `INTL_ICU_VERSION`, `INTL_ICU_DATA_VERSION` at runtime | The largest deployed web language rides the distro libicu row on Linux and a php.net-chosen ICU on Windows — same PHP version, two ICU revisions. Frameworks add third opinions (see Symfony/Carbon below). |
| Kotlin | JVM target → OpenJDK CLDR row; Android target → `android.icu` row | per target platform | One language, two data families depending on build target; `kotlinx-datetime` is deliberately locale-blind. |
| Perl | POSIX locale (glibc row) in core; `DateTime::Locale` on CPAN embeds CLDR per release | CPAN module changelog documents its CLDR version | Same pattern as Babel/ex_cldr: userland pinning on top of a drifting C-library floor. |
| R | OS locale for base formatting; bundles its own ICU on Windows for collation (`icu` capability) | `capabilities("ICU")`; `l10n_info()`; Windows: ICU version per R release notes | Statistical reports formatted on the analyst's machine — reproducible-research tooling meets the locale lottery. |
| Julia / Lua | effectively none — C-library passthrough (`os.date`, `Dates` with English defaults) | n/a | The Erlang stance without the ecosystem package to fill it. |
| formatjs / polyfills (JS) | CLDR at npm publish time | package version + lockfile | Deterministic only if the lockfile is, and still disagrees with the host `Intl` running beside it in the same page. |
| C / C++ (direct) | Whatever the program links: glibc `locale.h` (glibc row), ICU4C directly (pinned by the build), or **Qt's QLocale** (below) | `ldd` the binary; ICU4C: `u_getVersion()` | The only ecosystem where the developer explicitly chooses the data family at link time — everyone else inherits a runtime's choice. |

### App/mobile frameworks

| Stack | Data source | Notes |
|---|---|---|
| React Native (Hermes) | Android: delegates to the device's `android.icu` (per-API-level, per-OEM); iOS: Apple system ICU | **One JS bundle, two data families, N fleet revisions** — the same `toLocaleString` call in the same app renders differently on the user's iPhone vs Android phone. The registry's fleet query answers exactly this. |
| Flutter / Dart | `package:intl` + `flutter_localizations`: CLDR-derived data embedded per SDK/package release | Pinned in the artifact (good), version discoverable from the Flutter SDK release; Dart-on-web instead uses the browser's `Intl` — same codebase, different family per target. |
| Swift (server-side / Linux, Windows) | [swift-foundation-icu](https://github.com/apple/swift-foundation-icu): ICU pinned per Swift toolchain release | On Apple OSes Foundation uses system ICU instead — Swift code changes data family when it leaves Apple hardware. |
| Qt (QLocale) | **Own CLDR-derived tables regenerated per Qt release** (`qlocale_data_p.h`) | Desktop C++'s most common answer to locales: pinned in the Qt version, independent of both glibc and ICU on the same machine. Qt release notes state the CLDR version used for regeneration. (Qt WebEngine separately carries Chromium's ICU — two families inside one framework.) |
| Symfony (PHP) | `symfony/intl` component embeds a CLDR subset regenerated per release | A third locale opinion inside a PHP app, beside the intl extension's ICU and the OS. Version: the component's release notes. |
| Carbon (PHP dates) | **Hand-maintained per-locale translations**, not CLDR | The most popular PHP date library is an own-data family member, like rails-i18n. |
| Django (Python) | **Hand-maintained per-locale `formats.py` modules**, not CLDR | Django's date/number formats are community-edited Python files per locale — drift from CLDR is structural, not accidental. |
| WordPress | Own translation packs + `date_i18n()`/`wp_date()` with hand-maintained locale data | ~40% of the web formats dates through an own-data family with no CLDR lineage. Fleet-scale example for the registry. |
| Unity | **Backend-dependent, and mostly broken:** Editor/Mono backend uses Mono's own aging culture tables (with [long-standing `CurrentCulture` bugs](https://issuetracker.unity3d.com/issues/mono-cultureinfo-dot-currentculture-doesent-work)); **IL2CPP players — the dominant mobile/console backend — return InvariantCulture** ([issue tracker](https://issuetracker.unity3d.com/issues/system-dot-globalization-dot-cultureinfo-dot-currentculture-returns-invariant-culture-in-players-which-scripting-backend-are-il2cpp), [RegionInfo throws](https://issuetracker.unity3d.com/issues/il2cpp-accessing-system-dot-globalization-dot-currentculture-dot-regioninfo-throws-an-exception)) | Not "old data" but **no data**: the same C# `DateTime.ToString()` gives localized output in the Editor and invariant English in the shipped IL2CPP build — an editor/player divergence worse than any version skew in this survey. The `com.unity.localization` package papers over it with its own tables (own-data family). The pending CoreCLR migration (Unity 6.x roadmap) would finally bring real ICU. Fetch: scripting backend + Unity version, not a data version. |
| Unreal Engine | Bundles its own ICU: UE4 shipped **ICU 53 (2014, CLDR 25) essentially for its entire life** (`Binaries/ThirdParty/ICU/icu4c-53_1/` — [confirmed in-tree](https://github.com/permalance/unreal/blob/master/Engine/Build/BatchFiles/Linux/BuildThirdParty.sh)); UE5 moved to icu4c-64_1 (ICU 64, 2019, CLDR 35) **[infer]**. All `FText` formatting/collation flows through it | Fully pinned and fleet-uniform (the QIP property!) but a decade stale — a 2026 UE title formats with 2014–2019 CLDR on every platform identically. Also notable: Unreal's packaging offers **sharded ICU data presets** (English-only / EFIGS / CJK / All) to cut payload — the third independent reinvention of locale-sliced data artifacts after Blazor and ICU4X. Fetch: the `icu4c-*` folder name in `Engine/Source/ThirdParty/ICU` per engine release. |

### Game consoles

| Platform | Data source | Notes |
|---|---|---|
| Xbox (Series X/S) | Windows-lineage OS → NLS family, plus icu.dll-era components per system build; GDK titles use engine-bundled data in practice | Effectively the Windows row behind an NDA: version undocumented, servicing-updated, probe-only. |
| PlayStation 5 | FreeBSD-based Orbis/Prospero; SDK under NDA; system software carries WebKit (→ some ICU) internally | No public locale-stack documentation exists at all. Titles overwhelmingly ship engine-bundled (Unreal/Unity) or hand-made localization — own-data by necessity. |
| Nintendo Switch / Switch 2 | Proprietary Horizon OS; SDK under NDA | Same story; system UI locale data is opaque, games bring their own. |

Consoles are the registry's honest boundary: NDA'd SDKs mean the public mapping can't cover the *system* layer, and mostly doesn't need to — games are the one software ecosystem that already lives by pin-forever rules (a 2017 cartridge must format identically in 2040, offline), so locale data arrives frozen inside the title or engine, not from the platform. They're less a coverage gap than the existence proof that artifact-pinned locale behavior ships at planetary scale: every console game is already doing what QIP proposes, just with hand-rolled localization instead of CLDR-derived components.

## One system, many copies: the skew is intra-machine, not just fleet-wide

The web's canonical failure is *two* copies (server ICU vs browser ICU) separated by a network. Complex systems generalize this to **copy-per-subsystem, several inside one process**, because every embedded renderer, engine, scripting VM, middleware SDK, and database links its own locale stack. The versions aren't just different — they're frozen at wildly different *ages*, because each subsystem has its own update cadence.

A concrete stack-up for one PC game session:

| Subsystem | Locale stack | Age |
|---|---|---|
| Windows OS APIs | NLS + undocumented icu.dll | OS servicing cadence |
| Steam client + overlay | CEF → Chromium's ICU | updates ~monthly |
| Game launcher (Epic/Battle.net) | its own CEF → another Chromium ICU | its own cadence |
| Engine (`FText`) | Unreal's bundled ICU 53/64 | frozen 2014/2019 |
| In-game HTML UI middleware (Coherent/Gameface/Ultralight — HUDs are often literally HTML) | embedded Chromium/WebKit-lineage → yet another ICU | frozen at middleware release |
| Embedded scripting (Lua / Mono) | none / Mono tables / invariant | n/a or ancient |
| Local SQLite (saves, leaderboard cache) | optional ICU extension → whatever it was built with | build-time |
| Backend services | distro libicu + Postgres/MySQL collations + JVM/Go data | each its own row above |

That's six-plus independent locale stacks touching one user's session, spanning a *twelve-year* data spread. The same pattern holds outside games: a car's cabin runs Android Automotive (`android.icu` per API level) next to a Qt-based instrument cluster (QLocale per Qt release) next to RTOS nodes with nothing; a smart TV runs a web app runtime beside native middleware; a Windows desktop runs NLS, icu.dll, .NET's ICU mode, and Office's own locale handling on one machine.

Where it bites, concretely:

- **Cross-subsystem sort disagreement:** a leaderboard ordered server-side (Postgres ICU 67 collation) then re-sorted or merged client-side (engine ICU 53) shows visibly different orderings of the same names — the intra-system version of the Postgres index-corruption class.
- **The same timestamp, three renderings on one screen:** store expiry date formatted by the system webview (current CLDR), in-game countdown by the engine (CLDR 25-era), purchase receipt by the backend (distro CLDR) — simultaneously visible to the player.
- **Unicode-version skew as a correctness/security issue, not a formatting one:** username uniqueness and impersonation checks depend on normalization/casefolding, and characters unassigned in ICU 53's Unicode 6.3 normalize differently than in a current stack — server accepts a name as unique, client's older stack renders it confusable with an existing one. Case-insensitive matching across a Turkish-locale subsystem boundary compounds it.
- **Persistence poisoning:** anything *stored* under one subsystem's collation or normalization (save-file sort keys, SQLite indexes, cached sorted lists) silently disagrees with the subsystem that later reads it — drift frozen into data at rest.

Implications recorded here for the other drafts:

1. **Registry:** coordinates attach to *subsystems*, not machines. The fleet query needs a "stack-up" mode, and fingerprint probes must run *inside* each context that can execute them — JS in each webview/CEF instance, engine-API probes in game code, `SELECT` probes in each database — because one machine legitimately returns five different fingerprints.
2. **QIP components:** the intra-system framing strengthens the pitch beyond "server and client agree." One `date-format.de.wasm` can be invoked from the engine (native host), the HTML HUD (browser host), and the backend (server host) — the *N-copies problem collapses to one artifact* precisely because QIP components are host-portable. No pinned library can do this across subsystem boundaries; the portability is the differentiator, not just the pinning.

### Native / system layers

| Stack | Data source | Notes |
|---|---|---|
| glibc | **Its own `localedata`** — independently maintained, *not* CLDR | This is what `strftime`, `strcoll`, and `LC_*` actually consult on most Linux systems, versioned with glibc itself — the PostgreSQL index corruption was glibc localedata changing, not ICU. Fetch: glibc version (`ldd --version`) → glibc changelog. |
| musl | C/POSIX locale only, effectively no locale data | Why Alpine containers are locale-deserts; also why they're accidentally deterministic. |

### Databases

| Stack | Data source | Notes |
|---|---|---|
| MySQL 8+ | Own collations; `utf8mb4_0900_ai_ci` (the 8.0 default) pins **UCA 9.0.0** (2016) *in the collation's name* | Deliberate version-pinning-in-the-identifier — prior art for QIP's locale-as-component-identity stance, from a system that learned the index-corruption lesson. Older `utf8mb4_unicode_ci` = UCA 4.0.0, `utf8mb4_unicode_520_ci` = UCA 5.2.0 — three pinned Unicode generations selectable side by side. |
| MariaDB 10.11+ | Own collations; `utf8mb4_uca1400_ai_ci` pins **UCA 14.0.0** (with 939 built-in contractions the 0900 set lacks) — [supported charsets docs](https://mariadb.com/docs/server/reference/data-types/string-data-types/character-sets/supported-character-sets-and-collations) | **The fork war in miniature:** MariaDB has no `utf8mb4_0900_*` (MySQL dumps referencing it fail with "unknown collation"), MySQL has no `uca1400_*` — sibling databases pinned at Unicode 9 vs Unicode 14, with `utf8mb4_unicode_520_ci` (UCA 5.2.0, 2009!) as the only modern-ish collation both speak ([migration pain](https://www.coderedcorp.com/blog/guide-to-mysql-charsets-collations/), [WordPress#58871](https://core.trac.wordpress.org/ticket/58871)). Pinning-in-the-name is the right idea; the lesson for QIP is that *identity must be portable across hosts*, which named wasm artifacts are and vendor collation names aren't. |
| PostgreSQL | Per-collation choice of **three families**: `libc` (glibc localedata), `icu` (system libicu), and — since PG 17 — `builtin` (fixed, version-independent C.UTF-8 semantics) | `SELECT collname, collprovider, collversion FROM pg_collation`. PG records `collversion` at index creation and **warns "collation version mismatch" after an OS upgrade changes the data underneath** — drift detection built into the database because the glibc 2.28 corruption made it existential. The PG 17 `builtin` provider is yet another ecosystem converging on "pin the semantics, escape the environment." |
| MongoDB | Bundles its own ICU per server version | Pinned per server release — collation stable per version, changes on upgrade. |
| SQLite | Optional ICU extension → whatever ICU it was linked against | Data family decided at build time by whoever compiled it. |
| SQL Server | Windows collations — the NLS family, tied to Windows version and collation designator | Shares .NET Framework's non-CLDR lineage; a SQL Server ORDER BY and a Linux app tier's sort never came from the same data. |
| Oracle | Its own **NLS** subsystem (`NLS_LANG`, `NLS_DATE_FORMAT` …) — a fully proprietary data family | The oldest own-data family still in production; `SELECT * FROM NLS_DATABASE_PARAMETERS` to inspect. |

### Top-20 coverage map

Rough popularity-ranked checklist (Stack Overflow / GitHub Octoverse composite) → where each is covered above: **JavaScript/TypeScript** (browsers, Node, Deno, Bun, formatjs) · **Python** (stdlib/Babel/PyICU) · **Java** (OpenJDK) · **C#** (.NET ×4 rows) · **C/C++** (direct + glibc + Qt) · **PHP** (intl + Symfony + Carbon + WordPress) · **Go** (x/text) · **Rust** (ICU4X) · **Ruby** (rails-i18n, twitter-cldr-rb) · **Kotlin** (JVM/Android) · **Swift/Objective-C** (Apple + swift-foundation-icu) · **Dart** (Flutter) · **Scala** (JVM row) · **Elixir/Erlang** (ex_cldr / none) · **Perl** (DateTime::Locale) · **R** (capabilities) · **Julia/Lua** (none) · **SQL** (PostgreSQL, MySQL, SQL Server, Oracle, SQLite, MongoDB) · frameworks: **React/Vue/Angular** (browser Intl + formatjs), **React Native** (Hermes), **Django**, **Rails**, **Spring** (JVM), **Laravel/Symfony**, **Qt**, **Unity**, **Electron**. Gaps knowingly left: COBOL/mainframe NLS, SAP/ABAP, Excel/Sheets formula locales — real but beyond the registry's first ring.

## How to re-survey: sources and methods per platform

This section is the maintenance manual for the tables above — and the de facto spec for the registry's automated scraper. Two universal tricks cover most rows, then per-platform methods for the rest.

### Universal methods

- **Any vendored ICU source tree** declares its version in `source/common/unicode/uvernum.h` as `#define U_ICU_VERSION "78.3"`. Chromium, Firefox, Node, and AOSP all vendor ICU, so one fetch-and-grep works across all of them — only the path prefix differs.
- **ICU → CLDR/Unicode mapping is fixed per ICU release**, so you rarely need to fetch CLDR versions separately: get the ICU version, look up CLDR in the baseline table (maintained from the [ICU download page](https://unicode-org.github.io/icu/download/), or programmatically via `gh api repos/unicode-org/icu/releases` — tags look like `release-78-3`).
- **Runtime probes beat source archaeology** where available: ICU's own C API is `u_getVersion()` + `ulocdata_getCLDRVersion()`; the `icuinfo` CLI (in `icu-devtools` packages) prints both.

### Per-platform

| Platform | Authoritative source | Programmatic fetch | Runtime probe |
|---|---|---|---|
| **ICU/CLDR upstream** | [icu download page](https://unicode-org.github.io/icu/download/) | `gh api repos/unicode-org/icu/releases/latest`; CLDR: `gh api repos/unicode-org/cldr/tags` | — |
| **Chrome/Chromium** | [deps/icu README.chromium](https://chromium.googlesource.com/chromium/deps/icu/+/refs/heads/main/README.chromium) (`Version:` line) | Per Chrome release: get release tags from the [ChromiumDash JSON API](https://chromiumdash.appspot.com/fetch_releases?channel=Stable&num=1), then fetch that tag's `DEPS` (append `?format=TEXT`, base64) → icu pin → that revision's `README.chromium` | None exposed to JS — fingerprint probes only (by design, this gap is the registry's job) |
| **Edge / Brave / Electron** | inherit Chromium | Electron: `gh api repos/electron/electron/releases` lists the Chromium version per release → Chromium method above | Electron: `process.versions.chrome` → map |
| **Firefox** | [firefox-source-docs intl/icu](https://firefox-source-docs.mozilla.org/intl/icu.html) | Fetch `intl/icu/source/common/unicode/uvernum.h` from the release tag on hg.mozilla.org (`raw-file`) or the GitHub mirror; check `intl/icu-patches/` for the local patch list while there | None exposed — fingerprint probes; remember partial [ICU4X migration](https://firefox-source-docs.mozilla.org/intl/icu4x.html) means engine ≠ pure ICU |
| **Safari / macOS / iOS** | [apple-oss-distributions/ICU tags](https://github.com/apple-oss-distributions/ICU/tags) | Map tag → OS release via [apple-oss-distributions/distribution-macOS](https://github.com/apple-oss-distributions/distribution-macOS) (per-macOS-release manifests list the exact `ICU-xxxxx` build); leading digits of the tag = upstream ICU major | No public version API; fingerprint probes (mandatory anyway — it's a patched fork) |
| **Node.js** | release blog posts | Without installing: `https://raw.githubusercontent.com/nodejs/node/vXX.Y.Z/deps/icu-small/source/common/unicode/uvernum.h`; the [nodejs/node releases feed](https://github.com/nodejs/node/releases) flags `deps: update icu` commits | **`node -p process.versions`** → `icu`, `cldr`, `tz`, `unicode` — the gold standard; every platform should envy this |
| **Deno** | Deno release notes → bundled V8 | `deno --version` → V8 version → map V8 major to Chromium milestone → Chromium method | No `process.versions.icu` equivalent; probe |
| **Bun** | Bun release notes / vendored WebKit | Check `bun --revision` → [oven-sh/WebKit](https://github.com/oven-sh/WebKit) pin → WebKit's `Source/WTF`/ICU linkage per platform | `bun -e 'console.log(process.versions)'` — check per release whether an `icu` key exists; otherwise probe |
| **Windows 10/11** | none — undocumented | none (this is the gap) | `(Get-Item C:\Windows\System32\icu.dll).VersionInfo` as a heuristic; authoritative: tiny native/C# probe calling `u_getVersion()` + `ulocdata_getCLDRVersion()` in `icu.dll`, run per Windows build. The registry should publish this probe binary |
| **Android** | [official i18n table](https://developer.android.com/guide/topics/resources/internationalization) | AOSP per release branch: `https://android.googlesource.com/platform/external/icu/+/refs/heads/androidXX-release/icu4c/source/common/unicode/uvernum.h?format=TEXT` | `android.icu.util.VersionInfo.ICU_VERSION` and `android.icu.util.LocaleData.getCLDRVersion()` — documented APIs; OEM devices still need the probe (deltas) |
| **Linux distros** | [repology](https://repology.org/project/icu/versions) | **`https://repology.org/api/v1/project/icu`** — one JSON call covers every distro/release; spot-check via packages.debian.org / packages.ubuntu.com | `icuinfo` prints ICU + CLDR; `pkg-config --modversion icu-uc` |
| **OpenJDK** | `LocaleServiceProvider` javadoc per release (documents CLDR version since [JDK-8327259](https://bugs.openjdk.org/browse/JDK-8327259)) | Search [bugs.openjdk.org](https://bugs.openjdk.org) for "Upgrade CLDR to" / "Update CLDR to" fixVersion | `java -version` → javadoc lookup; locale provider order via `-Djava.locale.providers` |
| **.NET** | [globalization-icu docs](https://learn.microsoft.com/en-us/dotnet/core/extensions/globalization-icu) | App-local pin: the referenced `Microsoft.ICU.ICU4C.Runtime` NuGet version | It's *system* ICU, so probe the OS row (Windows icu.dll / distro libicu); the docs include a snippet to detect ICU-vs-NLS mode |
| **Go (x/text)** | `golang.org/x/text` source | grep the `CLDRVersion` constant in `x/text/unicode/cldr`; check collate/table generation comments for the (older) table versions | pinned per module version in `go.sum` — deterministic, just old |
| **PostgreSQL** | links system libicu | distro row above | `SELECT collversion FROM pg_collation WHERE collprovider='i'` (collator data version); `icuinfo` on the host for the library version |

### Automation sketch

A `tools/locale-survey/` script (or a scheduled routine) could refresh every **[verified]** cell: ~10 HTTP fetches (ChromiumDash JSON, repology JSON, GitHub APIs, raw `uvernum.h` files) parse with regex-level effort and diff against the tables above; anything that moved opens a PR updating this file. The rows marked "probe" (Windows builds, Apple/OEM devices, Bun/Deno behavior) are exactly the rows automation can't reach from a server — which is the registry's Source-2 fingerprinting justification, restated as an ops constraint.

## Where drift hits hardest: markets and scripts

Version skew is not uniformly painful. English between CLDR 25 and 48 is mostly spacing and abbreviation nuance (the U+202F class); other locales change *digit script*, *calendar day*, or *whether the locale exists at all*. Four distinct mechanisms, each with a flagship market:

### India & Indonesia — maximal fleet spread × fastest-improving data

The two effects multiply: these are the largest old-Android fleets on earth (the Android ladder above — API 24 = CLDR 28 — is lived reality, since budget devices stay in service for many years), *and* Indic/SE-Asian locale data improved more between CLDR 28 and 48 than any Western European locale did. Consequences:

- **Locales that don't exist on old stacks:** `hi-Latn` (romanized Hindi, "Hinglish" — added ~CLDR 40) simply isn't there on a 2017 device; formatting falls back to root/English silently. The failure mode isn't "slightly different bytes," it's "wrong language."
- **Indian digit grouping** (lakh/crore: `1,23,45,678` — variable 2,2,3 grouping) is exactly the feature hand-rolled and stale stacks get wrong; INR amounts render in the Western pattern on part of the fleet.
- **Grapheme segmentation for Indic scripts** (virama conjuncts) shifts with Unicode versions → truncation, cursor movement, and character-count validation disagree between subsystems on the *same* device.
- Indonesian adds an identifier landmine: its ISO code migrated `in` → `id`, and legacy Java still canonicalizes to `in` — cross-stack locale-ID disagreement before any data is even consulted.

### Arabic / MENA — largest per-version visual deltas

- **Digit script defaults flipped across CLDR releases and differ by region** (`ar-EG` → Eastern Arabic-Indic ٠١٢٣, `ar-MA`/`ar-DZ` → Latin): a version skew here changes every digit on the screen, the most visible delta locale data can produce.
- **Hijri calendar (islamic-umalqura) data changes move dates by a whole day** — and a day matters when it's Ramadan's start or an official Saudi document date. Two subsystems with different ICU vintages will disagree on *what day it is*.
- Six plural categories, bidi runs through every mixed-direction string, and Arabic-script collation leans on contractions — all high-churn algorithm+data territory.

### China — where version *mapping* itself collapses

- The fleet is domestic Android forks (MIUI et al.), **HarmonyOS NEXT** (no longer Android — its own frozen stack), and above all the **WeChat in-app browser and mini-program runtime**: a browser fleet of a billion-plus users with its own frozen Chromium/ICU vintage that no public table documents. China is the registry's probes-only market par excellence.
- **GB18030-2022 makes character repertoire a legal compliance matter**: the mandatory standard requires support for CJK extensions that old ICU/Unicode vintages predate — frozen stacks aren't just stale in China, they can be *non-compliant by regulation*.
- zh collation is genuinely plural (pinyin vs stroke vs radical-stroke ordering) with large, version-sensitive tables — contact-list ordering visibly reshuffles across vintages, and zh-Hans/zh-Hant/zh-HK fallback chains have shifted across CLDR releases.

### Japan — the sharpest single-event proof

The 2019 **Reiwa era transition**: any ICU older than 64.2 formats Japanese era dates as Heisei 31+ instead of Reiwa. Note what that indicts — **UE4's bundled ICU 53 predates Reiwa**, so a frozen-engine title formats the imperial era *wrong in Japan*, today, on every platform identically. Era-aware dates appear on receipts, contracts, and government-adjacent UI; this is a correctness-and-respect failure, not a nuance. It's the cleanest one-sentence argument that "pinned" must come with a deliberate upgrade path (the upgrade-as-diff story), not abandonment.

### Honorable mentions

**Thai/Khmer/Lao/Burmese**: word/line breaking requires bundled dictionaries that grew substantially across ICU versions — old stacks break lines mid-word, and Burmese support arrived late enough that 2010s vintages are simply wrong. **Iran**: Solar Hijri calendar data and arithmetic differ across vintages. **Turkey**: the casing problem is version-independent but subsystem-boundary-dependent. **Ethiopia**: Ge'ez calendar, late CLDR arrival.

### Consequences for the QIP plans

1. The i18n first wave (drafts/i18n-formatting.md) should treat **ar (digit systems + Hijri), hi (grouping + hi-Latn), id, ja (eras), th (segmentation-adjacent)** as first-class proof locales, not exotics — they're where pinned-and-portable formatting is *most* valuable, and where the Intl-duel conformance report will show the largest, most demo-able divergences.
2. For the registry, the highest-value coordinates are precisely the least-documented ones: WeChat webview vintages, HarmonyOS, Indian OEM Android builds — probes-only territory where a public fingerprint database has no competition at all.
3. The marketing demo writes itself: one timestamp and one price rendered across CLDR 28 vs 48 in `ar-EG`, `hi-IN`, and `ja-JP` (era boundary) shows digit-script flips, grouping changes, and a wrong imperial era — far more visceral than any English example.

## Documented incidents: when this made the news

Four incidents with strong public records — these seed the products' known-issues database (drafts/locale-products.md) and, usefully, each one evidences a *different* product claim.

### 1. Lebanon, March 2023: Apple and Google disagreed on what time it was — in the same country

The government postponed the DST switch with two days' notice; institutions split along sectarian lines, and for several days Lebanon ran **two simultaneous civil times**. The tech layer couldn't keep up: iPhones kept the old rule while Google showed the hour behind, and Beirut airport's departure board listed the *same flight* at both 3:30 and 4:30 ([CNBC](https://www.cnbc.com/2023/03/27/lebanon-in-two-different-time-zones-as-government-disagrees-on-daylight-savings.html), [CNN](https://www.cnn.com/2023/03/25/middleeast/lebanon-daylight-savings-intl/index.html), [The Register](https://www.theregister.com/2023/03/28/lebanon_dst_delay_chaos/), [Al Jazeera](https://www.aljazeera.com/news/2023/3/26/lebanon-awakes-to-two-times-of-day-amid-daylight-savings-dispute)). *What it proves:* the "two vendors, two data revisions, two answers" problem at international-news scale — the directory's core pitch, starring tzdata instead of CLDR.

### 2. Japan, 2019: the Reiwa era bug — "Japan's Y2K"

Era-formatted dates permeate receipts, banking, and government documents, and nearly all deployed software predated the era change. Covered as a Y2K-class event ([US News: "New Imperial Era Causes Y2K Worries in Japan"](https://www.usnews.com/news/best-countries/articles/2019-04-26/new-imperial-era-causes-y2k-worries-in-japan)); Microsoft shipped emergency updates across every supported Windows ([KB4469068](https://support.microsoft.com/en-us/topic/summary-of-new-japanese-era-windows-updates-kb4469068-1e760b2f-619a-ab02-723a-5b7e97a916bf)) and published app-preparation guidance; a real failure landed anyway — konbini ATMs told customers deposited funds would be available **May 7, 1989** (Heisei 1 computed where Reiwa 1 belonged; [Wikipedia: Japanese calendar era bug](https://en.wikipedia.org/wiki/Japanese_calendar_era_bug)). *What it proves:* frozen locale data is a latent correctness bug with a scheduled detonation date — and (per the market section) engines pinned on ICU 53 re-detonate it quietly forever. The SDK's upgrade-as-diff story is the designed answer.

### 3. The U+202F rollout, winter 2022–23: browsers broke the web with a space character — then partially retreated

ICU 72 swapped regular spaces for U+202F/U+2009 in time formats. CI suites and naive parsers failed at scale; the Node tracker filled with reports when **Node 18.13 — a patch release inside an LTS line — changed date output** ([nodejs#46123](https://github.com/nodejs/node/issues/46123)); Mozilla triaged a meta-bug of affected *sites* ([bug 1806042](https://bugzilla.mozilla.org/show_bug.cgi?id=1806042)) and **backed the ICU update out of Firefox 109 beta** to avoid breaking the web three weeks before Chrome 110 shipped the same change ([bug 1792775](https://bugzilla.mozilla.org/show_bug.cgi?id=1792775)). Browsers even discussed post-processing ICU output back to ASCII spaces as a compatibility shim. *What it proves:* the within-LTS drift claim (verbatim), the fleet-desync claim (two browsers shipping the same data weeks apart is a compat event), and the emulator's CI use case — every one of those broken assertions was a test that pinned oracles would have kept green.

### 4. glibc 2.28, 2018–19: a locale-data update silently corrupted PostgreSQL indexes

The glibc 2.28 collation overhaul (to ISO 14651:2016 / Unicode 9 order, affecting even `en_US`) changed sort order under existing btree indexes; tuples became invisible to lookups and unique constraints stopped deduplicating until every text index was rebuilt ([Debian glibc list](https://lists.debian.org/debian-glibc/2019/03/msg00030.html), [Crunchy Data remediation guide](https://www.crunchydata.com/blog/glibc-collations-and-data-corruption), [PostgreSQL wiki](https://wiki.postgresql.org/wiki/Collations), [daniel Vérité's warning](https://postgresql.verite.pro/blog/2018/08/27/glibc-upgrade.html)). PostgreSQL responded by *building drift detection into the database* (`collversion` tracking + mismatch warnings) and later a version-independent `builtin` provider. *What it proves:* locale data is load-bearing infrastructure whose drift corrupts **data at rest**, not just pixels — the persistence-poisoning class from the intra-machine section, realized at fleet scale.

Honorable mentions with public records: Turkey's 2016 DST abolition and Egypt's 2023 short-notice DST reintroduction (tzdata lag leaving phone clocks wrong nationwide), and the running React hydration-mismatch genre wherever Node and browser ICU vintages disagree. The pattern across all four majors: **nobody's application code changed.** The data moved underneath — or failed to move when the world did.

## What the survey proves (for the registry and the i18n components)

1. **Every cell in these tables is a distinct formatting oracle.** The two-monoliths pain from drafts/i18n-formatting.md is really an N-monoliths reality: a typical product today spans Chrome 78-era CLDR 48, an iPhone on Apple-forked CLDR 46, a Node LTS that silently moved 47→48 in a patch release, a RHEL 9 Postgres collating at CLDR 37, and a JDK 21 service on CLDR 43 — five revisions of "the truth" in one request path.
2. **Update policies differ in kind, not just speed:** Node upgrades ICU inside LTS lines; Java never does; Chrome froze for two years then jumped four CLDR releases; Windows updates silently and undocumentedly; Apple ships a patched fork on an OS cadence; Go pins forever. No amount of "keep everything updated" discipline can synchronize policies this different — which is the strongest argument yet that pinning data *in the artifact* (the QIP move) is the only convergence point.
3. **Registry coordinates need more than a version number:** Apple and Android require fork/OEM deltas (probes), Windows requires probes because the version is undocumented, Firefox requires patch-set awareness (icu-patches + partial ICU4X). The Source-2 fingerprinting design in locale-registry.md is not optional garnish; for four of the biggest platforms it's the only reliable source.
4. **Best-documented platform: Android** (first-party table); **worst: Windows** (in-box, undocumented, servicing-updated). The registry's initial coverage should mirror where documentation is weakest and fleet share is highest: Windows builds and Apple OS versions first.
5. **The registry's coordinate is (data family, revision), not just an ICU number.** The long tail splits into at least four families — ICU-lineage (browsers, Node, Android), CLDR-without-ICU (OpenJDK, ex_cldr, x/text, ICU4X, Flutter), own-data (glibc localedata, Windows NLS, rails-i18n, MySQL collations), and none (Erlang stdlib, musl, Go stdlib) — and members of different families never agreed *at any version*. Meanwhile the ecosystems that solved drift for themselves all converged on the same move QIP generalizes: pin the data in a versioned artifact (ICU4X data crates, Blazor's sharded icudt, ex_cldr Hex packages, .NET app-local ICU, MySQL naming UCA 9.0.0 into the collation identifier). Go's stale x/text is the cautionary counterexample: pinning without a refresh pipeline decays into pinned-but-abandoned — which is why the CLDR-to-Zig codegen tool in drafts/i18n-formatting.md matters as much as the components themselves.

Sources: [ICU download/release history](https://unicode-org.github.io/icu/download/) · [Chromium deps/icu README](https://chromium.googlesource.com/chromium/deps/icu/+/refs/heads/main/README.chromium) · [Node v24.0.0](https://nodejs.org/en/blog/release/v24.0.0), [v24.16.0](https://nodejs.org/en/blog/release/v24.16.0), [v26.0.0](https://nodejs.org/en/blog/release/v26.0.0), [nodejs#58870](https://github.com/nodejs/node/issues/58870) · [Android internationalization table](https://developer.android.com/guide/topics/resources/internationalization) · [apple-oss-distributions/ICU tags](https://github.com/apple-oss-distributions/ICU/tags) · [Microsoft Win32 ICU](https://learn.microsoft.com/en-us/windows/win32/intl/international-components-for-unicode--icu-) · [.NET globalization & ICU](https://learn.microsoft.com/en-us/dotnet/core/extensions/globalization-icu) · [repology icu](https://repology.org/project/icu/versions) · [Firefox ICU docs](https://firefox-source-docs.mozilla.org/intl/icu.html), [ICU4X in Firefox](https://firefox-source-docs.mozilla.org/intl/icu4x.html), [nixpkgs#484824](https://github.com/nixos/nixpkgs/issues/484824) · [JDK-8333582](https://bugs.openjdk.org/browse/JDK-8333582), [JDK-8327259](https://bugs.openjdk.org/browse/JDK-8327259), [JEP 252](https://openjdk.org/jeps/252)
