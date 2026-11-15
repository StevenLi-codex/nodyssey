# Native viewer gesture parity

## Bounded implementation

The shipping `Platform/NativeRemoteImage.swift` remains the only viewer and image-loading owner.
`NativeZoomImage` now supports double-tap to 2.5× around the tap (and back to minimum), plus a
one-finger, predominantly vertical drag to dismiss in either direction after 120 points, only at
minimum zoom. This follows `ImageViewerScreen.kt:263–367` and its constants; tap anchoring is a
native refinement of Android's center-reset double-tap.

UIScrollView still owns pinch and zoomed panning. The embedded scroll view declines its pan at
minimum zoom; ancestor scroll pans wait for the image pan/dismiss recognizers to fail, so an
unzoomed horizontal swipe belongs to the existing page TabView while a zoomed pan stays in the
image. Existing ancestor screen-edge pans receive failure priority, and dismiss admission rejects
both edge bands. No system gesture delegate is replaced and no global scroll enablement is changed.
Cancelled/short dismiss drags reset the transform. Reduce Motion disables zoom animation, drag
translation and snap-back animation. Close remains an independent native escape action.

## Verification actually run

`python3 iosapp/NativeViewerTests/run-mac-tests.py`

- Real Mac Swift 6.4.2, macOS SDK 26.5, Swift 5 language mode (matching the app).
- Three focused policy groups / eleven assertions execute the exact extracted production policy:
  dismiss admission excludes zoom/paging/edges/pinch; release threshold and zoom recheck; tap-centered
  zoom geometry. These are behavioral/algorithm tests, not appearance assertions.
- Exact production `NativeZoomImage` region typechecks against **compile-only UIKit and
  UIViewRepresentable stand-ins**, using real macOS SwiftUI for the environment property.
- Every run uses an isolated staging directory and prints the local and remote production SHA-256.
- Initial RED was missing-policy/missing-member compiler failures, not an executed behavioral RED.
- Source comparison against HEAD confirms all pre-zoom code unchanged except passing the existing
  dismiss action into `NativeZoomImage`: loader, decoder, original bytes, cancellation, cache,
  Wi-Fi/offline policy, Photos save and gallery remain unchanged.

This is **not** iOS compilation/linking, simulator testing or a claim that gestures passed on device.
UIKit stand-ins deliberately trap and never ship. Signature checking does not validate Apple's
recognizer arbitration, ancestor hierarchy, bounce behavior, rotation or interactive navigation.

## Required iOS acceptance

Test a single image and a multi-image gallery: off-center double-tap/reset; pinch and pan at all
edges without paging; horizontal paging at minimum zoom; vertical drag both ways; short/cancelled
drag; second finger joining a drag; system edge-back where the viewer is routed; Close; rotation;
Reduce Motion on/off; VoiceOver escape/Close. Include GIF and Wi-Fi-deferred/offline images to
confirm existing delivery behavior without changing those policies.

Generic image context menus, copy-original-image/collection actions, new gallery chrome and full
visual parity are not claimed by this gesture patch. Existing Photos save/share/browser buttons
remain usable; no unsupported transport method or second download path was fabricated.
