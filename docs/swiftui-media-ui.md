# Native Media / Sticker UI

## Integration surface

- Factory: `NativeMediaScreens.make(destination:) -> AnyView?` owns **ImageHost, StickerManage, StickerGroup, StickerSources, StickerAdd, ImageViewer, Web**. Unknown owned arguments display a native failure, not a Web/JSON fallback. Other routes return nil.
- Source ownership: `iosapp/Nodyssey/Native/Media/*.swift`; the deletion-race follow-up also changes only the image-host list/delete branches in `NativeSettings.kt`, their focused tests and contract docs. No Platform, editor, App.swift or project edits in that follow-up.
- Parent must add these Swift files and localized **Media.strings** variants under `Media/Resources/{en,zh-Hans,zh-Hant}.lproj` to the application target. Do not put the test-only `Typecheck/Contracts.swift` in the app.
- Requires the exact shared Foundation API from `swiftui-ui-integration.md`. Reuses `NativeRemoteImage`, `NativeImageGallery`, `NativeBrowser`. Minimum iOS 16; system List/Form/Picker/toolbars/sheets, not a parallel design framework.
- All repository operations use the existing app transport/request facade. No HTTP client, persistent Swift sticker database, fake repository, or authentication-cookie copying was introduced.

## Implemented route behavior

| Route | Implementation |
| --- | --- |
| ImageHost | Real `settings.capabilities.imageHosts` provider list (NODE_IMAGE/LSKY_PRO/EASY_IMAGE/SMMS/IMGBB/CUSTOM), selected-host observation, per-provider draft/readback, explicit save/select/disconnect. Custom file field/header name/secret header value/secure key-value form rows/JSON URL path/URL prefix. |
| ImageHost gallery | Only a browsable capability can invoke listing. User explicitly opens the connection-test/gallery. Remote rows use genuine IDs/URLs. GIF filter, viewer, share/copy via system share sheet, confirmation before deletion; deletion credentials remain Kotlin-only. Post-delete listing is read again. Upload-only providers report unsupported capability rather than pretending to have an empty gallery. |
| StickerManage | Server-provided arranged group keys, drag order, separate folder/group hidden writes, mine/site/GitHub groups, subscription/add/host navigation, link probing, CDN save/test/effective state, native file backup import/export with merge confirmation and partial-failure results, upload queue. |
| StickerGroup | Native image rows, multiselection, rename, drag reorder, single/batch move-to-top/removal with confirmation, external-group collection, undo only the `addedUrls` from this action (never pre-existing mine), link probing, explicit confirmed-Broken removal (Unreachable is not Broken), selected-link export. |
| StickerSources | Pinned SHA and ref, folder order and visibility, change-folder navigation preserving source, explicit check/apply updates, retained source errors/rate-limit reset, unsubscribe confirmation. |
| StickerAdd | Preserves `tab=LINK/HOST/UPLOAD/GITHUB` and `source`. Link paste/file import, deduplicated HTTPS preview/name/select; real host gallery multi-select/GIF filter; PhotosPicker and security-scoped image file importer, Quick Look original preview/name editing, original-format toggle and upload confirmation; explicit GitHub inspection, truncated-tree notice, folder selection/all/none, pinned `expectedSha`, source-change rejection/reinspect recovery. |
| ImageViewer | Validates urls/index and delegates to the existing platform gallery. |
| Web | Maps SIGN_IN/ONE_TAP_SIGN_IN/CHALLENGE/MANAGE/TELEGRAM_BIND to the existing restricted browser. No generic native-screen Web fallback. |

### Secrets and mutations

`MediaSecretEdit` represents **preserve / replace / clear** separately. Untouched values are omitted; explicit clear submits `""`; no masked placeholder is ever sent as a token. Secret input is transient and SecureField-backed, and cleared on form teardown/readback. Header/form values are treated as credentials too. Clearing required credentials may be rejected by the existing repository validator; Disconnect is the explicit full connection removal path. Save is not represented as successful remote authentication.

`MediaAction` owns cancellable single-flight view actions, sanitizes non-bridge failures and suppresses obsolete generation completions; `NativeStore` observation tasks follow view cancellation and null invalidation. Mutations are never retried automatically. `MediaHostService` binds deletion confirmation to a displayed listing revision and provider, checks the selected provider before and after listing and before delete, and re-reads after a successful delete. It also sends `expectedProvider` on listing and, from the confirmation ticket, on delete. Kotlin validates the exact enum against the selected provider **inside the existing settings lock**, before any remote listing or deletion; a mismatch fails with `SOURCE_CHANGED`. Selection/configuration writes share that lock through the whole operation. Missing/invalid delete provider arguments fail closed. Optional list binding preserves existing read-only callers; Media always supplies it, preventing an away-and-back selection race from mislabeling another host's rows. Requests that have already reached the server can still have indeterminate outcomes when canceled; do not automatically retry.

### Picker / upload lifetime

