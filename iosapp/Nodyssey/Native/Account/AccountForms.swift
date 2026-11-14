import SwiftUI
import PhotosUI
import UIKit
import NodysseyNativeCore

struct AccountProfileFieldsScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var store = NativeStore()
    @StateObject private var action = AccountAction()
    @State private var bio = ""
    @State private var signature = ""
    @State private var readme = ""
    @State private var photo: PhotosPickerItem?
    @State private var avatar: Data?
    @State private var avatarMIME = ""
    @State private var failure: NativeFailure?
    @State private var confirmation: String?
    @State private var preview: String?
    @State private var photoTask: Task<Void, Never>?

    var body: some View {
        Form {
            if app.isSignedIn {
                AccountStoreStatus(store: store) { Task { await load() } }
                if store.value != .null {
                    Section("account_avatar") {
                        PhotosPicker(selection: $photo, matching: .images) { Text("account_avatar_pick") }
                        if let avatar, let image = UIImage(data: avatar) {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 150)
                            Text("account_avatar_pending")
                            Button("account_action_save") { confirmation = "avatar" }.disabled(action.blocked)
                            Button("action_cancel") { self.avatar = nil; photo = nil }
                        }
                    }
                    Section("account_bio") { TextField("account_bio_hint", text: $bio, axis: .vertical) }
                    Section("account_signature") {
                        TextEditor(text: $signature).frame(minHeight: 100)
                        Text("account_signature_helper").font(.caption)
                        Button("action_preview") { preview = signature }
                    }
                    Section("account_readme") {
                        TextEditor(text: $readme).frame(minHeight: 180)
                        Text("account_readme_helper").font(.caption)
                        Button("action_preview") { preview = readme }
                    }
                    Button("account_action_save") { confirmation = "profile" }.disabled(action.blocked)
                }
                AccountActionStatus(action: action)
                if let failure { NativeFailureView(failure: failure) }
            } else { AccountRequireSignIn() }
        }
        .disabled(action.state.phase == .writing || action.state.phase == .reading)
        .navigationTitle("account_profile_title")
        .task(id: app.generation) {
            action.cancel(); photoTask?.cancel(); bio = ""; signature = ""; readme = ""; avatar = nil; photo = nil; confirmation = nil
            await load()
        }
        .onChange(of: photo) { item in
            photoTask?.cancel()
            let generation = app.generation
            photoTask = Task {
                do {
                    guard let data = try await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                        if item != nil { failure = NativeFailure(code: "INVALID_ARGUMENT", message: "") }; return
                    }
                    let bytes: Data
                    if (try? AccountInputState.avatar(data)) != nil { bytes = data }
                    else if let jpeg = image.jpegData(compressionQuality: 0.9) { bytes = jpeg }
                    else { throw NativeFailure(code: "INVALID_ARGUMENT", message: "") }
                    let mime = try AccountInputState.avatar(bytes)
                    guard !Task.isCancelled, generation == app.generation else { return }
                    avatar = bytes; avatarMIME = mime; failure = nil
                } catch { if !Task.isCancelled, generation == app.generation { failure = accountFailure(error) } }
            }
        }
        .confirmationDialog("account_action_save", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            Button("account_action_save") {
                let kind = confirmation; confirmation = nil
                if kind == "avatar", let avatar {
                    action.perform(app, operation: "account.uploadAvatar", arguments: ["base64": .string(avatar.base64EncodedString()), "mimeType": .string(avatarMIME), "confirmed": .bool(true)], read: {
                        _ = try await app.request("profile.self", ["refresh": .bool(true)])
                        self.avatar = nil; photo = nil
                    })
                } else if kind == "profile" {
                    action.perform(app, operation: "account.saveProfileFields", arguments: ["bio": .string(bio), "signature": .string(signature), "readme": .string(readme)], read: {
                        let fields = try await app.request("account.profileFields")
                        apply(fields)
                        _ = try await app.request("profile.self", ["refresh": .bool(true)])
                    })
                }
            }
        }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            NavigationStack { AccountMarkdown(bodyText: preview ?? "").padding().toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("action_close") { preview = nil } }
            } }
        }
        .onDisappear { action.cancel(); photoTask?.cancel(); avatar = nil }
    }
    private func apply(_ value: JSONValue) {
        bio = value.nativeString("bio") ?? ""; signature = value.nativeString("signature") ?? ""; readme = value.nativeString("readme") ?? ""
    }
    private func load() async { await store.load(app, "account.profileFields"); if store.failure == nil { apply(store.value) } }
}

