# Native image behavior tests

Run on macOS with `TMPDIR` set to a scratch directory:

```sh
sh iosapp/NativeImageTests/run-tests.sh
```

The runner compiles the **actual shipping** `Platform/NativeImage*.swift` files. Only the
UIKit image/view and Kotlin request boundary are synthetic (`Boundary.swift`); ImageIO,
CoreGraphics, cache scheduling, cancellation, state publication and byte handling are real.
There are no live requests, credentials, proxy/offline integration or device-frame claims.

## Security and lifetime contract

- Every independent owner first calls the unchanged `NativePlatform.shared.image` path.
  Swift has no URL-to-image cache lookup before Kotlin admits that access. Returned bytes
  are content-hashed off-main, then decoded work/final images can be reused.
- The same owner retains an already accepted presentation across disappearance/appearance,
  with no reset/redecode/request. Repeated pending appearances join its owned request.
  This is retained presentation, not authorization for another owner or a new byte access.
- Keys include process app identity, session and boundary epochs, boundary phase, generation,
  site/origin, Wi-Fi-only setting and decode size. Scope changes immediately purge reusable
  decoded entries and revoke old flights. View branches also check scope before drawing,
  sharing or saving. Per-access metered consent is still passed explicitly to Kotlin; it
  cannot be supplied by a decoded cache hit. Scope equality does not replace Kotlin admission.
- Original admitted `Data` stays on its presentation owner for Save and GIF decoding. The
  shared cache retains final decoded images only (64 entries / 48 MiB cost limit, LRU), and
  drops reuse on iOS memory pressure. Accepted owner presentation remains intact.
- At most two ImageIO decodes run at once in the installed singleton. Equal content/scope/size
  joins one flight while it has active waiters. Cancelling a waiter resumes it without waiting
  for synchronous ImageIO. Last-waiter cancellation cancels the worker and retires its keyed
  flight immediately, so fresh admitted requests can schedule a replacement. Scope changes
  also retire queued and running keyed flights. Retired workers still own their running slots
  until actual completion; identity-fenced finishes cannot remove a same-key replacement,
  publish revoked results or repopulate reusable cache.
- Static images use ImageIO target-size thumbnail creation with immediate caching on a worker.
  Inline default target is the display's maximum pixel extent; fixed-size callers may opt
  into `NativeRemoteImage(url:aspectFit:maxPixel:)`. Existing two-argument calls remain valid.
  The full-screen viewer keeps full resolution; multi-frame GIFs keep the existing animation
  budget/timing path. Source metadata supplies aspect ratio so thumbnail pixel rounding cannot
  alter row height.
- Reduce Motion replaces an animated UIImageView image with its first still frame and stops
  playback, including live setting changes; restoring motion restores the animated image.

This deliberately trades a synchronous cross-owner URL-cache presentation for preserving the
existing per-access Kotlin policy. It reduces repeated decode costs without introducing a new
network loader or making a Swift memory hit an admission bypass. Real iOS playback, memory,
scroll/frame-time, gallery gestures and authenticated/offline/network integration remain device
acceptance gates; the independent iPhoneOS SDK typecheck verifies the production UIKit branch.
