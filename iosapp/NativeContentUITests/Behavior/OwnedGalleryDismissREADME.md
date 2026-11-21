# Owned gallery dismissal regression

`run-owned-gallery-dismiss.py` prepares an isolated request; it never opens SSH.
Pass that JSON to the currently authorized serialized Mac wrapper. Example from
the repository root (use a **new** scratch request path):

```sh
python3 iosapp/NativeContentUITests/Behavior/run-owned-gallery-dismiss.py \
  --prepare-request "$TMPDIR/owned-gallery-dismiss/run.json"
# Then invoke the authorized Mac wrapper with that request.
```

The emitted command typechecks the uninstrumented production
`NativeOwnedNavigation`, `NativeRemoteImage` (including gallery, viewer and zoom),
real AppModel/Store/Core and exact ImageViewer factory case against iPhoneOS with
an iOS 16 deployment floor. It builds a disposable iOS simulator application and
creates/deletes only its own simulator. It does not archive, install tools, change
Xcode selection, use a live account/network or clear shared caches.

The seven behavioral cases check route/model **and mounted owner** consequences:

- Empty gallery Close returns to the same thread.
- Nonempty production viewer Close returns to the same thread.
- A short terminal drag keeps the route; a qualifying drag returns to the thread.
- A routed viewer in a sheet pops only its own child, preserving the sheet ID.
- A retained hidden action cannot close a newer route; identity-revoked actions
  cannot close a replacement, while a current replacement action works.
- The actual `NativeRemoteImage.fullScreenCover` keeps both Close and qualifying
  drag system-dismiss behavior, without touching the application path.
- Registered departure refusal preserves the route; later acceptance terminates
  exactly once via the existing model entry point.

This is **programmatic action/runtime evidence, not touch acceptance**. A
same-body extraction passes the shipping Close action to both the actual mounted
Button and a public representable that captures it. The zoom probe invokes the
actual installed production coordinator's `drag` with a public synthetic pan
subclass, replaying `.ended` and translation; it does not deliver recognizer touch
arbitration. Production viewer/zoom types are never substituted.

Boundaries: image I/O is a deterministic loaded raster; Kotlin transport traps;
unrelated destinations are fixture views. The UIKit diagnostic host supplies an
active scene environment. Empty URLs are rejected by the shipping media factory,
so only this no-network empty fixture relaxes its URL-count/index validation;
construction and action bodies remain shipping code. Nonempty routes use the
unaltered factory branch and the actual `ContentImageGallery` open callback.
No claim is made about live loading, full application linkage, genuine touch,
recognizer arbitration or the complete union's acceptance.

The request stages original and instrumented sources plus an SHA-256 manifest.
The wrapper records the remote input hashes and integer process exit status.
`0` means all seven cases passed; `42` means completed behavioral assertions
failed. Compilation, missing runtime/result and incomplete fixture failures are
not product RED; inspect the log rather than treating all nonzero exits alike.
