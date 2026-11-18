import SwiftUI
import NodysseyNativeCore

struct NativeRootView: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var restart = 0
    @State private var homeTabInteraction = NativeHomeTabInteraction()

    var body: some View {
        VStack(spacing: 0) {
            if app.isReady || app.activeSite != nil {
                if let failure = app.lifecycleFailure {
                    NativeFailureView(failure: failure, retry: { restart += 1 })
                }
                if let failure = app.linkFailure {
                    NativeFailureView(failure: failure)
                    Button("action_close") { app.linkFailure = nil }
                }
                if app.settings.nativeBool("onboardingSeen") == false {
                    NavigationStack(path: pathBinding(.home)) {
                        NativeWelcomeView()
                            .navigationDestination(for: NativeDestination.self) { NativeScreen(destination: $0) }
                    }
                } else {
                    tabs.id(app.generation)
                }
            } else if let failure = app.lifecycleFailure {
                NativeFailureView(failure: failure, retry: { restart += 1 })
            } else {
                NativeBusyView()
            }
        }
        .nativePageCanvas()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("native.root")
        .modifier(NativeSettingsAppearance(settings: app.settings))
        .sheet(item: Binding(get: { app.sheet }, set: { value in
            if value == nil { Task { await app.dismissSheet() } }
        })) { destination in
            NavigationStack(path: pathBinding(.sheet)) {
                NativeScreen(destination: destination)
                    .navigationDestination(for: NativeDestination.self) { NativeScreen(destination: $0) }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("action_close") { Task { await app.dismissSheet() } }
                                .disabled(app.departureRunning)
                        }
                    }
            }
            .nativePageCanvas()
            .environmentObject(app)
            .interactiveDismissDisabled(app.sheetRequiresDeparture || app.departureRunning)
            .modifier(NativeSettingsAppearance(settings: app.settings))
        }
        .task(id: restart) { await app.start() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await app.foreground() } }
        }
        .onOpenURL { app.openLink($0.absoluteString) }
    }

    private func pathBinding(_ stack: NativeAppModel.Stack) -> Binding<[NativeDestination]> {
        // Bind this render owner before the setter's unstructured task can yield.
        let owner = app.capturePathUpdateOwner()
        return Binding(get: { app.path(for: stack) }, set: { value in
            Task { await app.updatePath(value, for: stack, owner: owner) }
        })
    }

    private var tabs: some View {
        TabView(selection: $app.selectedTab) {
            NavigationStack(path: pathBinding(.home)) {
                NativeScreen(destination: NativeDestination("PostList"))
                    #if os(iOS)
                    .background {
                        NativeTabTapObserver(isHomeRoot: { app.homePath.isEmpty && app.sheet == nil }, selected: { wasHome, isHome, wasRoot in
                            if homeTabInteraction.tap(at: ProcessInfo.processInfo.systemUptime, wasHome: wasHome, isHome: isHome,
                                                      isRoot: wasRoot && app.homePath.isEmpty && app.sheet == nil, atTop: false) {
                                app.homeScrollToTop.send()
                            }
                        }).allowsHitTesting(false)
                    }
                    #endif
                    .navigationDestination(for: NativeDestination.self) { NativeScreen(destination: $0) }
            }
            .tabItem { Label("tab_home", systemImage: "house").accessibilityIdentifier("native.tab.home") }
            .tag(NativeTab.home)
            NavigationStack(path: pathBinding(.notifications)) {
                NativeScreen(destination: NativeDestination("Notifications"))
                    .navigationDestination(for: NativeDestination.self) { NativeScreen(destination: $0) }
            }
            .tabItem { Label("tab_notifications", systemImage: "bell").accessibilityIdentifier("native.tab.notifications") }
            .tag(NativeTab.notifications)
            NavigationStack(path: pathBinding(.profile)) {
                NativeScreen(destination: NativeDestination("Profile"))
                    .navigationDestination(for: NativeDestination.self) { NativeScreen(destination: $0) }
            }
            .tabItem { Label("tab_profile", systemImage: "person.crop.circle").accessibilityIdentifier("native.tab.profile") }
            .tag(NativeTab.profile)
        }
        .nativePageCanvas()
        .onChange(of: app.selectedTab) { _ in homeTabInteraction.reset() }
        .onChange(of: app.homePath) { _ in homeTabInteraction.reset() }
        .onChange(of: app.sheet) { _ in homeTabInteraction.reset() }
        .onChange(of: app.generation) { _ in homeTabInteraction.reset() }
        // System TabView/NavigationStack supplies Liquid Glass on iOS 26;
        // the canvas sits behind it, not on the bars or their scroll-edge treatment.
    }
}

#if os(iOS)
import UIKit

