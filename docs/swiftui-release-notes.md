# Native read-only release notes

## Fixed UI contract

`settings.changelog` request `{includePreRelease?: Bool}` (default false) returns the usual NativeBridge success envelope whose `data` is:

```text
{
  sourceUrl: "https://5151561.github.io/nodyssey/changelog.json",
  includesPreRelease: Bool,
  releases: [{versionName: String, tag: String, publishedOn: String,
              preRelease: Bool, notes: String, text: String, htmlUrl: String}]
}
```

`notes` is published Markdown; `text` uses common `releaseNotesText` for plain native rendering. `htmlUrl` is an optional link encoded as empty string when absent, otherwise restricted to the project's HTTPS release-tag URL. Use native text, not a generic website fallback. The source is project history, including Android-specific changes, **not** iOS update availability. Sort newest first with common `compareVersionNames`. `includePreRelease` is a transient read filter, not the unsupported update-channel preference.

Capability `releaseNotes` becomes true; `appUpdates` stays false. No observation/background fetch, update check, APK download/install, or persistent native cache. Fetch only when the user opens/retries this screen. NativeBridge owns cancellation and safe envelopes.

Failure codes: `NETWORK`, `RATE_LIMITED` (HTTP 429), `RELEASE_NOTES_HTTP` (other non-2xx), `RELEASE_NOTES_UNREADABLE` (invalid/unsupported/oversized manifest), `RELEASE_NOTES_SOURCE` (unexpected final response URL). Invalid argument types use the existing invalid-argument boundary. Failed fetches never masquerade as empty history. An explicitly published valid empty `versions` array is an honest empty result.

## Source discovery

Existing Android `UpdateManifestSource` reads `changelog.json`; `app/.../NodysseyRelease.kt` pins the base URL above. Common `ReleaseNote`, `compareVersionNames`, and `releaseNotesText` are reusable without the Android update repository. iOS `NoAppUpdates` remains untouched.

A public unauthenticated GET verified HTTP content at the original URL. Existing settings/supplement contracts describe the earlier unsupported baseline; this document supersedes only their changelog/releaseNotes statements.

## Implementation and security boundary

- `NativeReleaseNotes.kt` uses common `HttpTransport` with the existing iOS `NSUrlSessionTransport` and `appleUrlSession`. A short-lived session is created only for this request and invalidated in `finally`, including cancellation. It explicitly sets `cookies = null`, `referer = null`: the shared helper disables cookie saving and has no cookie storage. It never uses `graph.urlSession`/forum signing or touches forum credentials.
- The current real `UserAgent` and `deviceAcceptLanguage()` are retained. Proxy settings are read once per request and translated through common `ProxyConfig.routes(THIRD_PARTY)`: EVERYTHING is honored, FORUM_ONLY stays direct. Proxy authentication remains in the existing Apple session delegate. There is no new graph collector/session singleton or changed network-policy API.
- The only requested URL is the original static source; there is no caller-controlled source, mirror, GitHub API fallback, or new configured domain. Existing URLSession redirect behavior is retained; the response's final URL must exactly equal the source before its body is consumed as notes. **This is a final-source check, not a pre-redirect host firewall**; inherited redirects can be followed, but this session carries no forum cookies or referrer. Actual public retrieval returned 200 directly without redirect.
- Parser/output bounds: UTF-8 manifest at most 1,048,576 bytes; at most 1,000 entries; notes at most 32,768 Kotlin characters each; version at most 128 and tag at most 160 characters. Strict schema 1, field types, numeric dotted version syntax, date shape/ranges, unique version names, matching prerelease marker, and trusted HTTPS release-tag links are validated before filtering. Unknown fields remain forward-compatible. Blank tags use the existing `v$version` fallback; explicitly empty dates/notes/links are retained. Missing required fields, duplicates, and unsupported schemas are not mistaken for valid empty history.
- **The body cap is not a streaming network-memory cap.** Existing `HttpTransport` delivers a fully buffered decoded String. The parser rejects oversized input before JSON parsing; changing that transport contract is outside this work. Existing `getBytes(maxBytes)` can stream-bound bytes but discards the HTTP/final-source detail needed here. No new metrics, platform capability, or memory-limit claim is fabricated.
- Shared `ReleaseNote`, `compareVersionNames`, `isPreReleaseVersionName`, and `releaseNotesText` remain authoritative. No APK fields or installed-version comparison is exposed. `NoAppUpdates` remains unchanged; the new capability describes only history reading.

