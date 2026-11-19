import Foundation
import NodysseyNativeCore

/// Owns copies of picker grants, not a second media repository. No decoding or upload occurs here.
struct MediaUploadFileStager: Sendable {
    let directory: URL
    let byteLimit: Int
    init(directory: URL, byteLimit: Int = 64 * 1024 * 1024) throws {
        self.directory = directory; self.byteLimit = byteLimit
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func copy(_ source: URL) throws -> URL {
        guard source.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let resource = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard resource.isRegularFile == true, let size = resource.fileSize, size > 0, size <= byteLimit else { throw CocoaError(.fileReadTooLarge) }
        let target = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }
}

struct MediaLinkPreview: Identifiable, Sendable {
    var id: String { url }
    let url: String
    var name: String
    var selected = true
    static func parse(_ text: String) -> [Self] {
        // Same link grammar as shared StickerModels.extractStickerLinks; final add validates in Kotlin.
        guard let regex = try? NSRegularExpression(pattern: #"https://[^\s<>"'()\[\]]+"#) else { return [] }
        var seen: Set<String> = []
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let url = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,)>\"'"))
            guard seen.insert(url).inserted else { return nil }
            let path = url.components(separatedBy: "?")[0].components(separatedBy: "#")[0].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let file = path.components(separatedBy: "/").last ?? ""
            let name = (file as NSString).deletingPathExtension
            return .init(url: url, name: name.isEmpty ? "sticker" : String(name.prefix(20)))
        }
    }
}

struct MediaSubscriptionDraft: Sendable {
    private(set) var listing: JSONValue = .null
    private(set) var inspectedURL: String?
    var selected: Set<String> = []
    var folders: [JSONValue] { listing["folders"]?.array ?? [] }
    mutating func accept(_ listing: JSONValue, url: String) throws {
        guard let sha = listing["sha"]?.string, !sha.isEmpty, listing["folders"]?.array != nil else {
            throw NativeFailure(code: "INVALID_DATA", message: "Invalid repository listing.")
        }
        self.listing = listing; inspectedURL = url
        selected = Set(folders.compactMap { $0["path"]?.string })
    }
    mutating func invalidate() { listing = .null; inspectedURL = nil; selected = [] }
    func arguments(currentURL: String) throws -> [String: JSONValue] {
        let available = Set(folders.compactMap { $0["path"]?.string })
        guard inspectedURL == currentURL, let sha = listing["sha"]?.string,
              !selected.isEmpty, selected.isSubset(of: available) else {
            throw NativeFailure(code: "SOURCE_CHANGED", message: "Inspect and select folders again.")
        }
        return ["url": .string(currentURL), "expectedSha": .string(sha), "paths": .array(folders.compactMap { $0["path"]?.string }.filter { selected.contains($0) }.map(JSONValue.string))]
    }
}

struct MediaHostedImage: Identifiable, Sendable {
    let id: String
    let url: String
    let name: String
    let mimeType: String?
    init?(_ value: JSONValue) {
        guard let id = value["id"]?.string, let url = value["url"]?.string else { return nil }
        self.id = id; self.url = url; name = value["fileName"]?.string ?? url
        mimeType = value["mimeType"]?.string
    }
    var isGIF: Bool { mimeType == "image/gif" || URL(string: url)?.pathExtension.lowercased() == "gif" }
}

/// Deletion permission is tied to the provider and the exact displayed listing revision.
@MainActor final class MediaHostService {
    struct Confirmation: Sendable { fileprivate let provider: String; fileprivate let id: String; fileprivate let revision: UUID }
    let transport: any NativeTransport
    private(set) var images: [MediaHostedImage] = []
    private var provider: String?
    private var revision = UUID()
    private var deleting = false
    init(transport: any NativeTransport) { self.transport = transport }

