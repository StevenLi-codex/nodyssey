import SwiftUI
import NodysseyNativeCore
import NodysseyShell

struct AccountSignInScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var form = AccountAuthState()
    @State private var failure: NativeFailure?
    @State private var task: Task<Void, Never>?
    @State private var resetSignal = 0
    @State private var browser: AccountBrowserChoice?
    @State private var oneTapAvailable = false
    @State private var platformRequest: NativeRequest?

    var body: some View {
        Form {
            if form.challenge == nil {
                Text("sign_in_subtitle")
                TextField("sign_in_account", text: $form.account)
                    .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("native.signin.account").disabled(form.busy)
                SecureField("sign_in_password", text: $form.password).textContentType(.password)
                    .accessibilityIdentifier("native.signin.password").disabled(form.busy)
                NativeTurnstile(darkTheme: colorScheme == .dark, resetSignal: resetSignal,
                    onToken: { form.token = $0 }, onExpired: { form.token = "" },
                    onUnavailable: { form.token = ""; failure = NativeFailure(code: "CHALLENGE", message: "") })
                    .frame(minHeight: 85)
                Button("sign_in_submit") { submit() }.disabled(!form.canSubmit)
            } else {
                Text("sign_in_2fa_title").font(.headline)
                Text(form.account)
                TextField("account_two_factor_totp", text: $form.code)
                    .textContentType(.oneTimeCode).keyboardType(.numberPad).disabled(form.busy)
                Button("sign_in_2fa_submit") { submit() }.disabled(!form.canSubmit)
                Button("action_cancel") { cancelAuth() }
            }
            if form.busy { ProgressView() }
            if let failure { NativeFailureView(failure: failure) }
            Section {
                Button("sign_in_use_web") { openBrowser(.login) }
                Button("sign_in_forgot") { openBrowser(.login) }
                Button("sign_in_register_hint") { openBrowser(.login) }
                if oneTapAvailable {
                    Button { openBrowser(.oneTapLogin) } label: { Text("native.account.one_tap", tableName: "Account") }
                }
                Button("sign_in_terms") { app.open("Privacy") }
            }.disabled(form.busy)
        }
        .navigationTitle("action_sign_in")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("action_cancel") { cancelAuth(); dismiss() }.accessibilityIdentifier("native.signin.cancel") } }
        .sheet(item: $browser) { choice in
            NativeBrowser(url: "", title: String(localized: "action_sign_in"), goal: choice.goal, onFinished: {
                if app.isSignedIn { dismiss() }
            })
        }
        .onAppear {
            platformRequest = NativePlatform.shared.ready { context, _ in oneTapAvailable = context?.oneTapSignInPath != nil }
        }
        .onChange(of: app.generation) { _ in
            // Browser startup rotates the private epoch before WebKit loads.
            // It owns its cancellation/drain; don't cancel or dismiss its parent.
            guard !app.ownsAuthenticationPresentation else { return }
            cancelAuth(); if app.isSignedIn { dismiss() }
        }
        .onDisappear { platformRequest?.cancel(); cancelAuth() }
    }
    private func submit() {
        let challenge = form.challenge
        let args: [String: JSONValue] = challenge.map { ["challengeId": .string($0), "code": .string(form.code)] }
            ?? ["account": .string(form.account), "password": .string(form.password), "verificationToken": .string(form.token)]
        guard let ticket = form.begin() else { return }
        failure = nil
        task = Task {
            do {
                let result = try await app.request(challenge == nil ? "session.signIn" : "session.verifyTwoFactor", args)
                guard !Task.isCancelled, form.accepts(ticket) else { return }
                switch result.nativeString("status") {
                case "SIGNED": form.cancel(); dismiss()
                case "TWO_FACTOR_REQUIRED":
                    guard let handle = result.nativeString("challengeId"), form.acceptChallenge(handle, ticket: ticket) else {
                        form.failed(ticket); failure = NativeFailure(code: "INVALID_DATA", message: ""); return
                    }
                default:
                    form.failed(ticket); resetSignal += 1
                    failure = NativeFailure(code: "REFUSED", message: "")
                }
            } catch {
                guard !Task.isCancelled, form.accepts(ticket) else { return }
                if (error as? NativeFailure)?.code == "SIGN_IN_SUPERSEDED" { form.cancel() }
                else { form.failed(ticket) }
                resetSignal += 1; failure = accountFailure(error)
            }
        }
    }
    private func cancelAuth() {
        task?.cancel(); task = nil; form.cancel(); resetSignal += 1
        // Cleanup intentionally outlives screen disappearance. Never sync in the OTP lifecycle.
        Task { do { _ = try await app.request("session.cancelSignIn") } catch { /* No success is published for cleanup. */ } }
    }
    private func openBrowser(_ goal: NativeBrowserGoal) {
        task?.cancel(); form.cancel()
        task = Task {
            do {
                _ = try await app.request("session.cancelSignIn")
                try Task.checkCancellation()
                browser = AccountBrowserChoice(goal: goal)
            } catch { if !Task.isCancelled { failure = accountFailure(error) } }
        }
    }
}

struct AccountBrowserChoice: Identifiable {
    let id = UUID()
    var url = ""
    let goal: NativeBrowserGoal
}
