import Foundation
import Combine
import NodysseyNativeCore

struct NativePrivateResetConfirmation: Identifiable, Equatable {
    let id = UUID()
    let identityEpoch: String
    let generation: Int
}

@MainActor final class NativeAppModel: ObservableObject {
    let transport: any NativeTransport
    @Published var session: JSONValue = .null {
        didSet {
            // Epoch is opaque and process-local. Reload/clearance revisions do not
            // own navigation or editor lifetime; equal signed-in flags aren't identity.
            guard let oldEpoch = oldValue.nativeString("identityEpoch"), !oldEpoch.isEmpty,
                  let epoch = session.nativeString("identityEpoch"), !epoch.isEmpty,
                  oldEpoch == epoch,
                  oldValue.nativeBool("isSignedIn") == session.nativeBool("isSignedIn") else {
                // The browser's cookie mutation also rotates the session DTO epoch.
                // Revoke private work, but don't tear down its public presenter on
                // an epoch-only emission (either collector may arrive first).
                let epochOnly = validEpoch(oldValue) != nil && validEpoch(session) != nil &&
                    oldValue.nativeBool("isSignedIn") != nil &&
                    oldValue.nativeBool("isSignedIn") == session.nativeBool("isSignedIn") &&
                    session.nativeInt("generation") != nil &&
                    oldValue.nativeInt("generation") == session.nativeInt("generation")
                invalidateSession(preservingAuthentication: epochOnly)
                return
            }
        }
    }
    private final class WeakNativeStore {
        weak var value: NativeStore?
        init(_ value: NativeStore) { self.value = value }
    }
    @Published var settings: JSONValue = .null
    @Published var generation: Int = 0
    @Published var selectedTab: NativeTab = .home
    // An ephemeral UI command, not feed/paging state. No replay on tab return.
    let homeScrollToTop = PassthroughSubject<Void, Never>()
    @Published private(set) var homePath: [NativeDestination] = [] { didSet { navigationRevision += 1 } }
    @Published private(set) var notificationsPath: [NativeDestination] = [] { didSet { navigationRevision += 1 } }
    @Published private(set) var profilePath: [NativeDestination] = [] { didSet { navigationRevision += 1 } }
    @Published private(set) var sheet: NativeDestination? { didSet { navigationRevision += 1 } }
    @Published private(set) var sheetPath: [NativeDestination] = [] { didSet { navigationRevision += 1 } }
    private var navigationRevision = 0
    private struct Departure {
        let token: UUID
        let prepare: @MainActor () async -> Bool
        let validate: @MainActor () -> Bool
        let terminate: @MainActor () -> Void
        let revoke: @MainActor () -> Void
    }
    private var departures: [UUID: Departure] = [:]
    @Published private(set) var departureRunning = false
    @Published private(set) var site: JSONValue = .null
    @Published private(set) var isReady = false
    @Published var lifecycleFailure: NativeFailure?
    @Published var linkFailure: NativeFailure?
    @Published private(set) var privateBoundary: JSONValue = .null {
        didSet {
            // Eligibility can be revoked without changing the displayed epoch.
            // Never resurrect a dialog after an active transition drains.
            if !canConfirmPrivateReset { privateResetConfirmation = nil }
            if oldValue != .null,
               oldValue.nativeString("identityEpoch") != privateBoundary.nativeString("identityEpoch") ||
               (oldValue.nativeString("phase") == "READY" && privateBoundary.nativeString("phase") != "READY") {
                let phase = privateBoundary.nativeString("phase")
                let previousPhase = oldValue.nativeString("phase")
                // Mutation epochs revoke every private owner, including stale
                // editors, but authentication is the producer of this transition.
                // Keep only a public auth root; UNKNOWN/malformed recovery still
                // tears it down, as do signed-in changes in the session collector.
                invalidateSession(preservingAuthentication:
                    (phase == "TRANSITIONING" && privateBoundary.nativeBool("recoveryEligible") == false) ||
                    (previousPhase == "TRANSITIONING" && oldValue.nativeBool("recoveryEligible") == false && phase == "READY"))
            }
        }
    }
    @Published private(set) var privateBoundaryFailure: NativeFailure?
    @Published private(set) var privateResetConfirmation: NativePrivateResetConfirmation?
    @Published private(set) var privateResetRunning = false
    private var boundaryRevision = 0
    private var activeStart: Task<Void, Never>?
    private var sessionReady = false
    private var settingsReady = false
    private var pendingLinks: [String] = []
    private var requests: [UUID: (changesSession: Bool, task: Task<JSONValue, Error>)] = [:]
    private var foregroundTask: Task<Void, Never>?
    private var foregroundRunning = false
    private var authenticationPresentation: (token: UUID, destinationID: UUID)?
    var ownsAuthenticationPresentation: Bool {
        guard let authenticationPresentation else { return false }
        return sheet?.id == authenticationPresentation.destinationID
    }