`MediaUploadFileStager` copies original bytes into the app's dedicated `Caches/NativeMediaUploads` area **before the external picker grant ends**. It rejects remote URLs, non-regular files, empty files and files over 64 MiB. It does not decode/recompress GIFs or invent upload results. File import copying runs off Main. PhotosPicker uses imported file representation, not unbounded Data loading. Uploads pass `file:///…` and names to `stickers.upload`; original/prepared semantics and actual progress/FAILED/DONE come from Kotlin.

The upload queue is process-local in the existing library. Queued/failed source copies intentionally survive sheet dismissal for retry; the previous process's staging area is cleaned at the first new selection. Completed files are not currently reclaimed individually during the same process. The bridge has **no per-item cancellation operation**, so there is no fake Cancel Upload button. There is no camera capture screen; PhotosPicker and Files are the implemented native input paths.

### Optional editor picker contract

```swift
NativeStickerPicker { insertion in
    // Editor owns insertion at its marked-text-safe current selection.
}
.environmentObject(app)
```

The picker observes the real library, uses backend group order, filters hidden groups/folders, and emits **site shortcode / Unicode character / safely escaped custom Markdown**, not a site sticker's preview URL. Image thumbnails do not intercept selection taps. The editor may continue reading `stickers.get` independently; no editor files were changed. Parent/editor owns embedding this optional picker and keyboard/selection handoff tests.

## Executed verification