## Parent Apple execution evidence

Run `43560900650` at `492cbbac27ae0b7c85e085565dadb2e362a08730` compiled the production/test Kotlin sources and executed `NativeReleaseNotesTest` (**6 passed**) and `NativeReleaseNotesAppleTest` (**2 passed**), with zero failures/errors/skips in both XML suites. This verifies the actual Foundation session configuration assertions, not only throwing JVM signatures. The overall Kotlin run executed 48 tests with one separate SVG failure; the workflow was subsequently cancelled when the next diagnostic commit superseded it. The full run is not green. Native changelog screen behavior and actual network cancellation on Apple still require integration acceptance.

Evidence: `/home/hermes/.hermes/cache/scratch/nodyssey-ci-43560900650/artifacts/`, artifact `14100573578`. Parent also updated the supplement JVM harness to compile the new release-notes dependency and reran its 17 tests successfully.

## Verification

Command: `python3 iosapp/tests/native_release_notes_test.py --live` (optional `JAVA=/path/to/jdk21/bin/java`). The ordinary command is offline fixture-only; `--live` explicitly performs a real public GET.

Verified on 2026-11-14 at 04:57 UTC and rechecked after integration:

```text
JUnit: OK (17 tests)
Live JVM HTTP 200; bytes=76938; sourceRows=29; parsedRows=29
sha256=bfe6f3c7b29cba60cf15490fc87d3d3048569af837f1a00ae3b003705bbf42e2
Newest="1.2.22"
```

The live check runs **the exact production fetch/parser/mapping code** with a real JDK HTTP transport. It compares parsed count to the entire fetched manifest and requires actual published text. It does not replace failed network calls with fixtures. `NativeReleaseNotesFixture.kt` commits three verbatim rows (1.2.9, 1.2.22, 1.2.10), reordered to catch lexicographic sort bugs; synthetic prerelease cases are explicitly separate test transformations, not claimed published data. HTTP error, source mismatch, network failure, cancellation, schema/type/bounds/unsafe-link validation, stable filtering, semantic prerelease ordering, author-text preservation, shared formatting and third-party proxy scope are covered. Existing settings mapping/persistence tests run in the same harness.

Observed RED→GREEN: baseline `releaseNotes` capability was false and no parser existed; later real assertions caught accepted oversized manifests/unsafe HTTP release links, mismatched prerelease flags, and unsanitized source-level network errors before fixes. The initial absence-only reflection test and constant-capability scaffolding were removed after implementation; no built implementation was removed to manufacture RED. Final scoped Spotless IDE-hook check returned five `IS CLEAN` results (outer Check task intentionally skipped); `git diff --check` passed.

The JVM harness resolves actual pinned Kotlin 2.4.20, kotlinx JSON/coroutines 1.11.0 and existing built shared/ui/designsys/richtext JVM jars. Apple factory/transport/session APIs are **compile-only throwing signatures**, and the graph is an abstract signature adapter; none of those platform substitutes is executed. This proves portable production logic and JVM dependency signatures, **not** Objective-C ABI, Apple transport execution, or a Kotlin/Native build.

`NativeReleaseNotesAppleTest.kt` adds real Foundation tests for absent cookie storage, cookie-saving disabled, absent Cookie/Referer/Authorization headers, and HTTPS proxy configuration. They are intentionally excluded from Linux. Parent must run them with the full `:iosapp:iosSimulatorArm64Test`/Xcode gate, and verify actual device cancellation and the Swift native route. Linux-aarch64 cannot execute Kotlin/Native. The new file is picked up by the existing iosMain/iosTest source sets; no dependency/build-system changes are needed.

Integration note: older standalone settings/supplement JVM scripts which enumerate source filenames must now include `NativeReleaseNotes.kt` and its compile-only Apple signatures (or use this harness for settings tests). No foreign-owned harness was silently edited. NativeBridge/Core/Swift files were not changed by this work; only the existing settings changelog dispatch and releaseNotes capability were changed outside the new files.
