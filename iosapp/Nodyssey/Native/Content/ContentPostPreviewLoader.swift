import Foundation
import Combine
import NodysseyNativeCore

/// One context-menu session owns one transient Store. This never observes a feed,
/// starts a thread load, marks reading/history, or retains a paging handle.
@MainActor final class ContentPostPreviewLoader: ObservableObject {
    @Published private(set) var value: JSONValue = .null
    @Published private(set) var failure: NativeFailure?
    @Published private(set) var isLoading = false
    private let store = NativeStore()
    private var lease = ContentPostPreviewLease()
    private var cancelled = false
    private var started = false

    func load(_ app: NativeAppModel, owner: ContentPostPreviewOwner) async {
        guard !started, !cancelled, !Task.isCancelled, isCurrent(owner, app: app) else { return }
        started = true
        lease.begin(owner)
        isLoading = true
        // Reuse a complete cached body; only a missing opening post needs the
        // iOS-only ephemeral remote read. Never use thread.load/save here.
        await store.load(app, "thread.get", ["postId": .integer(owner.postID)])
        guard acceptReply(owner, app: app) else { return }
        guard validIdentity(store.value, owner: owner) else {
            rejectReply()
            return
        }
        if store.failure == nil && (store.value == .null || store.value["body"] == nil || store.value["body"] == .null) {
            await store.load(app, "thread.preview", ["postId": .integer(owner.postID)])
            guard acceptReply(owner, app: app) else { return }
            guard store.failure != nil || (validIdentity(store.value, owner: owner) &&
                  (store.value == .null || (store.value.nativeInt("firstLoadedPage") == 1 &&
                                            store.value.nativeInt("lastLoadedPage") == 1))) else {
                rejectReply()
                return
            }
        }
        value = store.value
        failure = store.failure
        isLoading = false
    }

    func cancel(_ owner: ContentPostPreviewOwner? = nil) {
        guard owner == nil || lease.current == nil || lease.current == owner else { return }
        cancelled = true // A delayed hosting .task cannot revive an ended menu.
        lease.cancel(owner)
        store.invalidate()
        value = .null
        failure = nil
        isLoading = false
    }

    private func acceptReply(_ owner: ContentPostPreviewOwner, app: NativeAppModel) -> Bool {
        guard !Task.isCancelled, !cancelled,
              lease.accepts(owner, postID: owner.postID, generation: app.generation,
                  identityEpoch: app.session.nativeString("identityEpoch"), site: app.site.nativeString("current")) else {
            cancel(owner)
            return false
        }
        return true
    }

    private func validIdentity(_ value: JSONValue, owner: ContentPostPreviewOwner) -> Bool {
        value == .null || value.nativeInt("postId") == owner.postID
    }

    private func rejectReply() {
        store.invalidate()
        value = .null
        failure = .init(code: "INVALID_DATA", message: "Thread identity or page does not match preview")
        isLoading = false
    }

    private func isCurrent(_ owner: ContentPostPreviewOwner, app: NativeAppModel) -> Bool {
        owner.matches(postID: owner.postID, generation: app.generation,
            identityEpoch: app.session.nativeString("identityEpoch"), site: app.site.nativeString("current"))
    }
}
