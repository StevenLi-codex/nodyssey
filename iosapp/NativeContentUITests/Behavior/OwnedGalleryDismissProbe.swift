import SwiftUI
import UIKit
import NodysseyNativeCore

struct ProbeTransport: NativeTransport {
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue { fatalError("unexpected transport: \(operation)") }
    func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error> { fatalError("unexpected observation: \(operation)") }
}

@MainActor enum Actions {
    static var current: [String: () -> Void] = [:]
    static let empty = "empty"
    static let route = "https://fixture.invalid/route.png"
    static let replacement = "https://fixture.invalid/replacement.png"
    static let cover = "https://fixture.invalid/cover.png"
    static var owners: [String: NativeOwnedNavigationController] = [:]
}

// Capture the same closure passed to the mounted Button. UIView updates refresh the
// capture on each render; teardown removes only its own registration.
struct ActionCapture: UIViewRepresentable {
    let name: String
    let action: () -> Void
    final class Capture: UIView {
        var name = ""
        var action: (() -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); publish() }
        func publish() {
            if window != nil { Actions.current[name] = action }
        }
    }
    func makeUIView(context: Context) -> Capture { Capture(frame: .zero) }
    func updateUIView(_ view: Capture, context: Context) { view.name = name; view.action = action; view.publish() }
}

struct ProbeHost: View {
    @ObservedObject var app: NativeAppModel
    var body: some View {
        NativeOwnedNavigation(app: app, stack: .home, rootID: nil, path: app.homePath,
                             isActive: app.sheet == nil && app.selectedTab == .home,
                             root: AnyView(Text("Home fixture")))
            .sheet(isPresented: Binding(get: { app.sheet != nil }, set: { shown in
                if !shown { Task { await app.dismissSheet() } }
            })) {
                if let sheet = app.sheet {
                    NativeOwnedNavigation(app: app, stack: .sheet, rootID: sheet.id, path: app.sheetPath,
                                          isActive: true, root: AnyView(Text("Sheet fixture")))
                        .environment(\.nativeCardMotionDisabled, true)
                        .environmentObject(app)
                }
            }
            // UIKit diagnostic host supplies the active-scene environment that
            // SwiftUI.App normally installs; the real owned container still gates it.
            .environment(\.scenePhase, .active)
            .environment(\.nativeCardMotionDisabled, true)
            .environmentObject(app)
    }
}

@main @MainActor final class ProbeApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.sceneClass = UIWindowScene.self
        configuration.delegateClass = ProbeScene.self
        return configuration
    }
}