    @discardableResult func list(provider: String) async throws -> [MediaHostedImage] {
        let capabilities = try await transport.request("settings.capabilities", [:])
        guard capabilities["imageHosts"]?.array?.contains(where: { $0["provider"]?.string == provider && $0["browsable"]?.bool == true }) == true else {
            throw NativeFailure(code: "UNSUPPORTED", message: "This provider has no gallery.")
        }
        try await requireSelected(provider)
        let value = try await transport.request("imageHost.images", ["expectedProvider": .string(provider)])
        try await requireSelected(provider)
        try Task.checkCancellation()
        guard let rows = value.array else { throw NativeFailure(code: "INVALID_DATA", message: "Invalid image list.") }
        images = rows.compactMap(MediaHostedImage.init)
        self.provider = provider; revision = UUID()
        return images
    }

    func confirmation(for id: String) throws -> Confirmation {
        guard let provider, images.contains(where: { $0.id == id }) else {
            throw NativeFailure(code: "INVALID_ARGUMENT", message: "Image is no longer listed.")
        }
        return .init(provider: provider, id: id, revision: revision)
    }

    func deleteConfirmed(_ confirmation: Confirmation) async throws {
        guard !deleting else { throw NativeFailure(code: "BUSY", message: "Operation in progress.") }
        guard confirmation.revision == revision, confirmation.provider == provider else {
            throw NativeFailure(code: "INVALID_ARGUMENT", message: "Confirm the current image again.")
        }
        deleting = true; defer { deleting = false }
        try await requireSelected(confirmation.provider)
        _ = try await transport.request("imageHost.delete", ["id": .string(confirmation.id), "expectedProvider": .string(confirmation.provider)])
        _ = try await list(provider: confirmation.provider)
    }

    private func requireSelected(_ provider: String) async throws {
        let current = try await transport.request("imageHost.get", [:])
        guard current["provider"]?.string == provider else {
            throw NativeFailure(code: "SOURCE_CHANGED", message: "Image host changed. Reload before continuing.")
        }
    }
}

struct MediaSticker: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let url: String?
    let insertion: String
    init?(_ value: JSONValue) {
        if let character = value["character"]?.string {
            id = character; name = character; url = nil; insertion = character
        } else if let url = value["url"]?.string, !url.isEmpty {
            id = url; self.url = url; name = value["name"]?.string ?? ""
            let escapedName = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "\n", with: " ")
            let target = url.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: " ", with: "%20")
            insertion = value["shortcode"]?.string ?? "![\(escapedName)](\(target))"
        } else { return nil }
    }
}

/// Browsing previews; only the editor picker inserts. Selection is an explicit browser mode.
struct MediaStickerInteraction: Sendable {
    enum Mode: Sendable { case browser, picker }
    enum Effect: Equatable { case none, preview(MediaSticker), insert(String) }
    let mode: Mode
    private(set) var selecting = false
    private(set) var selection: Set<String> = []

    mutating func activate(_ sticker: MediaSticker) -> Effect {
        if mode == .picker { return .insert(sticker.insertion) }
        guard sticker.url != nil else { return .none }
        if selecting {
            if !selection.insert(sticker.id).inserted { selection.remove(sticker.id) }
            return .none
        }
        return .preview(sticker)
    }
    mutating func beginSelection() { if mode == .browser { selecting = true } }
    mutating func endSelection() { selecting = false; selection = [] }
    mutating func selectAll(_ entries: [MediaSticker]) {
        guard mode == .browser else { return }
        selecting = true; selection = Set(entries.filter { $0.url != nil }.map(\.id))
    }
    mutating func reconcile(_ entries: [MediaSticker]) {
        selection.formIntersection(Set(entries.filter { $0.url != nil }.map(\.id)))
    }
}

struct MediaStickerGroup: Identifiable, Sendable {
    let id: String
    let name: String
    let hidden: Bool
    let slug: String?
    let path: String?
    let entries: [MediaSticker]

