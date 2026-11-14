import SwiftUI

// Signature-only stand-in for macOS typechecking. NEVER an app target or runtime test.
// The real implementation requires iOS/UIKit, Photos and the Kotlin framework.
struct NativeRemoteImage: View {
    let url: String
    var aspectFit: Bool = true
    var body: some View { EmptyView() }
}