    /// Register before WebKit starts its intentional cookie mutation, never for
    /// ordinary/account-management browsers. The token cannot retain private routes.
    func beginAuthenticationPresentation() -> UUID? {
        guard let sheet, sheet.route == "SignIn" || (sheet.route == "Web" &&
            ["SIGN_IN", "ONE_TAP_SIGN_IN", "CHALLENGE"].contains(sheet.arguments["goal"]?.string ?? "")) else { return nil }
        let token = UUID()
        authenticationPresentation = (token, sheet.id)
        return token
    }

    func endAuthenticationPresentation(_ token: UUID?) {
        if let token, authenticationPresentation?.token == token { authenticationPresentation = nil }
    }

    var activeSite: NativeSite? {
        site.nativeString("current").flatMap(NativeSite.init(rawValue:))
    }
    var siteOrigin: String? {
        site.nativeArray("sites").first { $0.nativeString("id") == site.nativeString("current") }?.nativeString("origin")
    }
    var siteName: String? {
        site.nativeArray("sites").first { $0.nativeString("id") == site.nativeString("current") }?.nativeString("displayName")
    }

    /// Root .task owns this lifetime. Never key this task by session generation.
    func start() async {
        // SwiftUI may start a replacement .task before the cancelled one finishes.
        // Await teardown so its collectors/defer cannot overwrite the new owner.
        let previous = activeStart
        previous?.cancel()
        await previous?.value
        guard !Task.isCancelled else { return }
        let task = Task { await runStart() }
        activeStart = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func runStart() async {
        isReady = false
        sessionReady = false
        settingsReady = false
        lifecycleFailure = nil
        defer {
            foregroundTask?.cancel()
            foregroundTask = nil
            if Task.isCancelled {
                isReady = false
                session = .null
                settings = .null
            }
        }
        do {
            let snapshot = try await transport.request("site.get", [:])
            try Task.checkCancellation()
            try applySite(snapshot)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.watchSession() }
                group.addTask { try await self.watchSettings() }
                group.addTask { await self.watchPrivateBoundary() }
                do {
                    while let _ = try await group.next() {}
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            isReady = false
            session = .null
            settings = .null
            lifecycleFailure = nativeSafeFailure(error)
        }
    }

    private func watchSession() async throws {
        for try await snapshot in transport.observe("session.state", [:]) {
            try Task.checkCancellation()
            if snapshot == .null {
                session = .null
                sessionReady = true
                becameReady()
                continue
            }
            guard snapshot.nativeInt("generation") != nil, snapshot.nativeBool("isSignedIn") != nil,
                  validEpoch(snapshot) != nil else {
                session = .null
                sessionReady = true
                privateBoundaryFailure = NativeFailure(code: "INVALID_DATA", message: "Invalid session response")
                becameReady()
                continue
            }
            session = snapshot
            sessionReady = true
            becameReady()
        }
        try Task.checkCancellation()
        throw NativeFailure(code: "OBSERVATION_ENDED", message: "Session observation ended")
    }

    private func watchSettings() async throws {
        for try await snapshot in transport.observe("settings.observe", [:]) {
            try Task.checkCancellation()
            settings = snapshot
            settingsReady = snapshot.object != nil
            if !settingsReady { isReady = false }
            becameReady()
        }
        try Task.checkCancellation()
        throw NativeFailure(code: "OBSERVATION_ENDED", message: "Settings observation ended")
    }

    private func watchPrivateBoundary() async {
        do {
            for try await snapshot in transport.observe("session.privateBoundary", [:]) {
                try Task.checkCancellation()
                applyPrivateBoundary(snapshot)
            }
            try Task.checkCancellation()
            throw NativeFailure(code: "OBSERVATION_ENDED", message: "Boundary observation ended")
        } catch {
            privateBoundary = .null
            if !Task.isCancelled { privateBoundaryFailure = nativeSafeFailure(error) }
        }
    }

    private func validEpoch(_ snapshot: JSONValue) -> String? {
        guard let epoch = snapshot.nativeString("identityEpoch"), !epoch.isEmpty else { return nil }
        return epoch // No parsing, ordering, hashing, persistence or secret-derived fallback.
    }

    var isPrivateReady: Bool {
        validEpoch(session) != nil && validEpoch(session) == validEpoch(privateBoundary) &&
        session.nativeInt("generation") != nil && session.nativeBool("isSignedIn") != nil &&
        privateBoundary.nativeString("phase") == "READY" && privateBoundary.nativeBool("requiresConfirmation") == false
    }

    var canConfirmPrivateReset: Bool {
        !privateResetRunning && validEpoch(privateBoundary) != nil &&
        ["UNKNOWN", "TRANSITIONING"].contains(privateBoundary.nativeString("phase") ?? "") &&
        privateBoundary.nativeBool("requiresConfirmation") == true && privateBoundary.nativeBool("recoveryEligible") == true
    }

    func canDisplay(_ destination: NativeDestination) -> Bool {
        if isPrivateReady { return true }
        // Deny unknown/private factories, including caches and editors. Public
        // preferences and authentication must remain reachable during bootstrap.
        if ["Settings", "ThemeSettings", "DynamicColor", "NotificationSettings", "ProxySettings",
            "DohSettings", "NetworkCheck", "AboutApp", "Privacy", "Changelog", "Help",
            "OpenSourceLicenses", "TitleKeywords", "SignIn"].contains(destination.route) { return true }
        return destination.route == "Web" && ["EXTERNAL", "SIGN_IN", "ONE_TAP_SIGN_IN", "CHALLENGE"]
            .contains(destination.arguments["goal"]?.string ?? "")
    }

    private func applyPrivateBoundary(_ snapshot: JSONValue) {
        boundaryRevision += 1
        guard validEpoch(snapshot) != nil,
              let phase = snapshot.nativeString("phase"), ["UNKNOWN", "TRANSITIONING", "READY"].contains(phase),
              let confirmation = snapshot.nativeBool("requiresConfirmation"),
              let recoveryEligible = snapshot.nativeBool("recoveryEligible"),
              phase != "READY" || (!confirmation && !recoveryEligible),
              !recoveryEligible || confirmation else {
            privateBoundary = .null
            privateBoundaryFailure = NativeFailure(code: "INVALID_DATA", message: "Invalid boundary response")
            return
        }
        privateBoundary = snapshot
        privateBoundaryFailure = nil
    }

    func refreshPrivateBoundary() async {
        let revision = boundaryRevision
        do {
            let value = try await request("session.privateBoundary")
            guard revision == boundaryRevision else { return } // Observation wins over an older readback.
            applyPrivateBoundary(value)
        } catch {
            guard revision == boundaryRevision else { return }
            privateBoundary = .null
            if !Task.isCancelled { privateBoundaryFailure = nativeSafeFailure(error) }
        }
    }

    func beginPrivateResetConfirmation() {
        guard canConfirmPrivateReset, let epoch = validEpoch(privateBoundary) else { return }
        privateResetConfirmation = NativePrivateResetConfirmation(identityEpoch: epoch, generation: generation)
    }

    func cancelPrivateResetConfirmation() { privateResetConfirmation = nil }

    /// Only the destructive dialog action calls this; opening/retrying recovery never confirms.
    func confirmPrivateReset(_ confirmation: NativePrivateResetConfirmation) async {
        guard !Task.isCancelled, privateResetConfirmation == confirmation, canConfirmPrivateReset,
              confirmation.identityEpoch == validEpoch(privateBoundary), confirmation.generation == generation else { return }
        privateResetConfirmation = nil // Single-use even when the backend refuses or transport fails.
        privateResetRunning = true
        privateBoundaryFailure = nil
        defer { privateResetRunning = false }
        do {
            _ = try await performRequest("session.resetPrivateStores", ["confirmed": .bool(true), "identityEpoch": .string(confirmation.identityEpoch)])
            await refreshPrivateBoundary() // Never adopt a session or infer READY from reset success.
        } catch {
            if !Task.isCancelled { privateBoundaryFailure = nativeSafeFailure(error) }
        }
    }

    private func becameReady() {
        // Public preferences/auth must not wait for private-store provenance.
        guard sessionReady, settingsReady, activeSite != nil else { return }
        guard !isReady else { return }
        isReady = true
        let links = pendingLinks
        pendingLinks = []
        for link in links { openLink(link) }
        foregroundTask = Task { await foreground() }
    }

    func foreground() async {
        guard isReady, !foregroundRunning else { return }
        foregroundRunning = true
        defer { foregroundRunning = false }
        do {
            _ = try await request("app.foreground")
            lifecycleFailure = nil
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            lifecycleFailure = nativeSafeFailure(error)
        }
    }

    func applySite(_ snapshot: JSONValue) throws {
        guard let raw = snapshot.nativeString("current"), NativeSite(rawValue: raw) != nil else {
            throw NativeFailure(code: "INVALID_DATA", message: "Invalid active site")
        }
        if let previous = site.nativeString("current"), previous != raw {
            privateBoundary = .null
            session = .null
        }
        site = snapshot // selected is NEXT launch, never the active namespace.
    }

    func request(_ operation: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard operation != "session.resetPrivateStores" else {
            throw NativeFailure(code: "CONFIRMATION_REQUIRED", message: "Explicit confirmation required")
        }
        // Native callers, like WebKit, can trigger a boundary epoch before their
        // first response. The form owner holds its longer OTP/retry lease; cover
        // direct native requests as well without replacing an existing browser lease.
        let nativeAuthentication = ["session.signIn", "session.verifyTwoFactor"].contains(operation)
        let presentation = nativeAuthentication && !ownsAuthenticationPresentation ? beginAuthenticationPresentation() : nil
        defer { endAuthenticationPresentation(presentation) }
        return try await performRequest(operation, arguments)
    }

    private func performRequest(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        try Task.checkCancellation()
        let capturedGeneration = generation
        let capturedBoundaryRevision = boundaryRevision
        let id = UUID()
        let changesSession = ["session.sync", "session.signIn", "session.verifyTwoFactor", "session.signOut"].contains(operation)
        let transport = self.transport
        let task = Task { try await transport.request(operation, arguments) }
        requests[id] = (changesSession, task)
        defer {
            requests[id] = nil
            // Even a failed/cancelled write may have reached the server. Keep
            // rows, but never let an appearance TTL hide its authoritative read.
            if capturedGeneration == generation {
                for store in stores { store.value?.invalidateFreshness(after: operation) }
                for owner in retainedOwners where owner.value != nil { owner.mutation?(operation) }
            }
        }
        let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        if !changesSession, capturedGeneration != generation {
            throw NativeFailure(code: "SESSION_CHANGED", message: "Session changed")
        }
        try Task.checkCancellation()
        let value = try result.get()
        if changesSession {
            let candidate = value["session"] ?? value
            if let incoming = candidate.nativeInt("generation"), candidate.nativeBool("isSignedIn") != nil {
                if let current = session.nativeInt("generation"), incoming < current {
                    throw NativeFailure(code: "SIGN_IN_SUPERSEDED", message: "Authentication was superseded")
                }
                guard validEpoch(candidate) != nil else {
                    session = .null
                    throw NativeFailure(code: "INVALID_DATA", message: "Invalid session response")
                }
                if capturedGeneration != generation, validEpoch(candidate) != validEpoch(session) {
                    throw NativeFailure(code: "SIGN_IN_SUPERSEDED", message: "Authentication was superseded")
                }
                session = candidate
            } else if !["TWO_FACTOR_REQUIRED", "REFUSED"].contains(value.nativeString("status") ?? "") {
                session = .null
                throw NativeFailure(code: "INVALID_DATA", message: "Invalid session response")
            }
        }
        if ["session.signIn", "session.verifyTwoFactor"].contains(operation), value.nativeString("status") == "SIGNED" {
            // Authentication succeeded independently of local-data admission. Never
            // convert a malformed/missing privacy result into a password failure.
            // A collector that advanced while this call waited remains authoritative.
            if capturedBoundaryRevision == boundaryRevision {
                let boundary = value["privateBoundary"] ?? .null
                let status = value.nativeString("privateDataStatus")
                let matches = (status == "READY" && boundary.nativeString("phase") == "READY" &&
                    boundary.nativeBool("requiresConfirmation") == false) ||
                    (status == "CONFIRMATION_REQUIRED" && boundary.nativeBool("requiresConfirmation") == true)
                applyPrivateBoundary(matches ? boundary : .null)
            }
        }
        if operation == "site.get" || operation == "site.select" { try applySite(value) }
        return value
    }

    func openLink(_ url: String) {
        guard NativeLinkRouting.isSafeWebURL(url) else {
            linkFailure = NativeFailure(code: "INVALID_LINK", message: "This address cannot be opened")
            return
        }
        guard isReady, let activeSite else {
            pendingLinks.append(url)
            return
        }
        linkFailure = nil
        if case .member(let name) = NativeDeepLink.parse(url, site: activeSite) {
            Task {
                do {
                    let result = try await request("search.resolveMember", ["name": .string(name)])
                    guard let uid = result.nativeInt("uid"), uid > 0 else {
                        throw NativeFailure(code: "NOT_FOUND", message: "Member not found")
                    }
                    open("UserSpace", ["uid": .integer(uid)])
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError),
                          (error as? NativeFailure)?.code != "SESSION_CHANGED" else { return }
                    linkFailure = nativeSafeFailure(error)
                }
            }
            return
        }
        let destination = NativeLinkRouting.destination(url, site: activeSite)
        open(destination.route, destination.arguments)
    }