/// SwiftUI's selection binding is not a repeated-tap API. Apple's public
/// didSelect callback is (including reselecting the same controller). Observe
/// it without replacing the system TabView, touching bar views or vetoing taps.
private struct NativeTabTapObserver: UIViewControllerRepresentable {
    let isHomeRoot: () -> Bool
    let selected: (Bool, Bool, Bool) -> Void

    func makeUIViewController(context: Context) -> Observer {
        let observer = Observer()
        observer.isHomeRoot = isHomeRoot
        observer.selected = selected
        return observer
    }
    func updateUIViewController(_ observer: Observer, context: Context) {
        observer.isHomeRoot = isHomeRoot
        observer.selected = selected
        observer.install()
    }
    static func dismantleUIViewController(_ observer: Observer, coordinator: ()) { observer.detach() }

    final class Observer: UIViewController {
        var isHomeRoot: () -> Bool = { false }
        var selected: (Bool, Bool, Bool) -> Void = { _, _, _ in }
        private let proxy = DelegateProxy()
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            // The containing hosting controller may acquire its parent later in
            // this same mount. No polling and no screen-coordinate hit testing.
            DispatchQueue.main.async { [weak self] in self?.install() }
        }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); install() }
        func install() {
            var child: UIViewController = self
            while let parent = child.parent {
                if let tabs = parent as? UITabBarController {
                    if proxy.tabs !== tabs { detach() }
                    proxy.tabs = tabs
                    proxy.home = child
                    proxy.isHomeRoot = { [weak self] in self?.isHomeRoot() ?? false }
                    proxy.selected = { [weak self] in self?.selected($0, $1, $2) }
                    if tabs.delegate !== proxy {
                        proxy.original = tabs.delegate
                        tabs.delegate = proxy
                    }
                    return
                }
                child = parent
            }
        }
        func detach() {
            if let tabs = proxy.tabs, tabs.delegate === proxy { tabs.delegate = proxy.original }
            proxy.tabs = nil; proxy.home = nil; proxy.original = nil
        }
    }

    final class DelegateProxy: NSObject, UITabBarControllerDelegate {
        weak var tabs: UITabBarController?
        weak var home: UIViewController?
        // NSObject forwarding is nonisolated; UIKit owns all delegate access on
        // the main thread. Store the weak reference without crossing Any through
        // assumeIsolated's Sendable return requirement.
        nonisolated(unsafe) weak var original: (any UITabBarControllerDelegate)?
        var isHomeRoot: () -> Bool = { false }
        var selected: (Bool, Bool, Bool) -> Void = { _, _, _ in }
        private var before: (wasHome: Bool, wasRoot: Bool)?

        func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
            // Capture before forwarding: SwiftUI's delegate may mutate selection
            // or navigation synchronously. Its admission decision stays intact.
            before = (tabBarController.selectedViewController === home, isHomeRoot())
            let allowed = original?.tabBarController?(tabBarController, shouldSelect: viewController) ?? true
            if !allowed { before = nil }
            return allowed
        }
        func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
            let captured = before
            before = nil
            original?.tabBarController?(tabBarController, didSelect: viewController)
            guard let captured else { return }
            selected(captured.wasHome, viewController === home, captured.wasRoot)
        }
        // Forward every other optional delegate selector (custom transitions,
        // orientation, customization, newer UIKit methods) to the existing owner.
        nonisolated override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }
        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
            if let original, original.responds(to: selector) { return original }
            return super.forwardingTarget(for: selector)
        }
    }
}
#endif

private struct NativeWelcomeView: View {
    @EnvironmentObject private var app: NativeAppModel
    @State private var busy = false
    @State private var failure: NativeFailure?
    var body: some View {
        Form {
            Section {
                Text("onboarding_welcome_title").font(.title2)
                Text("native_foundation_welcome", tableName: "Foundation")
            }
            Section {
                Button { app.open("Help") } label: { Text("native_foundation_help", tableName: "Foundation") }
                Button { app.open("Privacy") } label: { Text("native_foundation_privacy", tableName: "Foundation") }
            }
            Section {
                if let failure { NativeFailureView(failure: failure) }
                Button("onboarding_done") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            let settings = try await app.request("settings.set", ["key": .string("onboardingSeen"), "value": .bool(true)])
                            guard settings.nativeBool("onboardingSeen") == true else {
                                throw NativeFailure(code: "INVALID_DATA", message: "Onboarding was not persisted")
                            }
                            app.settings = settings
                            app.resetNavigation()
                        } catch {
                            guard !Task.isCancelled, !(error is CancellationError) else { return }
                            failure = nativeSafeFailure(error)
                        }
                    }
                }
                .disabled(busy)
                .accessibilityIdentifier("native.onboarding.continue")
                if busy { ProgressView() }
            }
        }
    }
}