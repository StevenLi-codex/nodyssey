import Foundation
import Combine
import NodysseyNativeCore

@MainActor final class NativeAppModel: ObservableObject {
    let transport: any NativeTransport
    @Published var session: JSONValue = .null {
        didSet {
            guard oldValue.nativeInt("generation") != session.nativeInt("generation") ||
                  oldValue.nativeBool("isSignedIn") != session.nativeBool("isSignedIn") else { return }
            invalidateSession()
        }
    }
    private final class WeakNativeStore {
        weak var value: NativeStore?
        init(_ value: NativeStore) { self.value = value }
    }
    @Published var settings: JSONValue = .null
    @Published var generation: Int = 0
    @Published var selectedTab: NativeTab = .home
    @Published var homePath: [NativeDestination] = []
    @Published var notificationsPath: [NativeDestination] = []
    @Published var profilePath: [NativeDestination] = []
    @Published var sheet: NativeDestination?
    @Published var sheetPath: [NativeDestination] = []
    @Published private(set) var site: JSONValue = .null
    @Published private(set) var isReady = false
    @Published var lifecycleFailure: NativeFailure?
    @Published var linkFailure: NativeFailure?
    private var activeStart: Task<Void, Never>?
    private var sessionReady = false
    private var settingsReady = false
    private var pendingLinks: [String] = []
    private var requests: [UUID: (changesSession: Bool, task: Task<JSONValue, Error>)] = [:]
    private var foregroundTask: Task<Void, Never>?
    private var foregroundRunning = false

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
                sessionReady = false
                isReady = false
                continue
            }
            guard snapshot.nativeInt("generation") != nil, snapshot.nativeBool("isSignedIn") != nil else {
                throw NativeFailure(code: "INVALID_DATA", message: "Invalid session response")
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

    private func becameReady() {
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
        if let previous = site.nativeString("current"), previous != raw { invalidateSession() }
        site = snapshot // selected is NEXT launch, never the active namespace.
    }

    func request(_ operation: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        try Task.checkCancellation()
        let capturedGeneration = generation
        let id = UUID()
        let changesSession = ["session.sync", "session.signIn", "session.verifyTwoFactor", "session.signOut"].contains(operation)
        let transport = self.transport
        let task = Task { try await transport.request(operation, arguments) }
        requests[id] = (changesSession, task)
        defer { requests[id] = nil }
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
                session = candidate
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
            sheetPath = []; sheet = destination; return
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
        homePath = []; notificationsPath = []; profilePath = []; sheetPath = []; sheet = nil
    }
    private var stores: [WeakNativeStore] = []
    func register(_ store: NativeStore) {
        stores.removeAll { $0.value == nil }
        if !stores.contains(where: { $0.value === store }) { stores.append(WeakNativeStore(store)) }
    }
    private func invalidateSession() {
        for request in requests.values where !request.changesSession { request.task.cancel() }
        for store in stores { store.value?.invalidate() }
        generation += 1
        resetNavigation()
    }
}