    init(transport: any NativeTransport) { self.transport = transport }
    var isSignedIn: Bool { session.nativeBool("isSignedIn") == true }

    func open(_ route: String, _ arguments: [String: JSONValue] = [:]) {
        let destination = NativeDestination(route, arguments)
        if route == "SignIn" || (route == "Web" && arguments["goal"]?.string == "CHALLENGE") {
            if !sheetDestinations.isEmpty {
                Task { await replaceSheet(destination) }
            } else { sheet = destination }
            return
        }
        if sheet != nil { sheetPath.append(destination); return }
        switch selectedTab {
        case .home: homePath.append(destination)
        case .notifications: notificationsPath.append(destination)
        case .profile: profilePath.append(destination)
        }
    }
    func showSignIn() { open("SignIn") }
    func resetNavigation() {
        if allDestinations.contains(where: { requiresDeparture($0) }) {
            Task { await resetNavigationAwaitingDeparture() }
        } else { clearNavigation() }
    }
    private func clearNavigation() {
        homePath = []; notificationsPath = []; profilePath = []; sheetPath = []; sheet = nil
    }

    private var sheetDestinations: [NativeDestination] { (sheet.map { [$0] } ?? []) + sheetPath }
    var sheetRequiresDeparture: Bool { sheetDestinations.contains(where: { requiresDeparture($0) }) }
    private var allDestinations: [NativeDestination] { homePath + notificationsPath + profilePath + sheetDestinations }
    private func requiresDeparture(_ destination: NativeDestination) -> Bool {
        departures[destination.id] != nil || ["PostComposer", "MessageThread"].contains(destination.route)
    }

