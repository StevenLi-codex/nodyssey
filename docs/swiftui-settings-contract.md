# Native settings bridge contract

Internal entrypoints: `NativeContext.settingsRequest(operation, args): JsonElement?` and `settingsObserve(operation,args): Flow<JsonElement>?`. Only an unrecognized operation returns Kotlin null. JSON null is a successful Unit acknowledgement. The core owns envelopes, cancellation, Main callbacks and sanitized errors. All field names follow domain models; enums use `.name`, IDs are integers. No extra Swift persistence.

## Operation vocabulary

The implementation recognizes 83 distinct request/observe names, including explicit unsupported operations below. These are backend operations, not a claim that every native screen or platform service has shipped.

| Request / observation | Arguments | Data |
| --- | --- | --- |
| `settings.get` / `settings.observe` | none | UserSettings fields plus showBlockedContent |
| `settings.set` | `key`, `value` | read-back settings; one field per call |
| `settings.theme.save`, `settings.theme.delete` | `name,color` / `color` | read-back settings |
| `settings.homeBoards` | `order:[String],disabled:[String]` | read-back settings |
| `settings.toolbar` | `surface:POST/REPLY/MESSAGE,actions:[String]` | read-back settings |
| `settings.capabilities` | none | actual iOS capabilities; unsupported controls must not be shown |
| `proxy.get` / `proxy.observe` | none | ProxyConfig without password, plus hasPassword |
| `proxy.save` | ProxyConfig fields (password omitted preserves existing) | redacted persisted config |
| `proxy.enabled` | `enabled` | redacted persisted config |
| `proxy.test` | none | `{connected,kind?}`; explicitly requested network call |
| `doh.get` / `doh.observe` | none | `{config:DohConfig,capabilities:DohCapabilities}` |
| `doh.save` | DohConfig fields (servers use DohServer field names) | persisted config and capabilities |
| `doh.enabled` | `enabled` | persisted config and capabilities |
| `doh.test` | none | DnsResolution; explicit network call, not a fake address lookup |
| `network.diagnostics`, `settings.changelog`, `settings.crashReport` | none | unsupported on current iOS graph; error, never fake success or an empty list pretending to be fetched |
| `imageHost.get` / `imageHost.observe` | optional `provider` | ImageHostConfig without token/headerValue/formFields; hasToken/hasHeaderValue/hasFormFields and isConfigured |
| `imageHost.select` | `provider` | current redacted config |
| `imageHost.save` | `provider,siteUrl?,token?,custom?` | persisted redacted config; absent secrets preserved, explicit empty clears |
| `imageHost.disconnect` | `provider` | persisted redacted config |
| `imageHost.test`, `imageHost.images` | optional `expectedProvider` (exact ImageHostProvider enum name) | selected host listing (only browsable hosts); if supplied, reject provider mismatch with `SOURCE_CHANGED` under the settings lock before host I/O |
| `imageHost.delete` | `id`, required `expectedProvider` from displayed listing/confirmation | Unit; validate provider under the settings lock before listing/deleting; mismatch is `SOURCE_CHANGED`, missing/invalid enum is invalid arguments; deletion credential stays inside Kotlin |
| `offline.get` / `offline.observe` | none | `{isAvailable,settings,usage,states:[{postId,state,...}]}` |
| `offline.settings` | partial OfflineSettings fields | read-back offline snapshot |
| `offline.download` | `postIds:[Int64]` | read-back snapshot, not a claim download completed |
| `offline.cancel` | `postId` | read-back snapshot |
| `offline.clear` | none | read-back snapshot; collections unaffected |
| `offline.estimate` | `postIds` | `{bytes:Int64?}`; null means unknown |
| `cache.size`, `cache.clear` | none | `{sizeBytes}`; clear covers repository text and app filesystem cache |
| `stickers.get` / `stickers.observe` | none | mine, subscriptions, cdn, groupLayout, uploads, linkProbes, sourceErrors |
| `stickers.add` | `stickers:[{url,name}]` | `{addedUrls}` |
| `stickers.addLinks` | `text` | `{addedUrls}` extracted using existing parser |
| `stickers.remove`, `stickers.moveToTop`, `stickers.reorder` | `urls:[String]` | read-back snapshot |
| `stickers.rename` | `url,name` | read-back snapshot |
| `stickers.groups.reorder`, `stickers.groups.hidden` | `keys` / `key,hidden` | read-back snapshot |
| `stickers.cdn` | `cdn,customBase?` | read-back snapshot |
| `stickers.export`, `stickers.import` | none / `text` | `{text}` / StickerImportResult; backup excludes host/proxy credentials |
| `stickers.inspect` | `url` | RepoListing; explicit GitHub request |
| `stickers.subscribe` | `url,paths,expectedSha` | re-inspect and reject moved commit, then persisted snapshot |
| `stickers.unsubscribe`, `stickers.applyUpdate` | `slug` | read-back snapshot |
| `stickers.folders.hidden`, `stickers.folders.reorder` | `slug,path,hidden` / `slug,paths` | read-back snapshot |
| `stickers.checkUpdates` | `force:Boolean` | `{error:StickerSourceError?}`; partial failures retained in snapshot |
| `stickers.probe`, `stickers.probeMine`, `stickers.measure` | `url` / none / `cdn` | LinkProbe / snapshot / `{elapsedMillis?}` |
| `stickers.upload`, `stickers.retryUpload`, `stickers.clearFinishedUploads` | `images:[{source,name}],keepOriginal` / `id` / none | snapshot; upload queued, never fake completed |
| `keywords.get` / `keywords.observe` | `kind:ALERT/BLOCK/BLOCK_REGEX` | string array |
| `keywords.add`, `keywords.remove` | `kind,text` | read-back array; regex uses rebuild-aware store operations |
| `notes.get` / `notes.observe`, `notes.set` | none / `uid,note` | `[{uid,note}]` |
| `tracked.get` / `tracked.observe`, `tracked.add`, `tracked.remove` | none / `postId,title,commentCount?,authorName?,categoryTitle?,categorySlug?` / `postId` | TrackedThread array |
| `reports.get` / `reports.observe`, `reports.add`, `reports.remove` | none / `entry:ReportCompareEntry` | existing serialized ReportCompareEntry array |
| `settings.metadata` | none | app version, links and license metadata |
| `settings.terms`, `settings.privacy` | none | TermsDocument, block `type` = Heading/Paragraph/ListBlock |