struct AccountMarkdown: View {
    @EnvironmentObject private var app: NativeAppModel
    let bodyText: String
    @State private var nodes: [NativeRichNode] = []
    @State private var failure: NativeFailure?
    var body: some View {
        Group {
            if let failure { NativeFailureView(failure: failure) }
            else { NativeRichTextView(nodes: nodes, actions: NativeRichTextActions(
                onImage: { url, _ in app.open("ImageViewer", ["urls": .array([.string(url)]), "index": .integer(0)]) },
                onLink: { url in
                    if let resolved = AccountLinkState.resolve(url, origin: app.siteOrigin) { app.openLink(resolved) }
                }, onQuoteReference: { _, floor, url in
                    if let resolved = AccountLinkState.resolve(url, origin: app.siteOrigin, floor: floor) { app.openLink(resolved) }
                }
            )) }
        }
        .task(id: bodyText + String(app.generation)) {
            nodes = []; failure = nil
            do {
                let result = try await app.request("editor.preview", ["body": .string(bodyText)])
                let parsed = try JSONDecoder().decode([NativeRichNode].self, from: result.nativeEncoded())
                try Task.checkCancellation(); nodes = parsed
            } catch { if !Task.isCancelled { failure = accountFailure(error) } }
        }
    }
}

struct AccountSecurityScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = NativeStore()
    @StateObject private var action = AccountAction()
    @State private var current = ""
    @State private var password = ""
    @State private var confirmationPassword = ""
    @State private var enrolPassword = ""
    @State private var confirmation: String?
    @State private var missingAuthenticator = false

    var body: some View {
        Form {
            if app.isSignedIn {
                Section("account_change_password") {
                    SecureField("account_password_current", text: $current).textContentType(.password)
                    SecureField("account_password_new", text: $password).textContentType(.newPassword)
                    SecureField("account_password_confirm", text: $confirmationPassword).textContentType(.newPassword)
                    if !confirmationPassword.isEmpty && confirmationPassword != password { Text("account_password_mismatch").foregroundStyle(.red) }
                    if !password.isEmpty {
                        Text(LocalizedStringKey(password.utf16.count < 8 ? "account_password_strength_weak" : password.utf16.count < 12 ? "account_password_strength_fair" : "account_password_strength_strong"))
                    }
                    Button("account_password_update") { confirmation = "password" }
                        .disabled(action.blocked || !AccountInputState.validPassword(current: current, new: password, confirmation: confirmationPassword))
                }
                Section("account_two_factor_section") {
                    AccountStoreStatus(store: store) { reload() }
                    if let enabled = store.value.nativeBool("enabled") {
                        Text(LocalizedStringKey(enabled ? "account_two_factor_on_hint" : "account_two_factor_off_hint"))
                        SecureField("account_password_current", text: $enrolPassword).textContentType(.password)
                        Button(LocalizedStringKey(enabled ? "account_two_factor_rebind" : "account_two_factor_bind")) { confirmation = "twoFactor" }
                            .disabled(action.blocked || enrolPassword.isEmpty)
                    }
                    Text("account_two_factor_body")
                    Text("native.account.totp_boundary", tableName: "Account").font(.caption)
                    if missingAuthenticator { Text("account_two_factor_no_app").foregroundStyle(.red) }
                }
                AccountActionStatus(action: action)
            } else { AccountRequireSignIn() }
        }
        .disabled(action.state.phase == .writing || action.state.phase == .reading)
        .navigationTitle("account_security_title")
        .task(id: app.generation) { clear(); action.cancel(); await store.load(app, "account.twoFactor") }
        .onChange(of: scenePhase) { phase in if phase == .active { reload() } }
        .confirmationDialog(LocalizedStringKey(confirmation == "password" ? "account_confirm_password_title" : "account_confirm_2fa_title"),
                            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil; enrolPassword = "" } }), titleVisibility: .visible) {
            Button("action_done", role: .destructive) {
                let kind = confirmation; confirmation = nil
                if kind == "password" {
                    action.perform(app, operation: "account.changePassword", arguments: ["currentPassword": .string(current), "newPassword": .string(password), "confirmed": .bool(true)], read: {
                        _ = try await app.request("session.snapshot")
                        store.value = try await app.request("account.twoFactor")
                    }, received: { _ in clear() })
                } else if kind == "twoFactor" {
                    let secret = enrolPassword; enrolPassword = ""
                    action.perform(app, operation: "account.beginTwoFactor", arguments: ["password": .string(secret), "confirmed": .bool(true)], read: {
                        store.value = try await app.request("account.twoFactor")
                    }, received: { value in
                        guard let uri = value.nativeString("uri"), let url = URL(string: uri), url.scheme == "otpauth" else {
                            missingAuthenticator = true; return
                        }
                        // Enrolment URI is handed off once, never logged, copied or persisted.
                        UIApplication.shared.open(url, options: [:]) { opened in missingAuthenticator = !opened }
                    })
                }
            }
        } message: { Text(LocalizedStringKey(confirmation == "password" ? "account_confirm_password_body" : "account_confirm_2fa_body")) }
        .onDisappear { clear(); action.cancel() }
    }
    private func clear() { current = ""; password = ""; confirmationPassword = ""; enrolPassword = ""; confirmation = nil }
    private func reload() { Task { await store.load(app, "account.twoFactor") } }
}