@MainActor final class ProbeScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    let app = NativeAppModel(transport: ProbeTransport())
    var lines: [String] = []
    var cases = 0
    var started = false

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        self.window = window
        window.rootViewController = UIHostingController(rootView: ProbeHost(app: app))
        window.makeKeyAndVisible()
    }
    func sceneDidBecomeActive(_ scene: UIScene) {
        guard !started else { return }
        started = true
        Task { await run() }
    }

    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: message, code: 1) }
    }
    func wait(_ predicate: () -> Bool, _ message: String, iterations: Int = 90) async throws {
        for _ in 0..<iterations { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw NSError(domain: message, code: 1)
    }
    func step(_ name: String, _ trial: () async throws -> Void) async {
        cases += 1
        do { try await trial(); lines.append("PASS \(name)") }
        catch { lines.append("FAIL \(name): \((error as NSError).domain)") }
    }
    func reset() async throws -> UUID {
        await app.resetNavigationAwaitingDeparture()
        Actions.current.removeAll()
        do {
            try await wait({ app.sheet == nil && Actions.owners["home"]?.probeAtRest(nil) == true && self.window?.rootViewController?.presentedViewController == nil }, "fixture reset did not settle")
        } catch {
            throw NSError(domain: "fixture reset did not settle: \(Actions.owners["home"]?.probeDescription ?? "no owner")", code: 1)
        }
        app.selectedTab = .home
        app.open("PostDetail", ["postId": .integer(42)])
        let thread = app.homePath.last!.id
        app.registerDismissal(destinationID: thread, close: { true }, revoke: {})
        try await wait({ Actions.owners["home"]?.probeAtRest(thread) == true }, "thread did not mount in owned navigation")
        return thread
    }
    func open(_ requestedURL: String? = nil) {
        let url = requestedURL ?? Actions.route
        ContentImageGallery.onImage(value: .object(["type": .string("img"), "url": .string(url)]), open: app.open)(url, nil)
    }
    func action(_ key: String, owner: String, top: UUID) async throws -> () -> Void {
        try await wait({ Actions.owners[owner]?.probeAtRest(top) == true && Actions.current[key] != nil }, "mounted production action missing for \(key)")
        return Actions.current[key]!
    }
    func assertReturned(_ thread: UUID, gallery: UUID) async throws {
        for _ in 0..<55 {
            if app.homePath.map(\.id) == [thread] && Actions.owners["home"]?.probeAtRest(thread) == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "close did not restore thread; thread=\(thread) gallery=\(gallery) path=\(app.homePath.map(\.id)) visible=\(Actions.owners["home"]?.probeVisibleDescription ?? "none")", code: 1)
    }
    func run() async {
        await step("empty-gallery-close") {
            let thread = try await reset()
            app.open("ImageViewer", ["urls": .array([])])
            let gallery = app.homePath.last!.id
            try await action(Actions.empty, owner: "home", top: gallery)()
            lines.append("ACTION empty-gallery-close gallery=\(gallery)")
            try await assertReturned(thread, gallery: gallery)
        }
        await step("routed-viewer-close") {
            let thread = try await reset()
            open()
            let gallery = app.homePath.last!.id
            try await action(Actions.route, owner: "home", top: gallery)()
            lines.append("ACTION routed-viewer-close gallery=\(gallery)")
            try await assertReturned(thread, gallery: gallery)
        }
        await step("routed-viewer-drag") {
            let thread = try await reset()
            open()
            let gallery = app.homePath.last!.id
            _ = try await action(Actions.route, owner: "home", top: gallery)
            try await wait({ Actions.owners["home"]?.probeZoomReady == true }, "loaded production zoom view missing")
            try require(Actions.owners["home"]?.probeDrag(distance: 40) == true, "production terminal drag not invoked")
            try await Task.sleep(for: .milliseconds(180))
            try require(app.homePath.map(\.id) == [thread, gallery], "short drag closed route")
            try require(Actions.owners["home"]?.probeDrag(distance: 160) == true, "production terminal drag not invoked")
            lines.append("ACTION routed-viewer-drag gallery=\(gallery)")
            try await assertReturned(thread, gallery: gallery)
        }
        await step("sheet-child-close-only") {
            let thread = try await reset()
            app.showSignIn()
            let sheet = app.sheet!.id
            try await wait({ Actions.owners["sheet"]?.probeAtRest(sheet) == true }, "outer sheet root not mounted")
            open()
            let gallery = app.sheetPath.last!.id
            try await action(Actions.route, owner: "sheet", top: gallery)()
            lines.append("ACTION sheet-child-close-only gallery=\(gallery) sheet=\(sheet)")
            do { try await wait({ app.sheet?.id == sheet && app.sheetPath.isEmpty && Actions.owners["sheet"]?.probeAtRest(sheet) == true }, "routed viewer failed to restore same sheet root", iterations: 55) }
            catch { throw NSError(domain: "\((error as NSError).domain); sheet=\(String(describing: app.sheet?.id)) path=\(app.sheetPath.map(\.id))", code: 1) }
            try require(app.homePath.map(\.id) == [thread], "sheet close touched Home")
        }
        await step("stale-hidden-and-replaced") {
            let thread = try await reset()
            open()
            let old = app.homePath.last!.id
            let retained = try await action(Actions.route, owner: "home", top: old)
            // Same gallery is now a retained predecessor. Its UUID still exists.
            open(Actions.replacement)
            let newer = app.homePath.last!.id
            _ = try await action(Actions.replacement, owner: "home", top: newer)
            retained()
            try await Task.sleep(for: .milliseconds(220))
            try require(app.homePath.map(\.id) == [thread, old, newer] && Actions.owners["home"]?.probeAtRest(newer) == true, "hidden gallery removed a newer route")
            await app.dismissDestination(newer)
            try await wait({ Actions.owners["home"]?.probeAtRest(old) == true }, "old gallery did not return for fixture cleanup")
            app.session = .object(["identityEpoch": .string("replacement-identity"), "isSignedIn": .bool(true)])
            try await wait({ app.homePath.isEmpty && Actions.owners["home"]?.probeAtRest(nil) == true }, "identity did not revoke old gallery")
            app.open("PostDetail", ["postId": .integer(43)])
            let nextThread = app.homePath.last!.id
            app.registerDismissal(destinationID: nextThread, close: { true }, revoke: {})
            Actions.current.removeValue(forKey: Actions.replacement)
            open(Actions.replacement)
            let replacement = app.homePath.last!.id
            let current = try await action(Actions.replacement, owner: "home", top: replacement)
            retained()
            try await Task.sleep(for: .milliseconds(220))
            try require(app.homePath.map(\.id) == [nextThread, replacement], "revoked gallery closed replacement")
            current()
            lines.append("ACTION stale-hidden-and-replaced old=\(old) replacement=\(replacement)")
            try await assertReturned(nextThread, gallery: replacement)
        }
        await step("modal-viewer-system-close") {
            let thread = try await reset()
            try await wait({ Actions.current["open-cover"] != nil }, "remote image open action not mounted")
            Actions.current["open-cover"]!()
            try await wait({ Actions.current[Actions.cover] != nil && self.window?.rootViewController?.presentedViewController != nil }, "real NativeRemoteImage fullScreenCover did not mount")
            Actions.current[Actions.cover]!()
            lines.append("ACTION modal-viewer-system-close")
            try await wait({ self.window?.rootViewController?.presentedViewController == nil }, "modal did not dismiss")
            try require(app.homePath.map(\.id) == [thread] && Actions.owners["home"]?.probeAtRest(thread) == true && app.sheet == nil, "modal close changed route owner")
            Actions.current.removeValue(forKey: Actions.cover)
            Actions.current["open-cover"]!()
            try await wait({ Actions.current[Actions.cover] != nil && self.window?.rootViewController?.presentedViewController != nil }, "second fullScreenCover did not mount")
            try await wait({ self.window?.rootViewController?.presentedViewController.map { ProbeDrag.isReady(in: $0.view) } == true }, "modal production zoom missing")
            try require(ProbeDrag.run(in: self.window!.rootViewController!.presentedViewController!.view, distance: 160), "modal terminal drag replay missing")
            try await wait({ self.window?.rootViewController?.presentedViewController == nil }, "modal drag did not dismiss")
            try require(app.homePath.map(\.id) == [thread] && app.sheet == nil, "modal drag changed route owner")
        }
        await step("departure-refusal-and-acceptance") {
            let thread = try await reset()
            open()
            let gallery = app.homePath.last!.id
            let close = try await action(Actions.route, owner: "home", top: gallery)
            var prepared = 0, terminated = 0
            var allow = false
            app.registerDismissal(destinationID: gallery, close: { prepared += 1; return allow }, revoke: {}, terminate: { terminated += 1 })
            close()
            try await wait({ prepared == 1 && !app.departureRunning }, "close never reached registered departure owner", iterations: 55)
            try require(app.homePath.map(\.id) == [thread, gallery] && terminated == 0, "refused close removed route")
            allow = true
            close()
            try await assertReturned(thread, gallery: gallery)
            try require(prepared == 2 && terminated == 1, "accepted close did not terminate exactly once")
        }
        lines.append("COMPLETE cases=\(cases)")
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.txt")
        try! lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