Image host connection uses existing API-token configuration. There is no username/password login API or non-upload connectivity test for upload-only providers; `imageHost.login` is explicitly unsupported. Third-party requests remain in the graph's cookie/referrer-free transport. Raw server messages, response bodies and auth/deletion credentials must not be emitted. UI input can carry secrets only app-local in memory. User must explicitly choose tests/imports/uploads; opening observers performs no network calls.

## Settings field and ownership matrix

`settings.get`/`settings.observe` return every `UserSettings` stored/model field (42), plus process-local `showBlockedContent`. Read-only fields are still returned to preserve current state; their presence is **not** a capability flag.

`settings.set` takes exactly one `{key,value}`. Supported keys:

- Enum strings: `themeMode` (`SYSTEM/LIGHT/DARK`), `appLanguage` (`SYSTEM/SIMPLIFIED_CHINESE/TRADITIONAL_CHINESE/ENGLISH`), `colorSource` (`PRESET/CUSTOM`; `WALLPAPER` rejected), `paletteStyle` (`SOFT/VIBRANT/EXPRESSIVE/NEUTRAL/MONOCHROME`), `reportFormat` (`ADAPTED/SOURCE`), `feedSort` (`LAST_REPLY/POST_TIME`).
- String: `presetId` (use the app's actual theme catalogue).
- Integer: `seedColor` (signed ARGB Int32), `stickerSize`, `readHistoryLimit` (repository validates/clamps values; changing history limit also calls `PostRepository.trimReadHistory`).
- Finite number: `fontScale` (repository clamps to its bounds).
- Boolean: `oneHandMode`, `einkMode`, `stickerUniformSize`, `homePageBar`, `onboardingSeen`, `showBlockedContent`; `oneHandTipDismissed` accepts only true.

Dedicated operations mutate `savedThemes`, `homeBoardOrder/disabledHomeBoards`, and `postToolbarActions/replyToolbarActions/messageToolbarActions`. Search history and recent-board recording belong to content operations. Remote `holidayTheme/hiddenHomeBoards` changes belong to account preference operations; this domain deliberately has no local-only mutation that could falsely imply a remote save.

Read-only platform-gap fields: `imagesOnWifiOnly`, `clipboardPostPrompt`, `wallpaperSeed/wallpaperSystemPalette/wallpaperAutoUpdate`, `notificationsEnabled/notificationPollMinutes/notificationsWifiOnly/notificationQuietHours/notifyInteractions/notifyMessages/notifyKeywordAlerts/notifyTrackedThreads`, `updateCheckOnLaunch/updateDevChannel`. Unsupported `settings.set` keys fail with `UNSUPPORTED_SETTING` before writing.

## Snapshot schemas and UI rules

- Proxy: `{enabled,type,host,port,username,scope,isUsable,hasPassword}`. `proxy.save` is a partial draft patch. Password omission preserves, explicit `""` erases, and a failed secret read-back is `SECRET_NOT_STORED`. Turning on an invalid saved endpoint is rejected; turning off does not persist half-edited form fields.
- DoH: `config:{enabled,servers,includeIPv6,fallbackToSystem}`; each server `{id,preset,customUrl,bootstrapOverride,checked,url,bootstrap}`. On iOS `canChooseRecordTypes/canFallBackToSystem/triesServersInOrder` are false. Explicit `servers` may check at most one; unsupported option changes are rejected. Legacy multi-checked defaults are preserved on switch-only edits, with the platform using the first. DoH testing returns the existing iOS tester's host/addresses/elapsedMillis, not invented DNS answers.
- Image host: `{provider,siteUrl,hasToken,isConfigured,problem,custom:{fileField,headerName,hasHeaderValue,hasFormFields,urlPath,urlPrefix}}`. Custom secret values are input-only. `save` does not implicitly select a host and does not imply its remote credential works; use `select` and an explicit supported test. Hosted image results contain `{id,fileName,url,uploadTime,sizeBytes,mimeType}`; deletion tokens never cross the ABI. Listing/test errors preserve safe recovery codes (`IMAGE_HOST_NOT_CONFIGURED/IMAGE_HOST_INVALID_KEY/IMAGE_HOST_CHALLENGE/IMAGE_HOST_REJECTED/IMAGE_HOST_HTTP/IMAGE_HOST_UNPARSABLE/IMAGE_HOST_INSECURE_LINK`, `NETWORK`, `UNSUPPORTED`), not server details.
- Offline: `{isAvailable,settings:{wifiOnly,includeImages,autoSyncReplies,retentionDays},usage:{posts,textBytes,imageBytes,freeBytes,totalBytes},states:[...]}`. State row always contains `postId,state`. `Downloading` adds nullable `progress`; `Downloaded` adds `bytes`; `Stale` adds `bytes,behindReplies`; `Failed` adds `reason` (`OutOfSpace/Network/Unavailable/Challenge/RateLimited`). Missing IDs mean `NotDownloaded`. Queue acceptance is not completion. Account `bookmarks.sync` already supplies reply counts to `OfflineLibrary.noteReplyCounts`.
- Stickers: `{mine:[{url,name}],siteGroups,subscriptions,cdn:{cdn,customBase,effective},groupLayout:{order,hidden},arrangedGroupKeys,uploads,linkProbes,sourceErrors}`. `arrangedGroupKeys` uses the existing `StickerGroupLayout.arrange` algorithm; hidden groups remain present for management. Site groups reuse the real `NodeSeekEmojiGroups` catalogue without calling Compose or embedding a view; keys are `site:ac/site:yct/site:xhj/fluent`, entries are `{type:"Sticker",name,shortcode,url}` or `{type:"Unicode",character}`. Insert the shortcode/character rather than the preview URL. Subscribed folder fields match `SubscribedFolder`, plus `key,entries:[{name,url}]`, with CDN URLs computed by the existing pinned-commit/UTF-8 encoder. Folder hiding comes from each folder's `hidden`; non-folder hiding comes from `groupLayout.hidden`. Upload rows `{id,name,keepOriginal,progress,state,error}` omit source paths and raw exception details; error is a safe code. Picked-image sources must be local `file:///...` URIs. Probes are `[{url,result:{type:"Ok",sizeBytes?}|{type:"Broken",code}|{type:"Unreachable"}}]`. Source errors are `[{slug,error:{type,...}}]`, where `RateLimited` includes nullable `resetAtEpochSeconds`, `Http` includes `code`.
- Keywords return stored normalized strings. BLOCK_REGEX always goes through `addBlockRule/removeBlockRule`, rebuilding the existing regex-hit cache instead of merely inserting/deleting a row. Blank/invalid patterns fail before acknowledgement. Notes return `[{uid,note}]`; tracked rows `{postId,title,lastKnownCount,authorName,categoryTitle,categorySlug}`; tracking unknown counts preserves `-1`, not a guessed page-size count. These stores retain their original device-local lifetime across logout.
- Reports use the existing `ReportCompareEntry` serializer (including the original `QualityReport` model), preserving deduplication/capacity semantics. Do not convert it to HTML or a new parallel report store.
- Terms/privacy use the same real `TermsRepository.terms()` document, not a fabricated policy. Metadata lists existing project/license/community channels; `changelog` is a truthful external releases link, **not** a claim of native release-note fetching. Help metadata likewise points to the actual project; native help/onboarding rendering remains a Swift responsibility.

## Explicit platform gaps / integration handoff

`settings.capabilities` currently reports false for `networkDiagnostics`, `notificationPolling`, `appUpdates`, `wallpaperColors`, `clipboardPostPrompt`, `imageHostPasswordLogin`, `imagesOnWifiOnly`, `releaseNotes`, `crashReports`, `offlineImageReading`. It also returns actual `offline`, image-host provider capabilities, and `retentionChoices`.

These false values reflect the baseline: no network-metrics delegate, `NoAppUpdates.releaseNotes()` empty, `NoCrashReports`, no background notification poller, no image-loader Wi-Fi policy consumer, and no offline-image reader hookup. Do not show functioning switches or claim complete offline image reading from successful downloads. Parent/platform work must implement and test the consumer, then change the relevant capability and mutation together. Apple wall­paper/private-DNS limitations are distinct from missing implementation. The Swift layer must apply theme/language/reading settings and preserve local navigation; successful persistence alone does not prove those UI consumers.

## Verification

- Added `NativeSettingsMappingTest` and `NativeSettingsPersistenceTest` under iosTest. Current JVM fixture run: **10 tests passed**, including secret omission/preservation, strict JSON types, DoH capability rejection, safe error classification, local picked-image validation, real catalogue shortcodes/CDN encoding, real DataStore reopening and unsupported Wi-Fi-image mutation refusal. No test uses user data or makes HTTP calls.
- Command: `python3 /home/hermes/.hermes/cache/scratch/native-settings-tests.py`. It compiles the exact production mapping/dispatcher sources against existing JVM shared/ui jars. A signature-only abstract `AppContainer` refinement replaces the iOS graph type for compilation; it is not instantiated, is not shipped, and does not fake repository results. Persistence tests use real DataStore files in scratch and delete them. This checks JVM API signatures, **not** Objective-C export or an Apple build.
- Scoped Spotless IDE hook reported `IS CLEAN` for all four owned Kotlin files. The outer `spotlessKotlinCheck` task is skipped by that hook; this is not a repository-wide formatting pass.
- Initial direct Gradle test attempt was blocked by absent JAVA_HOME; the available restored JDK was then used for the JVM harness/formatter. Native compilation remains unavailable on linux-aarch64; no iOS simulator/device test has run. The initial four mapping tests were authored before production but could not be executed RED until the JVM harness was available; do not claim a complete test-first history. Later Wi-Fi regression was observed as a real assertion failure before the fix.

Native Apple build/tests require macOS/Xcode. Linux static or shared tests do not establish native build success.
