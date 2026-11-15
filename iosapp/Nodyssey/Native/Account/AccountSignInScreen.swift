import SwiftUI
import NodysseyNativeCore
import NodysseyShell

struct AccountSignInScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var auth = AccountAuthSubmission()
    @State private var task: Task<Void, Never>?
    @State private var browser: AccountBrowserChoice?
    @State private var oneTapAvailable = false
    @State private var platformRequest: NativeRequest?

    var body: some View {
        Form {
            if auth.form.challenge == nil {
                Text("sign_in_subtitle")
                TextField("sign_in_account", text: $auth.form.account)
                    .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("native.signin.account").disabled(auth.form.busy)
                SecureField("sign_in_password", text: $auth.form.password).textContentType(.password)
                    .accessibilityIdentifier("native.signin.password").disabled(auth.form.busy)
                NativeTurnstile(darkTheme: colorScheme == .dark, resetSignal: auth.resetSignal,
                    onToken: { auth.form.token = $0 }, onExpired: { auth.form.token = "" },
                    onUnavailable: { auth.form.token = ""; auth.failure = NativeFailure(code: "CHALLENGE", message: "") })
                    .frame(minHeight: 85)
                Button("sign_in_submit") { submit() }.disabled(!auth.form.canSubmit)
            } else {
                Text("sign_in_2fa_title").font(.headline)
                Text(auth.form.account)
                TextField("account_two_factor_totp", text: $auth.form.code)
                    .textContentType(.oneTimeCode).keyboardType(.numberPad).disabled(auth.form.busy)
                Button("sign_in_2fa_submit") { submit() }.disabled(!auth.form.canSubmit)
                Button("action_cancel") { cancelAuth() }
            }
            if auth.form.busy { ProgressView() }
            if let failure = auth.failure { NativeFailureView(failure: failure) }
            Section {
                Button("sign_in_use_web") { openBrowser(.login) }
                Button("sign_in_forgot") { openBrowser(.login) }
                Button("sign_in_register_hint") { openBrowser(.login) }
                if oneTapAvailable {
                    Button { openBrowser(.oneTapLogin) } label: { Text("native.account.one_tap", tableName: "Account") }
                }
                Button("sign_in_terms") { app.open("Privacy") }
            }.disabled(auth.form.busy)
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
            // Native submit and browser startup rotate the private epoch before
            // completion. Their public lease owns cancellation/drain across it.
            guard !app.ownsAuthenticationPresentation else { return }
            cancelAuth(); if app.isSignedIn { dismiss() }
        }
        .onDisappear { platformRequest?.cancel(); cancelAuth() }
    }
    private func submit() {
        auth.submit(app: app, onSigned: { dismiss() })
    }
    private func cancelAuth() {
        task?.cancel(); task = nil
        auth.cancel(app: app)
    }
    private func openBrowser(_ goal: NativeBrowserGoal) {
        task?.cancel()
        let cleanup = auth.cancel(app: app)
        task = Task {
            await cleanup?.value
            guard !Task.isCancelled else { return }
            browser = AccountBrowserChoice(goal: goal)
        }
    }
}

struct AccountBrowserChoice: Identifiable {
    let id = UUID()
    var url = ""
    let goal: NativeBrowserGoal
}