struct AccountContactScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var contact = NativeStore()
    @StateObject private var telegram = NativeStore()
    @StateObject private var action = AccountAction()
    @State private var confirmation: String?
    @State private var browser: AccountBrowserChoice?
    var body: some View {
        Form {
            if app.isSignedIn {
                Section("account_email_section") {
                    AccountStoreStatus(store: contact) { reload() }
                    if let email = contact.value.nativeString("email") { LabeledContent("account_email_current", value: email).textSelection(.enabled) }
                    if contact.value.nativeBool("emailVerified") == true { Text("account_email_verified") }
                    Button("account_email_change") { browser = AccountBrowserChoice(url: "/setting#contact", goal: .manage) }
                }
                Section("account_telegram_section") {
                    AccountStoreStatus(store: telegram) { reload() }
                    if let bound = telegram.value.nativeBool("bound") {
                        Text(LocalizedStringKey(bound ? "account_telegram_bound" : "account_telegram_unbound"))
                        if let name = telegram.value.nativeString("displayName") { Text(name) }
                        if let avatar = telegram.value.nativeString("avatarUrl") { NativeRemoteImage(url: avatar).frame(width: 48, height: 48) }
                        Button(LocalizedStringKey(bound ? "account_telegram_unbind" : "account_telegram_bind")) { confirmation = bound ? "unbind" : "bind" }.disabled(action.blocked)
                    }
                    Button("account_telegram_refresh") { reload() }
                }
                Section("account_phone_section") { Text("account_phone_disabled_reason") }
                AccountActionStatus(action: action)
            } else { AccountRequireSignIn() }
        }
        .disabled(action.state.phase == .writing || action.state.phase == .reading)
        .navigationTitle("account_contact_title")
        .task(id: app.generation) { action.cancel(); confirmation = nil; browser = nil; await load() }
        .onChange(of: scenePhase) { if $0 == .active { reload() } }
        .sheet(item: $browser, onDismiss: { reload() }) { choice in
            NativeBrowser(url: choice.url, title: String(localized: "account_contact_title"), goal: choice.goal, onFinished: { reload() })
        }
        .confirmationDialog(LocalizedStringKey(confirmation == "unbind" ? "account_telegram_unbind_title" : "account_telegram_dialog_title"),
                            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            Button("action_done") {
                let kind = confirmation; confirmation = nil
                if kind == "bind" { browser = AccountBrowserChoice(goal: .telegramBind) }
                else { action.perform(app, operation: "account.unbindTelegram", arguments: ["confirmed": .bool(true)], read: {
                    telegram.value = try await app.request("account.telegram")
                }) }
            }
        }
        .onDisappear { action.cancel() }
    }
    private func load() async { await contact.load(app, "account.contact"); await telegram.load(app, "account.telegram") }
    private func reload() { Task { await load() } }
}
