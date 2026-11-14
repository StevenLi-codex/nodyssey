# SwiftUI Settings / Support

## Integration surface

`NativeSettingsScreens.make(destination:)` owns all 13 assigned routes and returns native Form/List/NavigationStack screens, never Compose or a generic website wrapper. Sources: `iosapp/Nodyssey/Native/Settings/`. Add every Swift source to the application target and add the three `Resources/{zh-Hans,zh-Hant,en}.lproj/Settings.strings` files as a localized **Settings.strings** resource. Existing shared keys stay in Localizable.strings. `SettingsLicenseText.swift` embeds the repository's complete GPL v3 text verbatim; original project/author attribution and original dependency catalogue remain visible. No third-party Swift runtime dependency was added.

Depends on the Foundation integration contract, unchanged. `site.get/site.select` and Wi-Fi-image setter/capabilities use the completed supplement contract. Changelog uses the separate real release-notes contract, not the earlier unsupported baseline.

## Routes and real behavior

| Route | Implemented behavior / truthful boundary |
|---|---|
| Settings | Read-back settings writes, next-launch site selection/cancel pending, language/font/e-ink, actual history retention choices (100/300/1000/Int32.max), capability-gated Wi-Fi images, process-local showBlockedContent, cache size and destructive clear confirmation, cross-domain links. |
| ThemeSettings | System/light/dark, original six preset IDs, preset/custom source, signed Int32 ARGB hex validation, system ColorPicker, PhotosPicker thumbnail + system eyedropper, save/rename/delete themes, live native accent preview. Source selection is deliberately independent from saving seed. |
| DynamicColor | Explicit iOS wallpaper/Monet public-API limitation; real route to custom/photo color, no fabricated wallpaper colors. |
| NotificationSettings | Reads actual system authorization, opens app system settings, explains absence of background polling/delivery, links to manual notifications, keywords, tracked threads and Telegram account flow. No inactive master/category/frequency switch or unnecessary permission prompt. |
| ProxySettings | HTTP/SOCKS, host/port, username, transient SecureField, scope, save/readback, independent enable/disable. Untouched password omitted; explicit clear sends empty string. Saved enabled configuration only is tested, on button press only. WebView exclusion disclosed. |
| DohSettings | Existing server catalogue, custom add/edit/delete, bootstrap override/default restore, restore missing presets, single effective selection, save/readback, enable/disable and explicit real resolution results. No unsupported IPv6/fallback/ordered-failover toggles. Legacy multi-checked state is preserved on master-only writes; explicit save normalizes selection. |
| NetworkCheck | Honest unavailable phase-metrics explanation and navigation to real proxy/DoH checks; does not label those checks full diagnostics. |
| AboutApp | Actual metadata version/project/issues/community channels, preserved attribution, help/privacy/licenses/releases navigation; no APK/self-update/crash-export claims. |
| Privacy | Real TermsRepository Heading/Paragraph/ListBlock document, loading/failure/retry; not invented policy text. |
| Changelog | `settings.changelog {includePreRelease}` on opening/filter/retry. Native release list and detail, date/pre-release marker/plain `text`, optional source release link. Filter is transient, not updateDevChannel. Malformed data is error, valid empty is empty. Project history may contain Android changes, not an iOS update offer. |
| Help | Native concise guide to actual navigation, library and editor flows; five-page replay sheet returns to existing navigation, writes onboardingSeen only on completion/skip. |
| OpenSourceLicenses | Full offline GPL v3 and original project/author attribution, metadata dependency catalogue and source links, transitive-version lockfile caveat. |
| TitleKeywords | Original `alerts` argument, ALERT/BLOCK/BLOCK_REGEX switching, shared normalization/regex validation, observation, add/delete and error handling. Alert storage explicitly does not imply background delivery. |

## All 42 UserSettings fields / ownership audit

The JSON snapshot is not a capability declaration. The matrix accounts for all fields, including those whose consumers belong outside this directory.

