import SwiftUI
import NodysseyNativeCore

struct NativeRootView: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var restart = 0

    var body: some View {
        VStack(spacing: 0) {
            Text("preview_guest_notice", tableName: "Foundation")
                .font(.caption).padding(8).frame(maxWidth: .infinity)
                .background(Color.orange.opacity(0.15))
            if app.isReady {
                if let failure = app.lifecycleFailure {
                    NativeFailureView(failure: failure, retry: { restart += 1 })
                }
                if let failure = app.linkFailure {
                    NativeFailureView(failure: failure)
                    Button("action_close") { app.linkFailure = nil }
                }
                if app.settings.nativeBool("onboardingSeen") == false {
                    NavigationStack(path: $app.homePath) {
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("native.root")
        .modifier(NativeSettingsAppearance(settings: app.settings))
        .sheet(item: $app.sheet, onDismiss: { app.sheetPath = [] }) { destination in
            NavigationStack(path: $app.sheetPath) {
                NativeScreen(destination: destination)
                    .navigationDestination(for: NativeDestination.self) { NativeScreen(destination: $0) }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("action_close") { app.sheet = nil }
                        }
                    }
            }
            .environmentObject(app)
            .modifier(NativeSettingsAppearance(settings: app.settings))
        }
        .task(id: restart) { await app.start() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await app.foreground() } }
        }
        .onOpenURL { app.openLink($0.absoluteString) }
    }

    private var tabs: some View {
        TabView(selection: $app.selectedTab) {
            NavigationStack(path: $app.homePath) {
                NativeScreen(destination: NativeDestination("PostList"))
                    .navigationDestination(for: NativeDestination.self) { NativeScreen(destination: $0) }
            }
            .tabItem { Label("tab_home", systemImage: "house").accessibilityIdentifier("native.tab.home") }
            .tag(NativeTab.home)
            NavigationStack(path: $app.notificationsPath) {
                NativeScreen(destination: NativeDestination("Notifications"))
                    .navigationDestination(for: NativeDestination.self) { NativeScreen(destination: $0) }
            }
            .tabItem { Label("tab_notifications", systemImage: "bell").accessibilityIdentifier("native.tab.notifications") }
            .tag(NativeTab.notifications)
            NavigationStack(path: $app.profilePath) {
                NativeScreen(destination: NativeDestination("Profile"))
                    .navigationDestination(for: NativeDestination.self) { NativeScreen(destination: $0) }
            }
            .tabItem { Label("tab_profile", systemImage: "person.crop.circle").accessibilityIdentifier("native.tab.profile") }
            .tag(NativeTab.profile)
        }
        // System TabView/NavigationStack supplies Liquid Glass on iOS 26;
        // no painted background hides the native treatment or scroll-edge behavior.
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