    /// Keep ownership across temporary pushes/tab changes. Unregister only the
    /// matching terminal owner; a late old view must not remove its replacement.
    @discardableResult
    func registerDismissal(destinationID: UUID, close: @escaping @MainActor () async -> Bool,
                           revoke: @escaping @MainActor () -> Void,
                           terminate: @escaping @MainActor () -> Void = {},
                           validate: @escaping @MainActor () -> Bool = { true }) -> UUID {
        let token = UUID()
        departures.removeValue(forKey: destinationID)?.revoke()
        guard allDestinations.contains(where: { $0.id == destinationID }) else { revoke(); return token }
        departures[destinationID] = Departure(token: token, prepare: close, validate: validate, terminate: terminate, revoke: revoke)
        return token
    }

    func unregisterDismissal(destinationID: UUID, token: UUID) {
        if departures[destinationID]?.token == token { departures[destinationID] = nil }
    }

    private func depart(_ removed: [NativeDestination], apply: () -> Void) async {
        guard !departureRunning else { return }
        departureRunning = true
        defer { departureRunning = false }
        let revision = navigationRevision
        let identity = generation
        var prepared: [(NativeDestination, Departure)] = []
        for destination in removed.reversed() where requiresDeparture(destination) {
            // Fail closed before the editor registers, rather than dropping an
            // unloaded draft during the first SwiftUI task scheduling window.
            guard let owner = departures[destination.id], await owner.prepare(),
                  !Task.isCancelled, generation == identity, navigationRevision == revision,
                  departures[destination.id]?.token == owner.token else { return }
            prepared.append((destination, owner))
        }
        guard !Task.isCancelled, generation == identity, navigationRevision == revision else { return }
        // Preparation may flush drafts, but must not destroy a model until every
        // owner has consented and the captured navigation transaction can commit.
        for (destination, owner) in prepared {
            guard departures[destination.id]?.token == owner.token, owner.validate() else { return }
        }
        for (destination, owner) in prepared {
            owner.terminate()
            departures[destination.id] = nil
        }
        apply()
    }