| Fields | UI / consumer ownership |
|---|---|
| themeMode, appLanguage, colorSource, presetId, seedColor | Settings controls; Foundation applies native mode/locale/accent. Six actual preset IDs retained, native system surfaces are not an exact Material palette port. |
| wallpaperSeed, wallpaperSystemPalette, wallpaperAutoUpdate | Preserved, read-only; explicit iOS wallpaper limitation. |
| paletteStyle | Foundation currently only distinguishes MONOCHROME from regular accent; full Soft/Vibrant/Expressive/Neutral algorithms require Foundation integration, not persistence-only switches. |
| savedThemes | Shared theme save/delete; rename by same color+new name. |
| fontScale, einkMode | Foundation consumer uses semantic Dynamic Type, forced light/primary tint/no explicit animations. Device verification of complete e-ink appearance remains necessary. |
| oneHandMode | Original expandable one-hand title has no native consumer yet; explained, no inactive toggle. |
| stickerUniformSize, stickerSize | Renderer currently has a fixed ScaledMetric; requires Rendering owner to consume these. Explained, no inactive toggle. |
| imagesOnWifiOnly | Complete supplement setter/capability; existing NativePlatform strict local-first/off-Wi-Fi deferred reader consumes it. Device test still required. |
| reportFormat | Content currently offers local report source/adapted mode; stored global preference consumer still requires Content integration. |
| feedSort, homePageBar | Content currently initializes LAST_REPLY and always draws page entry. Must consume stored settings and persist sort changes before global controls are enabled. |
| clipboardPostPrompt | No native consumer; explained, not exposed as functional switch. |
| holidayTheme, hiddenHomeBoards | Remote AccountPreferences owns mutations, not a local settings imitation. |
| searchHistory, recentBoards | Content owns exact identity-based history/MRU operations via supplement. |
| homeBoardOrder, disabledHomeBoards | ContentBoardManager/ContentFeed owns arrangement and consumer. |
| postToolbarActions, replyToolbarActions, messageToolbarActions | Editing/EditorPanels owns arrangement and real surface toolbar consumer. |
| notificationsEnabled, notificationPollMinutes, notificationsWifiOnly, notificationQuietHours, notifyInteractions, notifyMessages, notifyKeywordAlerts, notifyTrackedThreads | Preserved, no background poll/delivery implementation; actual authorization is separate, no inactive controls. |
| readHistoryLimit | Shared choices only; settings.set trims shared history. |
| updateCheckOnLaunch, updateDevChannel | Preserved; appUpdates false. Changelog pre-release filter does not mutate these. |
| onboardingSeen | Foundation initial welcome; native help replay completion/skip writes true without clearing existing navigation. |
| oneHandTipDismissed | No native one-hand tip, so no pretend dismissal write. |

`showBlockedContent` is additional process-local state, not one of the 42 persisted model fields.

## Lifecycle / security

- SettingsAction uses a tested UUID gate: double taps cannot queue a second mutation; cancelled/session-invalidated completions cannot publish or unlock a newer request. Mutations are never auto-retried.
- Shared responses provide read-back snapshots, not optimistic fake success. Error rendering uses NativeFailureView, which never displays arbitrary exception/server messages.
- Proxy password is input-only and cleared after submission/disappearance; no secret enters JSON output, logs or a Swift persistent store. Test buttons never run in `.task`.
- Network form drafts do not hitchhike on enable/disable. Form opening requests only saved configs. DoH result contains only actual returned host/addresses/elapsedMillis.
- Keyword observers are task/cancellation bound; changing kind invalidates old visible state. All screens are session-generation scoped. Keyword input remains editable during add: a successful readback clears only the submitted input revision, never subsequent edits (including A → B → A). The existing SettingsAction gate still owns failure, duplicate-submission and generation/cancellation safety.
- Photos stay local/in-memory and are thumbnail-decoded; iOS ColorPicker/PhotosPicker path still needs actual UIKit/Xcode/device verification.

## Verification

Run from repository root:

```sh
# On macOS (also invoked by the existing ios-swiftui CI workflow):
sh iosapp/NativeSettingsUITests/run-tests.sh

# From the approved SSH runner host; optional absolute logs stay outside the repo:
python3 iosapp/NativeSettingsUITests/run-mac-tests.py --log "$TMPDIR/settings-behavior-actions.log"
python3 iosapp/NativeSettingsUITests/run-mac-tests.py --typecheck-ui --log "$TMPDIR/settings-ui.log"
```

Both normal runners execute **26 base checks**, then **61 action-inclusive checks**, each with zero failures on the approved Mac (Apple Swift 6.4.2). The latter includes the former: **61 distinct checks, not 87**. The Mac runner delegates to the same checked-in `run-tests.sh` as CI, so no scratch adapter or opt-in action flag is needed. Both executables compile actual production `SettingsBehavior.swift` and NativeCore; the second also compiles unchanged production `SettingsComponents.swift` with `-D SETTINGS_ACTION_TESTS`. Its test-only app boundary and unused UI dependency signatures live in the existing conditional section of `main.swift`; `Typecheck/` signatures are not linked into either executable. Any compiler or assertion failure stops the shell runner and propagates through the Mac runner to CI/caller.

The shell runner preserves full-Xcode SDK discovery via `xcrun`, and uses the installed macOS 26.5 SDK only when Command Line Tools is selected and that SDK exists. Builds use a disposable directory under `$TMPDIR`, removed on exit. `--typecheck-ui` remains a separate signature-only gate.

The base checks cover secret omission/replacement/clear, malformed/signed/out-of-range ports, legacy DoH single-selection/bootstrap retention/missing identity, duplicate request/stale completion gate, signed ARGB/partial hex, empty-vs-malformed release responses and hostile release links, plus three keyword draft regressions. Historical evidence is in `NativeSettingsUITests/Evidence/`; new execution logs are kept outside the repository.

