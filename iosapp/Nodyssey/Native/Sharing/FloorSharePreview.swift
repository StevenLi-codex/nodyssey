import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct FloorSharePreview: View {
    @ObservedObject var session: FloorShareSession
    let original: FloorShareDocument
    let dark: Bool
    let generation: Int
    let close: () -> Void
    @State private var activity: ActivityItem?
    private var copy: FloorShareCopy { .init(language: original.language) }

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 16) {
                    if let document = session.document {
                        FloorShareCard(document: document, dark: dark)
                    }
                    if let failure = session.failure {
                        Text(verbatim: copy.message(for: failure)).foregroundStyle(.red)
                            .accessibilityIdentifier("sharing.failure")
                    }
                    if session.document == nil {
                        Button(copy.retry) { session.prepare(original, dark: dark, generation: generation) }
                    }
                }.padding()
            }
            .navigationTitle(copy.image)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(copy.close, action: close) }
                ToolbarItem(placement: .primaryAction) {
                    #if canImport(UIKit)
                    Button(copy.export) {
                        if let url = session.shareURL(generation: generation) { activity = ActivityItem(url: url) }
                    }
                    .disabled(session.document == nil)
                    .accessibilityIdentifier("sharing.export")
                    #else
                    // macOS verification/preview only. Shipping iOS uses the completion-aware activity below.
                    if let url = session.shareURL(generation: generation) { ShareLink(copy.export, item: url) }
                    #endif
                }
            }
            #if canImport(UIKit)
            .sheet(item: $activity, onDismiss: {
                // Also covers an interactive dismissal with no activity callback.
                if session.document != nil { session.finish(activityFailed: false) }
            }) { item in
                FloorShareActivity(url: item.url) { failed in
                    session.finish(activityFailed: failed)
                    activity = nil
                }
            }
            #endif
        }
    }

    private struct ActivityItem: Identifiable {
        let id = UUID()
        let url: URL
    }
}

#if canImport(UIKit)
/// Presented by SwiftUI's sheet, including on iPad; no global top-controller lookup/popover hack.
private struct FloorShareActivity: UIViewControllerRepresentable {
    let url: URL
    let completion: @MainActor (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, error in
            let failed = error != nil
            Task { @MainActor in completion(failed) }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
#endif
