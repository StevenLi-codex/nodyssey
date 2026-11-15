import SwiftUI

/// Public recovery surface: unknown provenance never mounts private factories.
struct NativePrivateBoundaryRecoveryView: View {
    @EnvironmentObject private var app: NativeAppModel
    @State private var refreshing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "lock.shield").font(.largeTitle).accessibilityHidden(true)
                Text(LocalizedStringKey(app.isSignedIn ? "native_foundation_boundary_signed_in" : "native_foundation_boundary_title"), tableName: "Foundation").font(.headline)
                Text("native_foundation_boundary_detail", tableName: "Foundation")
                if app.isSignedIn {
                    Text("native_foundation_boundary_signed_in_detail", tableName: "Foundation")
                }
                if (app.privateBoundary.nativeString("phase") == "TRANSITIONING" &&
                    app.privateBoundary.nativeBool("recoveryEligible") != true) || app.privateResetRunning {
                    ProgressView()
                    Text("native_foundation_boundary_transition", tableName: "Foundation")
                }
                if app.privateBoundaryFailure != nil {
                    // Never render arbitrary bridge detail, epoch, cookie or owner proof.
                    Text("native_foundation_boundary_failed", tableName: "Foundation")
                }
                Button {
                    refreshing = true
                    Task { await app.refreshPrivateBoundary(); refreshing = false }
                } label: { Text("native_foundation_boundary_refresh", tableName: "Foundation") }
                .disabled(refreshing || app.privateResetRunning)
                .accessibilityIdentifier("native.boundary.refresh")
                Button { app.open("Settings") } label: {
                    Text("native_foundation_boundary_settings", tableName: "Foundation")
                }.accessibilityIdentifier("native.boundary.settings")
                Button("action_sign_in") { app.showSignIn() }
                    .accessibilityIdentifier("native.boundary.signin")
                if app.canConfirmPrivateReset {
                    Button(role: .destructive) { app.beginPrivateResetConfirmation() } label: {
                        Text("native_foundation_boundary_review_reset", tableName: "Foundation")
                    }.accessibilityIdentifier("native.boundary.reviewReset")
                }
            }
            .multilineTextAlignment(.center)
            .padding()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("native.boundary.recovery")
    }
}
