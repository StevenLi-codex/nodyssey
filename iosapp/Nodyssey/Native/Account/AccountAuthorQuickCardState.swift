import Foundation
import Combine
import NodysseyNativeCore

enum AccountAuthorQuickCardNavigation: Equatable {
    case signIn
    case route(String, [String: JSONValue])
}

struct AccountAuthorQuickCardSnapshot {
    var profile: JSONValue?
    var note: String?
    var notesAvailable = false
    var isLoading = false
    var failure: NativeFailure?
}

/// Transient presentation only. Uses the same request state as NativeStore; the
/// shared repositories remain the only profile/notes source and persistence owner.
@MainActor final class AccountAuthorQuickCardState: ObservableObject {
    @Published private var content = AccountAuthorQuickCardSnapshot()
    private let request = NativeRequestState()
    private var uid: Int64?
    private var isCurrent: (() -> Bool)?
    private var lifecycle = UUID()

    func snapshot(for uid: Int64) -> AccountAuthorQuickCardSnapshot {
        guard self.uid == uid, isCurrent?() == true else { return AccountAuthorQuickCardSnapshot() }
        return content
    }

    func load(uid: Int64, using transport: any NativeTransport, currentGeneration: @escaping () -> Int) async {
        invalidate()
        self.uid = uid
        let generation = currentGeneration()
        isCurrent = { currentGeneration() == generation }
        let token = lifecycle
        defer {
            if token == lifecycle, Task.isCancelled || isCurrent?() != true { invalidate() }
        }
        guard uid > 0 else {
            content.failure = NativeFailure(code: "INVALID_ARGUMENT", message: "Invalid author")
            return
        }
        content.isLoading = true
        await request.load(using: transport, operation: "profile.user", arguments: ["uid": .integer(uid)])
        guard token == lifecycle, isCurrent?() == true, !Task.isCancelled else { return }
        if let failure = request.failure {
            content.isLoading = false; content.failure = failure
            return
        }
        guard let profile = request.value, profile["uid"]?.int == uid else {
            content.isLoading = false
            content.failure = NativeFailure(code: "INVALID_RESPONSE", message: "Profile unavailable")
            return
        }
        content.profile = profile
        request.invalidate()
        await request.load(using: transport, operation: "notes.get")
        guard token == lifecycle, isCurrent?() == true, !Task.isCancelled else { return }
        content.isLoading = false
        if request.failure == nil, let rows = request.value?.array {
            content.notesAvailable = true
            content.note = rows.first { $0["uid"]?.int == uid }?["note"]?.string
        }
        // Never keep the complete local notes listing in the presentation state.
        request.invalidate()
    }

    func navigation(for uid: Int64, message: Bool, signedIn: Bool) -> AccountAuthorQuickCardNavigation? {
        guard uid > 0, let profile = snapshot(for: uid).profile, profile["uid"]?.int == uid else { return nil }
        if !message { return .route("UserSpace", ["uid": .integer(uid)]) }
        guard let name = profile["name"]?.string, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard signedIn else { return .signIn }
        return .route("MessageThread", ["uid": .integer(uid), "userName": .string(name)])
    }

    func invalidate() {
        lifecycle = UUID(); isCurrent = nil; uid = nil
        request.invalidate(); content = AccountAuthorQuickCardSnapshot()
    }
}
