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
- Keyword observers are task/cancellation bound; changing kind invalidates old visible state. All screens are session-generation scoped.
- Photos stay local/in-memory and are thumbnail-decoded; iOS ColorPicker/PhotosPicker path still needs actual UIKit/Xcode/device verification.

## Verification

Run from repository root:

```
python3 iosapp/NativeSettingsUITests/run-mac-tests.py --log final-behavior.log
python3 iosapp/NativeSettingsUITests/run-mac-tests.py --typecheck-ui --log final-ui.log
```

Approved Mac runner: Apple Swift 6.4.2. Foundation test executable uses actual production SettingsBehavior.swift and actual NativeCore (not a copied JSON implementation). Current **23 behavioral checks pass**, covering secret omission/replacement/clear, malformed/signed/out-of-range ports, legacy DoH single-selection/bootstrap retention/missing identity, duplicate request/stale completion gate, signed ARGB/partial hex, empty-vs-malformed release responses and hostile release links. Evidence is in `NativeSettingsUITests/Evidence/`.

TDD honesty: first new APIs produced genuine missing-production compiler RED before implementation (not runtime assertions). A subsequent signed-port regression was observed as **runtime assertion RED**, then corrected and GREEN. Do not label all compiler RED logs executed assertion failures.

All domain SwiftUI sources **typechecked with real macOS SwiftUI** under Swift 6 using macOS 26.5 SDK and signature-only Foundation contracts (`19-final-ui.log`, exit 0). Final behavior run is `18-final-behavior.log` (23 checks, exit 0). Resource audit checked 178 referenced keys with no missing key, 48 matching domain keys in each of three locales, all 42 UserSettings names in the ownership matrix, and verbatim GPL text. These are resource/schema checks, not behavioral UI tests. These stubs are never shipped and do not produce data. Default newer SDK failed because the CLT installation lacks SwiftUIMacros; pinning the existing 26.5 SDK avoids that toolchain prerequisite failure. Transient nested-SSH banner timeouts were retried. This is **not an iOS build**, Kotlin ObjC ABI/link check, simulator run or live proxy/DNS test.

## Parent integration gates / exact remaining work

- Wire settings Swift sources and localized Settings table into the Xcode target; do not package test Typecheck signatures.
- Foundation: full palette styles, complete e-ink behavior, one-hand consumer if baseline parity required. Current regular-accent/monochrome modes must not be described as all five palettes.
- Content: consume `app.settings["feedSort"]`, write `settings.set {key:"feedSort",value}` on user selection, honor `homePageBar`, use `reportFormat` for initial report mode. These do not need new bridge APIs; they need actual consumers.
- Rendering: consume `stickerUniformSize/stickerSize`; then enable corresponding controls. Existing fixed sticker size is not completion.
- Full device/Xcode acceptance: language change without losing navigation, photos/eyedropper, settings rollback, site next-launch/cancel, proxy credentials & traffic, DoH platform behavior, read-back history trim, cache confirmation, release source failures and in-flight dismissal.
- NetworkCheck/notification background polling remain genuine implementation gaps. No `network.diagnostics` fake payload or inactive notification switch was added.