- `python3 iosapp/NativeMediaTests/run-mac-tests.py`: **11 Swift Testing behavioral tests passed**, on the existing isolated Mac CLT runner, Apple Swift 6.4.2. Compiles actual `MediaDomain.swift` and actual NativeCore. Synthetic recording transports are test-only; file staging tests use scratch files and actual byte copies. No network mutations/uploads/deletions were exercised.
- `python3 iosapp/tests/native_image_host_selection_test.py`: **8 Kotlin behavioral tests passed** against exact `NativeSettings.kt`/mapping/release sources and real pinned JVM domain jars. Executes the concrete `iosTest` suite `io.github.nodyssey.ios.native.NativeImageHostSelectionTest` unchanged through `settingsImageHostRequest`, the same internal repository-only entry used by production settings dispatch. No JVM-generated test subclass, runtime app-graph fake or test-owned mutex remains. The compile-only graph/throwing Apple transport signatures are still necessary to compile unrelated parts of the exact source on JVM; they are not instantiated by these tests. This is **not an Apple build or native execution**. Covers a provider switch after the last frontend check with colliding IDs, queued selection before lock acquisition, selection blocked throughout delete listing, malformed/missing provider, successful backend-token deletion, missing image and cancellation/lock release.
- Observed genuine behavioral **RED → GREEN** for Kotlin delete (stale request previously returned success), Kotlin bound listing (previously returned the other provider's rows), Swift delete payload (valid confirmation rejected by contract transport due to missing provider), and Swift listing payload (away-and-back selection previously granted a wrong-provider confirmation). Swift fixtures model the contract; the Kotlin harness independently exercises its actual enforcement.
- Existing release-notes harness: **17 tests passed**; existing supplement/settings harness: **17 tests passed**. Scoped Spotless hook for the two owned Kotlin files reported `IS CLEAN` twice (outer task skipped by the IDE hook), not a repository-wide formatting gate.
- Covered consequences: secret omission versus clear; group order/hidden provenance and canonical site insertion; URL/SHA/folder-selection freshness; pasted link HTTPS filtering/deduplication; upload-only provider rejection; confirmation/provider binding and delete readback; selected-provider change during a pending listing; Markdown escaping without identity changes; local file lifetime/byte preservation/type/size admission.
- Tests were introduced in vertical slices. Initial missing newly designed APIs failed compilation before implementation (not runtime assertion RED). Two later **real assertion RED → GREEN** regressions were observed: provider change during listing incorrectly granted a deletion ticket; a user-provided sticker name/parenthesized URL produced broken Markdown. Both are now passing.
- `python3 iosapp/NativeMediaTests/run-mac-tests.py --typecheck-ui`: all media SwiftUI sources typechecked in Swift 6 against **macOS 26.5 SDK**, with test-only Foundation/Platform signatures and an iOS EditButton signature. The native Files/PhotosPicker/Quick Look signatures were checked on macOS. The iOS fullscreen branch is not checked by that command. This is **not** an iOS/Kotlin link or device test.
- CLT default macOS 27 SDK failed because SwiftUIMacros.StateMacro was unavailable; the existing installed 26.5 SDK was used instead. Build output has CLT missing framework-search-path warnings and iOS-16-compatible one-argument onChange deprecation warnings on the newer macOS target. SSH banner timeouts occurred transiently; connectivity was checked and subsequent real runs succeeded.
- Three native locale tables contain the same generated keys. Literal-key audit is a resource sanity check, not claimed behavioral UI coverage.

## Concrete Apple image-host regression gate

`NativeImageHostSelectionTest` is now a concrete class in the existing `iosTest` source set, with its requester directly calling internal `settingsImageHostRequest(repository, operation, args)`. Both the real `NativeContext.settingsRequest` image-host route and this requester enter `settingsLockedRequest`, which owns the **single existing `settingsWriteLock`**. The private image-host dispatcher cannot be invoked by tests without the lock. The non-image settings path uses that same lock, not another mutex. Select, save, disconnect, current-provider validation, listing and deletion remain inside its transaction; exception mapping and cancellation propagation are unchanged. Tests supply only the in-memory `ImageHostRepository`; they never create the app container or use credentials/live services.

On an Apple-silicon Mac with full Xcode and a suitable simulator, run:

```sh
./gradlew :iosapp:iosSimulatorArm64Test --tests 'io.github.nodyssey.ios.native.NativeImageHostSelectionTest.*'
```

Require the test report to contain **all eight named cases executed, zero failures and zero skipped** (compile-only, disabled targets, stale reports and aggregate success do not satisfy this gate):

- `missingOrMalformedExpectedProviderNeverListsOrDeletes`
- `sameProviderDeletesExactImageWithBackendOnlyToken`
- `missingIdDoesNotDeleteAnotherImage`
- `queuedDeleteValidatesProviderAfterTakingSettingsLock`
- `selectionCannotInterleaveBetweenDeletionListingAndDelete`
- `cancellationDuringDeletionListingReleasesLockWithoutDeleting`
- `providerBoundListRejectsSwitchBeforeDispatch`
- `switchAfterLastFrontendCheckCannotDeleteCollidingIdOnAnotherProvider`

`iosapp/scripts/verify_native_results.py` now requires this suite by default and checks every method above, not just the suite or total count. It rejects missing/skipped cases, duplicate cases (including duplicates replacing a missing case or spread across XML files), and failures/errors; existing suite/count/failure gates remain intact. Archived Apple Gradle reports use `method[iosSimulatorArm64]` testcase names and target-prefixed classnames, so the verifier accepts that exact suffix or a bare method name, not arbitrary suffix stripping. `--required` remains a repeatable replacement for the default suite list; the strict case gate applies whenever `NativeImageHostSelectionTest` is required. For the filtered run above, verify its fresh report with:

```sh
python3 iosapp/scripts/verify_native_results.py iosapp/build/test-results/iosSimulatorArm64Test --required NativeImageHostSelectionTest
```

Local verifier validation: **22 Python unittest tests passed**, including behavioral RED → GREEN for incomplete, skipped and duplicate-substituted case reports, unknown suffixes, the default suite requirement and declared skips. All prior verifier checks remain covered. These XML fixtures test the verifier only; **the eight concrete image-host cases have not been executed on Apple and remain pending the next committed CI run**. The existing CI invocation uses the verifier's default requirements; no workflow edit was needed. Reports must be fresh: this verifier checks contents, not commit provenance or report age.

The seam follow-up was exercised locally on JVM only: the first direct-suite run failed because the class was abstract (`InstantiationException`); after making it concrete, compilation identified the missing injectable entry. These are discovery/API RED evidence, **not new behavioral RED assertions**. Extraction then passed all eight cases, plus the 17-test release-notes and 17-test supplement harnesses without source-list changes. Post-GREEN scratch-only mutations separately proved sensitivity: omitting provider validation caused two assertion failures; omitting the settings lock caused two assertion failures. Those mutation runs are not retroactive test-first claims. Scoped Spotless reported both owned Kotlin files `IS CLEAN`; Gradle also warned that Kotlin/Native cannot execute on this Linux arm64 host. No Apple test execution or Swift/Kotlin app integration is claimed. Save/disconnect exclusion and holding the lock through the delete call are preserved by the common lock structure, not separately suspended by these eight fixtures.

## Remaining acceptance / honest boundaries

1. Parent still owns source/resource target inclusion, full iOS SDK/Kotlin export/Xcode build, launch/navigation integration, and simulator/device interaction checks. Mac signature fixtures cannot establish those gates.
2. Real Photos/iCloud/File-provider permission/revocation, Quick Look, original/GIF upload progress/retry, save/share gallery behavior, browser goal/cookie lifecycle, Dynamic Type and all three runtime language choices need device validation. No live upload/delete was used as a test.
3. Camera capture and per-upload cancellation are not implemented; current native input paths are PhotosPicker/Files and the current backend has no cancel ABI. Same-process completed-upload staging cleanup remains an optimization/lifetime gap noted above.
4. **Native provider-switch deletion race closed.** The prior gap was a switch *after Swift's final check but before Kotlin acquired the settings lock*, not a native settings switch inside that lock. Delete now requires the displayed `expectedProvider`; bound listing checks it too. The existing lock excludes native select/save/disconnect calls until listing/deletion completes. This binds the real provider enum, not a new account/configuration revision: same-provider endpoint/credential changes before dispatch and direct repository writers outside the native settings bridge are not covered by this provider identity contract. Cancellation after a remote mutation remains potentially indeterminate.
5. Editor integration of the reusable picker and app-wide selected-language bundle resolution remain parent-owned. Source completion here is not a claim that every baseline media/device acceptance checkbox is green.