    static func groups(_ snapshot: JSONValue) -> [Self] {
        guard snapshot.object != nil else { return [] }
        let hidden = Set(snapshot["groupLayout"]?["hidden"]?.array?.compactMap(\.string) ?? [])
        var groups: [Self] = [.init(id: "mine", name: "mine", hidden: hidden.contains("mine"), slug: nil, path: nil,
                                   entries: (snapshot["mine"]?.array ?? []).compactMap(MediaSticker.init))]
        for subscription in snapshot["subscriptions"]?.array ?? [] {
            guard let slug = subscription["slug"]?.string else { continue }
            for folder in subscription["folders"]?.array ?? [] {
                guard let key = folder["key"]?.string, let path = folder["path"]?.string else { continue }
                groups.append(.init(id: key, name: folder["name"]?.string ?? path, hidden: folder["hidden"]?.bool ?? false,
                                    slug: slug, path: path, entries: (folder["entries"]?.array ?? []).compactMap(MediaSticker.init)))
            }
        }
        for site in snapshot["siteGroups"]?.array ?? [] {
            guard let key = site["key"]?.string else { continue }
            groups.append(.init(id: key, name: key, hidden: hidden.contains(key), slug: nil, path: nil,
                                entries: (site["entries"]?.array ?? []).compactMap(MediaSticker.init)))
        }
        let order = snapshot["arrangedGroupKeys"]?.array?.compactMap(\.string) ?? groups.map(\.id)
        return order.compactMap { key in groups.first { $0.id == key } }
    }
}

/// Editor-only projection: collections remain in the management catalogue and storage.
struct MediaStickerPickerContent: Sendable {
    let groups: [MediaStickerGroup]
    let selectionKey: String
    var entries: [MediaSticker] { groups.first { $0.id == selectionKey }?.entries ?? [] }

    init(snapshot: JSONValue, selectedKey: String?) {
        groups = MediaStickerGroup.groups(snapshot).filter { $0.id != "mine" && !$0.hidden }
        if let selectedKey, groups.contains(where: { $0.id == selectedKey }) {
            selectionKey = selectedKey
        } else {
            selectionKey = groups.first(where: { $0.slug == nil })?.id ?? groups.first?.id ?? ""
        }
    }
}

/// Masked read-back values are never submitted as replacement credentials.
enum MediaSecretEdit: Equatable, Sendable {
    case preserve, clear, replace(String)
    var value: JSONValue? {
        switch self {
        case .preserve: return nil
        case .clear: return .string("")
        case .replace(let value): return .string(value)
        }
    }
}

struct MediaHostDraft: Sendable {
    let provider: String
    var siteURL: String
    var fileField: String
    var headerName: String
    var urlPath: String
    var urlPrefix: String
    var token: MediaSecretEdit = .preserve
    var headerValue: MediaSecretEdit = .preserve
    var formFields: MediaSecretEdit = .preserve

    init(provider: String, snapshot: JSONValue) {
        self.provider = provider
        siteURL = snapshot["siteUrl"]?.string ?? ""
        fileField = snapshot["custom"]?["fileField"]?.string ?? "file"
        headerName = snapshot["custom"]?["headerName"]?.string ?? ""
        urlPath = snapshot["custom"]?["urlPath"]?.string ?? ""
        urlPrefix = snapshot["custom"]?["urlPrefix"]?.string ?? ""
    }

    func arguments() throws -> [String: JSONValue] {
        var args: [String: JSONValue] = ["provider": .string(provider), "siteUrl": .string(siteURL)]
        args["token"] = token.value
        if provider == "CUSTOM" {
            var custom: [String: JSONValue] = ["fileField": .string(fileField), "headerName": .string(headerName), "urlPath": .string(urlPath), "urlPrefix": .string(urlPrefix)]
            custom["headerValue"] = headerValue.value
            custom["formFields"] = formFields.value
            args["custom"] = .object(custom)
        }
        return args
    }
}
