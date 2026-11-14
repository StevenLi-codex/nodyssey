import SwiftUI
import NodysseyNativeCore

struct ContentShareLink: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    let postID: Int64
    let page: Int64
    var floor: String? = nil
    /// Parent must pass the actual loaded DTO + title at a floor action; never fetch a second copy.
    /// Omitting this retains link sharing and visibly explains why image sharing is unavailable.
    var shareContext: FloorShareContext? = nil
    @StateObject private var site = NativeStore()
    @StateObject private var imageSession = FloorShareSession()
    @State private var retry = 0
    @State private var preview: Preview?
    @State private var imageFailure: FloorShareError?
    private var language: FloorShareLanguage { .init(locale: locale) }
    private var copy: FloorShareCopy { .init(language: language) }
    private var origin: String? {
        guard let current = site.value.nativeString("current") else { return nil }
        return site.value.nativeArray("sites").first(where: { $0.nativeString("id") == current })?.nativeString("origin")
    }
    private var url: URL? {
        guard let origin else { return nil }
        return try? FloorShareDocument.sourceURL(origin: origin, postID: postID, page: page, floor: floor)
    }
    var body: some View {
        Group {
            if let url {
                Menu {
                    ShareLink(copy.link, item: url)
                    Button(copy.image, action: prepareImage)
                        .accessibilityIdentifier("sharing.floorImage")
                } label: { Label(copy.share, systemImage: "square.and.arrow.up") }
            } else if let failure = site.failure {
                NativeFailureView(failure: failure, retry: { retry += 1 })
            } else if site.value != .null {
                Text(verbatim: copy.invalid)
            } else { ProgressView() }
        }
        .task(id: "\(app.generation)|\(retry)") { await site.load(app, "site.get") }
        .sheet(item: $preview, onDismiss: { imageSession.clear() }) { selected in
            FloorSharePreview(session: imageSession, original: selected.document, dark: selected.dark,
                              generation: selected.generation, close: { preview = nil })
        }
        .alert(copy.image, isPresented: Binding(get: { imageFailure != nil }, set: { if !$0 { imageFailure = nil } })) {
            Button(copy.close, role: .cancel) { imageFailure = nil }
        } message: { Text(verbatim: copy.message(for: imageFailure ?? .renderFailed)) }
        .onChange(of: app.generation) { _ in invalidate() }
        .onChange(of: shareContext) { _ in invalidate() }
        .onChange(of: url) { _ in invalidate() }
        .onDisappear { invalidate() }
    }

    private func prepareImage() {
        do {
            guard let shareContext, let origin else { throw FloorShareError.missingContext }
            let document = try FloorShareDocument.make(context: shareContext, postID: postID, page: page,
                                                       floor: floor, origin: origin, language: language)
            let dark = colorScheme == .dark
            imageSession.prepare(document, dark: dark, generation: app.generation)
            if let failure = imageSession.failure { throw failure }
            preview = Preview(document: document, dark: dark, generation: app.generation)
        } catch { imageFailure = error as? FloorShareError ?? .renderFailed }
    }

    private func invalidate() {
        preview = nil
        imageFailure = nil
        imageSession.clear()
    }

    private struct Preview: Identifiable {
        let id = UUID()
        let document: FloorShareDocument
        let dark: Bool
        let generation: Int
    }
}
