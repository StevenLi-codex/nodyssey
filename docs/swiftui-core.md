# NativeCore integration API

Foundation-only local Swift package `iosapp/NativeCore`, product/module `NodysseyNativeCore`; iOS 16 (existing deployment target) and macOS 13. No repository/storage duplication.

## Implemented integration API

- `JSONValue`: recursive Codable/Sendable/Equatable enum `.object([String: JSONValue])`, `.array([JSONValue])`, `.string(String)`, `.integer(Int64)`, `.number(Double)`, `.bool(Bool)`, `.null`. Integer-first decoding preserves IDs, including Int64.max. Use `.integer` for IDs, not `.number`. Optional `object`, `array`, `string`, `int`, `bool`; `value["field"]` returns optional; `requireInt("id")` throws rather than inventing an ID.
- `NativeFailure: Error, Codable, Equatable, Sendable` with public String `code`, `message`; `NativeEnvelope.decode(_ json: String) throws -> JSONValue` enforces `ok` and required data/error shape.
- `NativeTransport: Sendable`: `func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue`; `func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error>`. Implementations decode envelopes with `NativeEnvelope`. Cancellation must cancel the bridge handle and release observer; no automatic mutation retry.
- `CallbackNativeTransport(request:observe:)` supplies callback adaptation. Both start closures are `@MainActor @Sendable (String, String, @escaping @Sendable (String) -> Void) -> NativeCancellation`. The UI adapter supplies closures calling the exported Kotlin ABI; no Kotlin dependency in this package. Start executes on MainActor; `NativeCancellation` is idempotent and may run from any executor. Its platform closure must dispatch cancellation to MainActor if the Kotlin handle requires that. Cancellation resumes suspended requests even when the bridge never calls back, handles synchronous completion before handle installation, and releases observations on stream termination.
- `@MainActor NativeRequestState`: transient load/observation state, generation fencing, explicit invalidation on logout/account switch; async `load(using:operation:arguments:)`, async `observe(using:operation:arguments:)`, `cancel()`, `invalidate()`; public read-only `value`, `failure`, `isLoading`. State is not ObservableObject. Its optional `onChange: (@MainActor () -> Void)?` lets a UI wrapper publish state changes, including each observed snapshot. Capture wrapper owners weakly. Use the owning SwiftUI `.task` to await load/observe so disappearance cancels the child operation.
- `@MainActor NativeMutationState`: shared publish/send single-flight gate; editable String `draft`, public read-only `isSubmitting`, `failure`; `submit(using:operation:arguments:draftKey:) async throws -> JSONValue`; rejects overlaps, preserves failed drafts, clears successful submitted draft only if not edited meanwhile. `invalidate()` cancels and fences old-account completion, clears sensitive draft.
- `NativeRoute: Hashable, Sendable`: `.post(id: Int64, page: Int)`, `.space(uid: Int64)`, `.member(name: String)`, `.notifications(group: NativeNotificationGroup?)`, `.messageThread(uid: Int64)`. `NativeNotificationGroup`: `.mentions`, `.messages`. `NativeSite`: `.nodeSeek`, `.deepFlood`. `NativeDeepLink.parse(_ text: String, site: NativeSite = .nodeSeek) -> NativeRoute?` recognizes canonical post/space/member/notification/jump URLs on the active site's exact hosts only. This route vocabulary mirrors shared `NodeSeekSite.InternalRoute`; other native screen destinations remain UI-owned.

## Verification boundary

All core transport tests are **synthetic transport** tests. macOS `swift test` is not an iOS build, Kotlin bridge linkage test, simulator run, or UI validation.

### Executed results

On the supplied Mac (Apple Swift 6.4.2, arm64 macOS 27.3), staged only under `/Users/steven/.cache/hermes-build/nodyssey-native-core`:

```sh
NATIVE_CORE_TESTING_FROM_SOURCE=1 swift test --disable-xctest
# ✔ Test run with 20 tests passed after 0.006 seconds.

swift build --build-system native --target NodysseyNativeCore \
  -Xswiftc -swift-version -Xswiftc 6 -Xswiftc -warnings-as-errors
# Build of target: 'NodysseyNativeCore' complete! (0.66s)
```

The CLT installation lacks XCTest and bundled Testing. The opt-in builds pinned upstream Swift Testing 6.0.3 from source; **no production dependency is added**. Full Xcode/Swift toolchains with bundled Testing do not need this opt-in. Test-first sequence, actual runtime RED→GREEN regressions, framework prerequisites and retained raw logs are in [`iosapp/NativeCore/Verification/README.md`](../iosapp/NativeCore/Verification/README.md). Initial clean default-engine build emitted CLT search-path linker warnings; final incremental test run was warning-free. The strict Swift 6 library build emitted only SwiftPM's deprecated-engine warning.

### Integration obligations / limits

- Invalidate **every** account/site-scoped state before rendering a new account/site; the core deliberately does not duplicate repository/session ownership. Invalidation clears sensitive snapshots before notifying observers and erases transient mutation drafts.
- Use one `NativeMutationState` per composer for all publish/send entry points. The gate prevents overlapping local calls, not server-side exactly-once delivery; cancellation cannot undo a server write. Never auto-retry a mutation after ambiguous cancellation/failure.
- Use `.integer(id)` for every ID argument. `.number(Double(id))` loses identity above 2^53 before the transport can validate it. `int` does not coerce a string, Boolean or `.number` into a required identity.
- Deep links are parsed against the **active site**, not a union of both host sets. Full encoded path matching rejects query/path-substring tricks, encoded authorities, user-info, nonstandard ports, malformed/overflowed IDs/pages and encoded path separators. Unknown URLs return nil; this is not permission to open an authenticated WebView.
- Pure JSON array identity and page route numbers are covered; repository paging/deduplication, Kotlin facade ABI linkage, real session reconciliation, and native screen integration remain parent-owned verification gates. No Android/shared source or working-contract file was changed.
