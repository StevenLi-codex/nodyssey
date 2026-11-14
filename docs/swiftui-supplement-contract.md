# Native supplement contract

Implementation owner: `NativeSupplement.kt`; dispatch stays inside NativeBridge session/cancellation lifecycle. These signatures are fixed for parallel UI integration; implementation/test status is appended below.

## Operations

- request `app.foreground` `{}` → JSON null once the singleton graph is ready and the existing offline scheduler's `onLaunch()` has been invoked. Call on native scene activation (including initial activation); it resumes queued work and schedules maintenance, not notification polling and not Compose startup. Completion acknowledges scheduling, not download completion. Observe existing offline progress for completion; AppDelegate still registers background tasks before launch finishes.

- request `reports.parse` `{code:String, spans?:[AnsiSpan]}` → canonical `QualityReport` JSON or JSON null for non-report text. `AnsiSpan={start:Int,end:Int,fg:Int?,bg:Int?,bold:Bool,underline:Bool}` uses UTF-16 offsets; pass existing RichNode code/spans unchanged. Omit spans for raw ANSI input (shared AnsiDecoder runs). Same shared parser handles NodeQuality and YABS. Report uses existing serial discriminators `field/badges/table/note`, tones `Neutral/Good/Warn/Bad`; feed result into existing `reports.add {entry:{report,postId?,threadTitle?,floor?}}`. Do not fabricate a report on null.
- request `site.get` `{}` → `{current:Site, selected:Site, requiresRestart:Bool, sites:[{id,displayName,origin,hosts,oneTapSignInPath,oneTapProviderName}]}`. Site enum strings `NODESEEK`, `DEEPFLOOD`. Current is the running graph; selected is next-launch NSUserDefaults choice.
- request `site.select` `{site:"NODESEEK"|"DEEPFLOOD"}` → same site snapshot after readback. Persists original iOS `active_site` key; never flips ActiveSite or rebuilds graph. Selecting current cancels a pending change. UI must say next launch, not imply immediate switch. Titles/URLs must use `current` site's displayName/origin until next process launch.
- request `search.history.get` / observe `search.history` `{}` → `[{query,target,categorySlug,sort}]`.
- request `search.history.record` / `search.history.remove` `{query:String,target:"POSTS"|"USERS",categorySlug?:String,sort?:"LAST_REPLY"|"POST_TIME"}` → refreshed history array. Default sort POST_TIME (shared search default, not feed default). Repository owns normalization/dedupe/limit; all identity fields matter.
- request `search.history.clear` `{target:"POSTS"|"USERS"}` → refreshed history array; only that target is cleared.
- request `boards.recent.get` / observe `boards.recent` `{}` → `[String]` slugs.
- request `boards.recent.record` `{categorySlug?:String}` → refreshed slug array; null/blank means whole site and is not recorded. Repository owns MRU/dedupe/limit. No fake clear/remove capability: shared repository exposes record only.
- `settings.set {key:"imagesOnWifiOnly",value:Bool}` now saves through SettingsRepository and returns normal settings snapshot. `settings.capabilities.imagesOnWifiOnly` and `offlineImageReading` are true, matching existing NativePlatform implementation. NativePlatform still owns actual local-first loading, one-shot WiFi monitoring and explicit metered override.

Search history preserves the shared query/target/category/sort identity exactly; no native persistent copy or inferred title/domain. Both `search_history_v3` and `recent_boards` are global shared settings keys (unlike the three site-suffixed home-board arrangement keys). This supplement does not invent site provenance or claim cross-site partitioning. UI must match recent slugs against the current site's real board catalogue; retained search entries have no historical site identity to display. `remove` expects the exact returned entry, including its normalized query and sort.

## Optional-path assessment (not promised)

`network.diagnostics` remains unsupported: `IosAppContainer.networkDiagnostics` is null. Existing `proxy.test` and `doh.test` are real narrow probes, not URLSession timing diagnostics. `settings.changelog` remains unsupported: iOS uses NoAppUpdates. The current release source is **Android-only** `UpdateManifestSource` (OkHttp/java.io), reading the project's published `changelog.json`; the old common ChangelogViewModel comment mentioning GitHub API is stale. Common `releaseNotesText` only formats an existing body and is not a release fetcher. Reusing the Android repository directly on iOS is not possible without an additional platform transport/data-source implementation, outside this essential supplement. The genuine public project releases link remains available in `settings.metadata`. No fabricated notes, latency phases, APK/background-notification/crash-report features were added.

## Status and verification

Implemented all operations above in `NativeSupplement.kt`, with only two dispatch additions in NativeBridge; session reconciliation, in-flight session-change cancellation, sanitized errors and observer invalidation remain unchanged. `NodysseyApp.nativeForeground()` awaits the existing singleton and calls the existing scheduler, leaving legacy Compose startup untouched.

Run `python3 iosapp/tests/native_supplement_test.py` (optional `JAVA=/path/to/jdk21/bin/java`). It compiles the actual supplement/settings source files against the built shared/ui/richtext/designsys JVM jars with cached Kotlin 2.4.20; **17 JUnit tests passed**, including the existing settings mapping suite. New coverage exercises real DataStore file write/reopen, target/scope/sort identity, remove/clear, MRU, WiFi enable/disable and persistence, capabilities, shared NodeQuality/YABS parsing, ANSI tone equivalence, site next-launch/cancel/readback rules and foreground ready→scheduler ordering/failure/cancellation.

Genuine RED was executed before implementation: WiFi setter threw UNSUPPORTED_SETTING, capability output was false, recent-board dispatch returned null, and new report/history/site/foreground entry points were absent. Subsequent GREEN runs passed; no implementation was removed to manufacture failures.

The JVM harness uses explicitly compile-only throwing stubs for Foundation and NodysseyApp, plus an abstract graph signature adapter refining iOS's nonnullable DoH support. Site storage callbacks and scheduler callbacks are injected only for boundary-rule tests. This **does not execute NSUserDefaults, BGTaskScheduler, the actual iOS graph, or NativeBridge lifecycle on Apple**. Parent still must run Kotlin/Native/Xcode compilation and device/simulator verification of site persistence across process launch, foreground queue resumption, offline bytes/WiFi behavior and UI subscription lifetimes. No live account/network mutations were used.

Scoped Spotless IDE-hook check returned six `IS CLEAN` results for owned Kotlin files; outer check tasks are intentionally SKIPPED in that mode. `git diff --check` passed. Linux ARM Kotlin/Native unsupported-host warnings are a real limitation, not an Apple build success.