    func dismissSheet() async {
        await depart(sheetDestinations) { sheetPath = []; sheet = nil }
    }

    private func replaceSheet(_ destination: NativeDestination) async {
        await depart(sheetDestinations) { sheetPath = []; sheet = destination }
    }

    func resetNavigationAwaitingDeparture() async {
        await depart(allDestinations) { clearNavigation() }
    }

    enum Stack { case home, notifications, profile, sheet }
    func path(for stack: Stack) -> [NativeDestination] {
        switch stack {
        case .home: return homePath
        case .notifications: return notificationsPath
        case .profile: return profilePath
        case .sheet: return sheetPath
        }
    }
    struct PathUpdateOwner: Equatable {
        fileprivate let identityEpoch: String?
        fileprivate let generation: Int
        fileprivate let revision: Int
    }
    func capturePathUpdateOwner() -> PathUpdateOwner {
        PathUpdateOwner(identityEpoch: validEpoch(session), generation: generation, revision: navigationRevision)
    }
    func updatePath(_ value: [NativeDestination], for stack: Stack, owner: PathUpdateOwner? = nil) async {
        if let owner, owner != capturePathUpdateOwner() { return }
        let current = path(for: stack)
        // NavigationStack writes are pops only. Route creation belongs to open(),
        // never to a delayed setter replaying destinations from an old stack.
        guard value.count <= current.count, Array(current.prefix(value.count)) == value else { return }
        let removed = Array(current.dropFirst(value.count))
        await depart(removed) {
            switch stack {
            case .home: homePath = value
            case .notifications: notificationsPath = value
            case .profile: profilePath = value
            case .sheet: sheetPath = value
            }
        }
    }

