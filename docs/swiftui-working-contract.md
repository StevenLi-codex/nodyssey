# SwiftUI migration working contract

Scope: all existing iOS routes and capabilities become real SwiftUI/system views, preserving Kotlin repositories, storage, session/cookie boundaries and Android. Branch `feat/ios-swiftui-liquid-glass` starts at `ca98c21c47ddee7b3704417442d60e90bc828596`. No Compose view embedded as final UI; WebKit only for authentication/challenges or genuine web content, not generic native-screen fallback. Preserve authorship/license. Current user authorized full migration, NOT publishing forum content for smoke tests.

## Ownership and shared bridge

Kotlin owns repositories and stored state. Swift owns rendering and transient navigation/input. Do not duplicate database or logged-in data in a second persistent Swift store. NativeBridge is an iOS-only facade in `iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/native/`.

Public ABI (Kotlin Objective-C export):
```
class NativeRequest { fun cancel() }
object NativeBridge {
    fun request(operation: String, argumentsJson: String, completion: (String) -> Unit): NativeRequest
    fun observe(operation: String, argumentsJson: String, completion: (String) -> Unit): NativeRequest
}
```
Callbacks on Main. Every payload is an envelope: `{"ok":true,"data":...}` or `{"ok":false,"error":{"code":"...","message":"..."}}`. Errors sanitized, never raw cookies/tokens/passwords. Cancellation cancels work and releases observers, no late callbacks. Both one-shot requests and observations initialize through the existing process-singleton `NodysseyApp.ensureContainer()`. Reconcile session provenance before any cached data is exposed. Never auto-retry state-changing actions. Operations and argument names must be recorded in `docs/swiftui-bridge-contract.md` by backend owners as they implement real repository calls; do not invent endpoints or fake success.

Internal ABI: shared `NativeContext(val graph: IosAppContainer, val scope: CoroutineScope)`. Domain functions `internal suspend fun NativeContext.contentRequest(operation: String, args: JsonObject): JsonElement?` and `accountRequest`, `settingsRequest`, with null meaning unrecognized operation. Corresponding `contentObserve`, `accountObserve`, `settingsObserve` can return `Flow<JsonElement>?`. Core helper names prefixed `native...` to avoid collisions. `NativeBridge` dispatches all three. Each domain owns its own mappings and contract markdown section/file; no broad modification of shared models merely to serialize them.

JSON DTO field names follow Kotlin public model names. For enums use enum `.name`. IDs JSON integer (Swift Int64); preserve numeric identity. RichNode uses existing kotlinx.serialization tagged JSON discriminator, not new HTML scraping/rendering. Arrays remain arrays; paged output `{items: [...], page: ..., totalPages: ...}` where backing API provides those facts; no invented total. Dates use existing timestamps/text fields. Mutation responses must contain confirmed results or Unit acknowledgement, not made-up data.

## Swift ownership

Foundation-only Swift core lives under `iosapp/NativeCore/` as local Swift Package, with JSONValue, NativeTransport protocol, request/error/cancellation/state tests and navigation route/domain models. Platform adapter plus screens live `iosapp/Nodyssey/Native/`. `NativeClient` facade in native UI exposes `func request(_ operation: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue` and observations via AsyncThrowingStream; adapter forwards to exported `NativeBridge.shared`. NativeCore JSONValue supports `.object`, `.array`, `.string`, `.number`, `.bool`, `.null` and typed access without silently defaulting required identities. Authoritative decoder/errors in core, never every screen reinventing parsing.

Prefer built-in NavigationStack, TabView, List, Form, searchable, sheet, Menu, alerts/confirmationDialog. Use system Liquid Glass on iOS 26+, normal system materials on older supported versions. Do not apply glass to long-form text/card content. Use Dynamic Type, system colors, accessibility reduce motion/transparency. All controls need actual handling, disabled/busy/error states; no TODO buttons or no-op rows. Main screens and helpers should consume `NativeClient` injected as environment object.

## Acceptance

Write failing behavior tests before new production behavior, then execute green tests. Tests must cover cancellation, stale responses, logout invalidation, account isolation, draft preservation, paging identity and mutation deduplication where relevant. Fixtures synthetic or repository checked-in fixtures only; never fabricated live results. Native UI typechecking, real Xcode build, simulator or device execution are distinct from Foundation test success. No user-facing completion claim until all named routes and actions are accounted for and verified. Maintain explicit remaining gaps instead of web fallbacks or decorative screens. No push/release until parent integrates and verifies scope.
