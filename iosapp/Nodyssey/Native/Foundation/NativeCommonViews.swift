import SwiftUI
import NodysseyNativeCore

struct NativeBusyView: View {
    var body: some View {
        ProgressView("loading_indicator_label").frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

struct NativeEmptyView: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray").font(.largeTitle).accessibilityHidden(true)
            Text(LocalizedStringKey(title)).multilineTextAlignment(.center)
        }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
    }
}

struct NativeFailureView: View {
    let failure: NativeFailure
    var retry: (() -> Void)? = nil
    @EnvironmentObject private var app: NativeAppModel
    private var presentation: NativeFailurePresentation { NativeFailurePresentation(code: failure.code) }
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
            Text(LocalizedStringKey(presentation.titleKey), tableName: presentation.titleKey.hasPrefix("native_foundation_") ? "Foundation" : nil).font(.headline).multilineTextAlignment(.center)
            // Never render failure.message: arbitrary NSError/server text can contain secrets.
            switch presentation.recovery {
            case .signIn:
                Button("action_sign_in") { app.showSignIn() }.modifier(NativeActionStyle())
            case .challenge:
                Button("action_verify") {
                    app.open("Web", ["url": .string(app.siteOrigin ?? ""), "goal": .string("CHALLENGE")])
                }.modifier(NativeActionStyle())
            case .retry:
                if let retry { Button("action_retry", action: retry).modifier(NativeActionStyle()) }
            case .none: EmptyView()
            }
        }.frame(maxWidth: .infinity).padding().accessibilityElement(children: .contain)
    }
}

/// System glass for actions only. Body content remains on system list/form surfaces.
struct NativeActionStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *), !reduceTransparency {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
