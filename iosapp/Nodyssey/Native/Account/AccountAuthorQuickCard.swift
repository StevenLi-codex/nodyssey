import SwiftUI
import NodysseyNativeCore

/// An explicitly opened, read-only sheet, not a userscript runtime. Feature idea:
/// NodeSeek Pro Max 1.2.6 by 用蚊香买榄菊 (GPL-3.0); see docs/native-promax-integration.md.
struct AccountAuthorQuickCard: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = AccountAuthorQuickCardState()
    @State private var retry = 0
    let uid: Int64
    /// Optional parent handoff for navigation after a sheet's dismissal. The
    /// default uses the existing app routes; neither path sends a message.
    var onNavigate: ((AccountAuthorQuickCardNavigation) -> Void)? = nil

    var body: some View {
        let snapshot = state.snapshot(for: uid)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let profile = snapshot.profile {
                        AccountAuthorQuickCardContent(profile: profile, note: snapshot.note,
                                                      notesAvailable: snapshot.notesAvailable,
                                                      notesLoading: snapshot.isLoading)
                        Button { navigate(message: false) } label: {
                            Text("native.account.quick_card.full_profile", tableName: "Account")
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }.buttonStyle(.borderedProminent)
                        if state.navigation(for: uid, message: true, signedIn: app.isSignedIn) != nil {
                            Button("space_message") { navigate(message: true) }
                                .buttonStyle(.bordered).frame(minHeight: 44)
                        }
                        if !snapshot.isLoading && !snapshot.notesAvailable { retryButton }
                    } else if snapshot.isLoading {
                        ProgressView("loading_indicator_label").frame(maxWidth: .infinity)
                    } else {
                        if let failure = snapshot.failure { NativeFailureView(failure: failure) }
                        Text("native.account.quick_card.unavailable", tableName: "Account").foregroundStyle(.secondary)
                        if uid > 0 { retryButton }
                    }
                    Divider()
                    Text("native.account.quick_card.credit", tableName: "Account")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(Text("native.account.quick_card.title", tableName: "Account"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action_close") { state.invalidate(); dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        // A session change invalidates but does not silently fetch again. Only
        // opening a target or explicitly retrying starts a new bounded read.
        .task(id: "\(uid):\(retry)") {
            await state.load(uid: uid, using: app.transport, currentGeneration: { app.generation })
        }
        .onChange(of: app.generation) { _ in state.invalidate() }
        .onDisappear { state.invalidate() }
    }

    private var retryButton: some View {
        Button { retry += 1 } label: { Text("native.account.reconcile", tableName: "Account") }
            .buttonStyle(.bordered).frame(minHeight: 44)
    }

    private func navigate(message: Bool) {
        guard let destination = state.navigation(for: uid, message: message, signedIn: app.isSignedIn) else { return }
        state.invalidate()
        dismiss()
        if let onNavigate { onNavigate(destination); return }
        switch destination {
        case .signIn: app.showSignIn()
        case .route(let route, let arguments): app.open(route, arguments)
        }
    }
}

/// Pure native content composition; raw bio/notes are Text, never executable HTML.
struct AccountAuthorQuickCardContent: View {
    @Environment(\.locale) private var locale
    let profile: JSONValue
    let note: String?
    let notesAvailable: Bool
    let notesLoading: Bool

    private var unknown: String { String(localized: "native.account.quick_card.unknown", table: "Account") }
    private func text(_ key: String) -> String? {
        guard let value = profile[key]?.string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    private func count(_ key: String) -> String {
        guard let value = profile[key]?.int, value >= 0 else { return unknown }
        return String(value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(.secondary.opacity(0.10))
                    if let avatar = text("avatarUrl") { NativeRemoteImage(url: avatar) }
                    else { Image(systemName: "person.fill").foregroundStyle(.secondary) }
                }.frame(width: 44, height: 44).clipShape(Circle()).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(text("name") ?? unknown).font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("UID \(profile["uid"]?.int.map(String.init) ?? unknown)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            LabeledContent { Text(count("rank")) } label: { Text("profile_level") }
            LabeledContent {
                Text(text("createdAt").flatMap { AccountProfileDate.formatted($0, locale: locale) } ?? unknown)
            } label: { Text("native.account.quick_card.registered", tableName: "Account") }
            VStack(alignment: .leading, spacing: 4) {
                Text("space_bio").font(.caption).foregroundStyle(.secondary)
                Text(text("bio") ?? unknown).font(.subheadline).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent { Text(count("topicCount")).monospacedDigit() } label: { Text("space_stat_topics") }
            LabeledContent { Text(count("commentCount")).monospacedDigit() } label: { Text("space_stat_comments") }
            Divider()
            Text("native.account.note", tableName: "Account").font(.caption).foregroundStyle(.secondary)
            if notesLoading { ProgressView("loading_indicator_label") }
            else if !notesAvailable { Text("native.account.quick_card.notes_unavailable", tableName: "Account").foregroundStyle(.secondary) }
            else if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(note).font(.subheadline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else { Text("native.account.quick_card.no_note", tableName: "Account").foregroundStyle(.secondary) }
        }.font(.subheadline)
    }
}
