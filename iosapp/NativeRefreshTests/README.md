# Shared native refresh

## Call-site contract

```swift
.nativeRefreshable(
    generation: app.generation,
    failure: { store.failure != nil },
    completion: { /* optional: await observer completion, return success */ true }
) {
    await existingRefresh()
}
```

`failure` is evaluated after the real action and completion await. Existing error UI and cached data remain caller-owned. A throwing operation whose error is swallowed must expose that failure here. An early-return/no-op action should supply a false completion result when it cannot establish success.

For revision/Paging commands, capture a store revision **before dispatch** and await the matching observed NotLoading/Error terminal state inside the action (or use a caller-owned captured token in completion). Merely awaiting a command acknowledgement is not completion. A completion closure that captures its baseline only after the action can miss a fast observer response. The shared component deliberately does not invent transport/Paging policy.

`generation` resets presentation and cancels the active task. The original page/store must continue fencing its own data publication; presentation fencing cannot undo an assignment made inside an old closure. Departure and cancellation clear the visual state, while a cancellation-ignoring old operation is drained/coalesced rather than admitting a duplicate request.

## Ownership

SwiftUI `.refreshable` remains the only action/gesture owner. The UIKit bridge:

- resolves only a scroll ancestor or one unambiguous scroll owner inside the local view-controller root;
- retains the original UIRefreshControl, action targets, pan recognizer, delegate and insets;
- observes public contentOffset/refreshControl/isRefreshing and adds only a pan target;
- mounts a noninteractive SwiftUI ring in the original refresh control, suppressing its spinner with clear tint;
- restores tint, removes hosting-controller containment/observers/targets on detach;
- calls public endRefreshing only when its active presentation collapses or is dismantled;
- adds no row, safe-area inset, content overlay, poller or refresh-start delay.

The hosting view copies the page's SwiftUI environment for custom tint and color scheme. Motion is a separate explicit value: the modifier reads the real system Reduce Motion value and the root's existing `nativeCardMotionDisabled` (e-ink) preference, combines them, and passes that policy through the UIKit anchor into the independent ring host. Either preference disables rotation, phase spring and scale while retaining progress/check feedback; live changes stop/restart the loop on the same ring. Successful completion holds the check only after the request has finished, then returns to the system-owned collapse.

## Official API rationale

Apple's `View.refreshable(action:)` documentation exposes the async refresh environment action and states that the native indicator remains visible for the async handler duration. It has no pull-progress/custom-indicator parameter. `UIRefreshControl` documents target/action integration with UIScrollView, and `UIScrollView.refreshControl` publicly exposes that system-owned control. This is the smallest bridge; remove it when SwiftUI provides those missing slots.

- https://developer.apple.com/documentation/swiftui/view/refreshable(action:)
- https://developer.apple.com/documentation/uikit/uirefreshcontrol
- https://developer.apple.com/documentation/uikit/uiscrollview/refreshcontrol

## Verification

Run `python iosapp/NativeRefreshTests/run-mac-tests.py` from the repository. It compiles actual shipping Foundation state/coordinator with Swift 6 warnings-as-errors and executes continuation-controlled behavior tests. A topology harness executes the exact extracted shipping owner-resolution methods against explicitly synthetic view trees; it does not emulate UIKit. The runner then typechecks both complete shipping source files against the real **iPhoneOS 26.5 SDK**, targeting `arm64-apple-ios16.0`, and separately against macOS SwiftUI. It uses a per-run staging directory, local `DEVELOPER_DIR` (no global Xcode selection), and writes exact source SHA-256, SDK output, invocation and log to the printed scratch artifact path.

The iOS-only bridge is gated by `os(iOS) && canImport(UIKit)`; a macOS contract test with a synthetic UIKit module must not accidentally activate it. Keep both NativeRefresh source files and `NativePressStyle.swift` (the existing motion environment key) in explicit caller/compiler input lists. The runner also executes the production motion policy truth table; appearance/numeric probes remain disposable.

This establishes real iOS **compilation**, not simulator/device execution. UIRefreshControl mounting, dynamic UIKit tint, haptics, zero-height-before-pull sampling, native inset collapse and rootView-update animation retention remain runtime integration gates. Apple's public `isRefreshing` property is not documented as KVO-compliant; successful compilation does not prove its notifications. Progress/feedback uses the control's measured height, **not** a documented system activation threshold. Normal finish currently also calls `endRefreshing()` as presentation collapses; cancellation needs that cleanup, but interaction with SwiftUI's own async completion/inset animation remains unmeasured. The original system action targets, pan/delegate and inset assignments are not replaced.
