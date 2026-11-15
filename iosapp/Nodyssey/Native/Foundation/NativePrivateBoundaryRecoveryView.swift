import SwiftUI

/// Temporary request-lifetime transition, not an ownership lock or data recovery workflow.
struct NativePrivateBoundaryRecoveryView: View {
    @EnvironmentObject private var app: NativeAppModel
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            if let failure = app.privateBoundaryFailure {
                NativeFailureView(failure: failure, retry: {
                    Task { await app.foreground(); await app.refreshPrivateBoundary() }
                })
            }
        }.padding()
    }
}
