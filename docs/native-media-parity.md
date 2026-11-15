# Native media parity: bounded implementation

## Implemented

- `StickerGroup` now uses an image-dominant adaptive grid. A normal tap opens details/preview; selecting is explicit and never inserts content. The editor-facing `NativeStickerPicker` uses an explicit picker mode and retains canonical shortcode/Unicode/Markdown insertion.
- Selection excludes Unicode-only entries, clears when leaving selection mode, and reconciles deleted entries from the observed catalogue. Added empty-group state, selected count, in-group hidden control, export-all outside selection mode, and native context menus.
- Personal stickers retain rename, confirmed removal, confirmed-broken cleanup, collect acknowledgement-based undo, and reorder through Move earlier/later/top. Existing shared operations remain the sole persistence path.
- `StickerManage` group directory now has artwork/count/disclosure while retaining its existing group reorder and hide controls.
- `ImageHost` and the `StickerAdd` host picker now use a thumbnail grid. Image taps preview; picker selection has a separate labelled control. The viewer receives the currently filtered image sequence. Provider-bound delete tickets and explicit confirmation are unchanged.
- Added English, Simplified Chinese and Traditional Chinese resources. Semantic fonts and wider accessibility-category grid columns remain; no new custom animations were introduced.

## Source evidence and audit correction

Read `StickerGroupScreen.kt` route/grid/cell/sheet helpers (108–595), `ImageHostScreen.kt` gallery/tile helpers (661–800), and `ImageViewerScreen.kt` zoom helper (263–367), along with native implementation and the all-pages route/content/account-settings audits.

The audit's requested “drag-range selection” is not what the Android helper implements: a long press without movement selects; dragging reorders only My stickers. This change does **not** claim native drag parity. Native context actions provide reorder alternatives pending device gesture work.

## Integration update

Build64 sources include the editor's replacement of its duplicate picker with
`NativeStickerPicker(onSelect:)`. The combined gate compiled the real Media and
Editing implementations together. The Platform owner also added double-tap zoom
and unzoomed-only drag dismissal; see `native-viewer-gesture-parity.md`. These
supersede the ownership handoffs below, not the remaining device acceptance gates.

## Original Media-only handoff / remaining gaps

- Image viewer double-tap zoom, drag dismissal, single shared gallery chrome and generic image long-press actions are in `Platform/NativeRemoteImage.swift`, outside this task's Media-only ownership. That file was deliberately not modified or copied into a competing viewer. Its real APIs are `NativeImageState.image/data`, `load(_:allowMetered:)`, `cancel()`, `NativeShare(items:)`, `NativeExternalBrowser`, and Photos add-only resource saving. Add any gesture/context actions at that owner; permit dismissal only when unzoomed, preserve page gestures, and honor Reduce Motion.
- No generic collect flow was fabricated. Sticker collection still uses existing operations only, with undo restricted to `addedUrls`.
- The editor owner must replace its separate picker with `NativeStickerPicker(onSelect:)` to consume this canonical observed picker. This task did not edit `Editing/`.
- Inline image long-press hooks require the rich renderer/content owner. `ContentImageGallery.onImage` already preserves the clicked URL and was left unchanged.
- Sticker subscription metadata, paste-backup import, other add-mode layouts, provider configuration and third-party website affordances remain deferred.

## Verification

`NativeMediaTests/run-tests.sh` executed on a real arm64 Mac with Apple Swift 6.4.2: **14 tests passed**, including 3 new interaction tests, existing provider-race/delete-ticket tests, canonical insertion, subscription pinning and original-byte file staging. The initial new-API run failed to compile because `MediaStickerInteraction` did not yet exist; this is API RED, **not** an executed pre-fix assertion failure.

`NativeMediaTests/typecheck-ui.sh` passed using real macOS SwiftUI and SDK 26.5 against the exact modified group/management sources and the exact gallery source region. App/image boundary types and EditButton are signature-only stand-ins. This is not iOS/UIKit/Kotlin linking. Hashes were verified in a unique remote staging directory. CLT linker search-path warnings and iOS-16-compatible `onChange` deprecation warnings remain.

No device/simulator gestures, VoiceOver, visual parity, photo permission, share presentation or live image/server interactions were exercised. Source audit and signature checks are not visual proof. Image transport, Wi-Fi override policy, cache/SVG processing, image byte cancellation, sharing lifetimes, storage, auth and Kotlin were unchanged.
