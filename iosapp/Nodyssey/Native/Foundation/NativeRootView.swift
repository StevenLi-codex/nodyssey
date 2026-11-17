import SwiftUI
import NodysseyNativeCore

struct NativeRootView: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var restart = 0

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
        // System TabView/NavigationStack supplies Liquid Glass on iOS 26;
        // the canvas sits behind it, not on the bars or their scroll-edge treatment.
    }
}

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