    func dismissDestination(_ id: UUID) async {
        if sheet?.id == id { await dismissSheet(); return }
        for stack in [Stack.home, .notifications, .profile, .sheet] {
            let current = path(for: stack)
            if let index = current.firstIndex(where: { $0.id == id }) {
                await updatePath(Array(current.prefix(index)), for: stack)
                return
            }
        }
    }
    private var stores: [WeakNativeStore] = []
    private final class RetainedOwner {
        weak var value: AnyObject?
        let invalidate: () -> Void
        let mutation: ((String) -> Void)?
        init(_ value: AnyObject, invalidate: @escaping () -> Void, mutation: ((String) -> Void)?) {
            self.value = value; self.invalidate = invalidate; self.mutation = mutation
        }
    }
    private var retainedOwners: [RetainedOwner] = []
    /// Presentation owners remain view-owned; this weak registry only revokes them.
    func registerRetainedOwner(_ owner: AnyObject, invalidate: @escaping () -> Void, mutation: ((String) -> Void)? = nil) {
        retainedOwners.removeAll { $0.value == nil || $0.value === owner }
        retainedOwners.append(RetainedOwner(owner, invalidate: invalidate, mutation: mutation))
    }
    func register(_ store: NativeStore) {
        stores.removeAll { $0.value == nil }
        if !stores.contains(where: { $0.value === store }) { stores.append(WeakNativeStore(store)) }
    }
    private func invalidateSession(preservingAuthentication: Bool = false) {
        let authentication = preservingAuthentication ? sheet.flatMap { destination in
            guard authenticationPresentation?.destinationID == destination.id else { return nil as NativeDestination? }
            return destination.route == "SignIn" || (destination.route == "Web" &&
                ["SIGN_IN", "ONE_TAP_SIGN_IN", "CHALLENGE"].contains(destination.arguments["goal"]?.string ?? ""))
                ? destination : nil
        } : nil
        if authentication == nil { authenticationPresentation = nil }
        privateResetConfirmation = nil
        let owners = Array(departures.values)
        departures = [:]
        for owner in owners { owner.revoke() } // Never flush under the new identity.
        for request in requests.values where !request.changesSession { request.task.cancel() }
        for store in stores { store.value?.invalidate() }
        for owner in retainedOwners where owner.value != nil { owner.invalidate() }
        retainedOwners = []
        generation += 1
        homePath = []; notificationsPath = []; profilePath = []; sheetPath = []
        // Assign the same destination identity so a live nested WKWebView isn't
        // dismantled and reseeded merely because private admission closed.
        sheet = authentication
    }
}