import SwiftUI
import NodysseyNativeCore

/// Local transient action state only; Kotlin remains the repository and queue owner.
@MainActor final class MediaAction: ObservableObject {
    @Published var busy = false
    @Published var failure: NativeFailure?
    @Published var notice: String?
    private var task: Task<Void, Never>?
    private var revision = UUID()

    func run(_ app: NativeAppModel, work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; failure = nil; notice = nil
        let generation = app.generation
        let token = UUID(); revision = token
        task = Task { @MainActor in
            defer { if revision == token { busy = false; task = nil } }
            do {
                try await work()
                try Task.checkCancellation()
                guard generation == app.generation, token == revision else { return }
            } catch is CancellationError {
            } catch {
                guard generation == app.generation, token == revision, !Task.isCancelled else { return }
                failure = error as? NativeFailure ?? NativeFailure(code: "INTERNAL", message: "Operation could not be completed.")
            }
        }
    }

    func request(_ app: NativeAppModel, _ operation: String, _ arguments: [String: JSONValue] = [:],
                 refresh: String? = "stickers.get", completion: @escaping @MainActor (JSONValue) -> Void = { _ in }) {
        run(app) {
            let generation = app.generation
            let result = try await app.request(operation, arguments)
            if let refresh { _ = try await app.request(refresh) }
            try Task.checkCancellation()
            guard generation == app.generation else { return }
            completion(result)
        }
    }

    func cancel() { revision = UUID(); task?.cancel(); task = nil; busy = false; failure = nil; notice = nil }
}

enum MediaL {
    static func text(_ key: String) -> String { NSLocalizedString(key, tableName: "Media", bundle: .main, value: key, comment: "") }
}

struct MediaFeedback: View {
    @ObservedObject var action: MediaAction
    var body: some View {
        if action.busy { ProgressView() }
        if let failure = action.failure { NativeFailureView(failure: failure) }
        if let notice = action.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
    }
}

struct MediaImagePresentation: Identifiable {
    let id = UUID()
    let urls: [String]
    let index: Int
}

struct MediaRows: Identifiable {
    let id: String
    let value: JSONValue
    static func from(_ rows: [JSONValue], key: String) -> [Self] {
        rows.compactMap { row in row[key]?.string.map { .init(id: $0, value: row) } }
    }
}

struct MediaStickerCell: View {
    let sticker: MediaSticker
    var body: some View {
        HStack {
            if let url = sticker.url { NativeRemoteImage(url: url, aspectFit: true).frame(width: 48, height: 48).allowsHitTesting(false) }
            else { Text(sticker.insertion).font(.largeTitle).frame(width: 48) }
            Text(sticker.name).lineLimit(2)
        }.accessibilityElement(children: .combine)
    }
}

struct MediaTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText] }
    var text: String
    init(text: String = "") { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= 8 * 1024 * 1024,
              let value = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        text = value
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

import UniformTypeIdentifiers