TDD honesty: first new APIs produced genuine missing-production compiler RED before implementation (not runtime assertions). A subsequent signed-port regression was observed as **runtime assertion RED**, then corrected and GREEN. Do not label all compiler RED logs executed assertion failures.

All domain SwiftUI sources **typechecked with real macOS SwiftUI** under Swift 6 using macOS 26.5 SDK and signature-only Foundation contracts (`19-final-ui.log`, exit 0). Final behavior run is `18-final-behavior.log` (23 checks, exit 0). Resource audit checked 178 referenced keys with no missing key, 48 matching domain keys in each of three locales, all 42 UserSettings names in the ownership matrix, and verbatim GPL text. These are resource/schema checks, not behavioral UI tests. These stubs are never shipped and do not produce data. Default newer SDK failed because the CLT installation lacks SwiftUIMacros; pinning the existing 26.5 SDK avoids that toolchain prerequisite failure. Transient nested-SSH banner timeouts were retried. This is **not an iOS build**, Kotlin ObjC ABI/link check, simulator run or live proxy/DNS test.

## SETTINGS-1: keyword draft stale completion

`SettingsKeywordsScreen` binds its field to the production `SettingsKeywordDraft.text`. Each write changes an opaque revision; the add button captures that revision before invoking the unchanged `SettingsAction`. Accepted success still publishes the repository list, but only clears an unchanged draft. No Kotlin change or second repository model is needed: `keywords.add` already captures the submitted text and returns the actual list.

Behavioral TDD evidence (Apple Swift 6.4.2, approved Mac):

- `settings-1-api-red.log`: missing new helper, compiler exit 1, **not** a runtime assertion.
- `settings-1-behavior-red.log`: after extracting the original unconditional clear into the UI-connected helper, **24 checks / 1 failure**, exit 1: `delayed keyword A success must preserve newer draft B`.
- `settings-1-behavior-green.log`: adding the revision guard gives **24 checks / 0 failures**, exit 0.
- `settings-1-final-behavior.log`: **26 checks / 0 failures**, exit 0, including unchanged A clears and A → B → A remains intact.
- `settings-1-actions-green.log`: **61 checks / 0 failures**, exit 0. Compiles the real `SettingsAction` from `SettingsComponents.swift` with `SETTINGS_ACTION_TESTS`; only the app request boundary and unused view dependencies are synthetic. Delayed continuations exercise edited/unchanged/reentered success, unchanged/edited failure, generation mismatch before lifecycle cancellation, and generation cancellation followed by a deliberately late successful reply. Every scenario also checks captured A, duplicate rejection, readback publication, busy release and failure handling. This is executable action testing, not SwiftUI lifecycle automation or a backend test.
- `settings-1-final-ui.log`: complete Settings sources pass the existing Swift 6 macOS 26.5 signature typecheck, exit 0.

These original SETTINGS-1 logs and the historical scratch adapter are in `/home/hermes/.hermes/cache/scratch/`, not the historical `Evidence/` directory. The adapter is superseded by the checked-in normal runners above and should not be used with the new runner. Durable-runner verification captured the previously missing action-suite result first, then executed the shared shell runner on the approved CLT Mac: **26/0 base and 61/0 action-inclusive checks**, exit 0. No production sources or test assertions were changed to integrate the runner.

The action suite exercises production action/gate code against synthetic checked continuations; its placeholder UI dependencies are test-only. It does not automate the actual TextField or view lifecycle. Full-Xcode SDK selection is retained, but the durable-runner execution recorded here used CLT, not full Xcode.

Remaining SETTINGS-1 acceptance: full Xcode/iOS build and actual TextField interaction/lifecycle tests on simulator or device (edit while add is pending, failure, session change and dismissal). macOS helper/action execution and signature checking do **not** establish UIKit runtime behavior, Kotlin linkage, live keyword persistence or backend execution. Existing broader integration gates below are not closed by this fix.

## Parent integration gates / exact remaining work

- Wire settings Swift sources and localized Settings table into the Xcode target; do not package test Typecheck signatures.
- Foundation: full palette styles, complete e-ink behavior, one-hand consumer if baseline parity required. Current regular-accent/monochrome modes must not be described as all five palettes.
- Content: consume `app.settings["feedSort"]`, write `settings.set {key:"feedSort",value}` on user selection, honor `homePageBar`, use `reportFormat` for initial report mode. These do not need new bridge APIs; they need actual consumers.
- Rendering: consume `stickerUniformSize/stickerSize`; then enable corresponding controls. Existing fixed sticker size is not completion.
- Full device/Xcode acceptance: language change without losing navigation, photos/eyedropper, settings rollback, site next-launch/cancel, proxy credentials & traffic, DoH platform behavior, read-back history trim, cache confirmation, release source failures and in-flight dismissal.
- NetworkCheck/notification background polling remain genuine implementation gaps. No `network.diagnostics` fake payload or inactive notification switch was added.
