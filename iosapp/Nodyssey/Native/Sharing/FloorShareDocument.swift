import Foundation
import NodysseyNativeCore

/// Only a loaded floor DTO, never a feed preview or a reconstructed editor excerpt.
struct FloorShareContext: Equatable, Sendable {
    let content: JSONValue
    let threadTitle: String
    var openingPost = false
    var revealedBlocked = false
}

enum FloorShareError: Error, Equatable {
    case missingContext, invalidSource, invalidContent, blockedContent, renderFailed
}

enum FloorShareLanguage: Sendable {
    case english, simplifiedChinese, traditionalChinese

    init(locale: Locale) {
        let tag = locale.identifier.lowercased().replacingOccurrences(of: "_", with: "-")
        if tag.hasPrefix("en") { self = .english }
        else if tag.hasPrefix("zh") && (tag.contains("hant") || tag.contains("-tw") || tag.contains("-hk") || tag.contains("-mo")) { self = .traditionalChinese }
        else { self = .simplifiedChinese }
    }
}

struct FloorShareDocument: Equatable, Sendable {
    let author: String
    let floor: String
    let title: String
    let createdAt: String?
    let source: URL
    let body: String
    let truncated: Bool
    let language: FloorShareLanguage

    static func sourceURL(origin: String, postID: Int64, page: Int64, floor: String?) throws -> URL {
        guard postID > 0, var url = URLComponents(string: origin), url.scheme == "https",
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { throw FloorShareError.invalidSource }
        url.path = "/post-\(postID)-\(max(1, page))"
        url.query = nil
        url.fragment = floor.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
        guard let result = url.url else { throw FloorShareError.invalidSource }
        return result
    }

    static func make(context: FloorShareContext, postID: Int64, page: Int64, floor: String?, origin: String, language: FloorShareLanguage) throws -> Self {
        let value = context.content
        guard let author = value["authorName"]?.string, !author.isEmpty, !context.threadTitle.isEmpty,
              let label = value["floor"]?.string ?? (context.openingPost ? "#0" : nil),
              let raw = value["nodes"], raw.array != nil else { throw FloorShareError.missingContext }
        let nodes: [NativeRichNode]
        do { nodes = try JSONDecoder().decode([NativeRichNode].self, from: JSONEncoder().encode(raw)) }
        catch { throw FloorShareError.invalidContent }
        guard !label.isEmpty, floor == nil || floor == label || floor == String(label.drop(while: { $0 == "#" })) else { throw FloorShareError.invalidContent }
        guard value["isBlocked"]?.bool != true || context.revealedBlocked else { throw FloorShareError.blockedContent }
        var projection = FloorShareProjection(copy: .init(language: language))
        projection.blocks(nodes)
        return Self(author: author, floor: label, title: context.threadTitle,
                    createdAt: value["createdAtTitle"]?.string ?? value["createdAtText"]?.string,
                    source: try sourceURL(origin: origin, postID: postID, page: page, floor: label),
                    body: projection.text, truncated: projection.truncated, language: language)
    }
}
