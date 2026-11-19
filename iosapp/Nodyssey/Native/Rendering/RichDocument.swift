import Foundation

/// A renderer must never hand an executable URL to a global system opener.
/// Relative site paths/floors are handed unchanged to the injected navigation owner.
public enum NativeRichLinkPolicy {
    public static func isAllowed(_ raw: String) -> Bool {
        guard !raw.isEmpty,
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.rangeOfCharacter(from: .controlCharacters) == nil,
              !raw.contains("\\"),
              let components = URLComponents(string: raw) else { return false }
        guard let scheme = components.scheme?.lowercased() else {
            return (raw.hasPrefix("/") && !raw.hasPrefix("//")) || raw.hasPrefix("#")
        }
        switch scheme {
        case "https", "http":
            return components.host?.isEmpty == false && components.user == nil && components.password == nil
        case "mailto": return !components.path.isEmpty
        default: return false
        }
    }
}

/// Wrap opportunities for the native media/text flow. Never split a composed character.
/// Ordinary text-only paragraphs use Text's native attributed-string layout instead.
public enum NativeInlineFlow {
    /// Presentation-only tokens; canonical nodes and media/action payloads stay unchanged.
    public static func project(_ inlines: [NativeInlineNode]) -> [NativeInlineNode] {
        inlines.flatMap { node -> [NativeInlineNode] in
            switch node {
            case let .text(text, style):
                return tokens(text).map { $0.unicodeScalars.contains { $0 == "\n" || $0 == "\r" } ? .lineBreak : .text($0, style) }
            case let .link(text, url, style):
                return tokens(text).map { $0.unicodeScalars.contains { $0 == "\n" || $0 == "\r" } ? .lineBreak : .link($0, url, style) }
            default: return [node]
            }
        }
    }

    public static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var word = ""
        func flush() {
            if !word.isEmpty { result.append(word); word = "" }
        }
        for character in text {
            let value = character.unicodeScalars.first?.value ?? 0
            let isCJK = (0x2E80...0xA4CF).contains(value) || (0xAC00...0xD7AF).contains(value)
                || (0xF900...0xFAFF).contains(value) || (0x20000...0x323AF).contains(value)
            let isEmoji = character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
            if character.isWhitespace || isCJK || isEmoji {
                flush()
                result.append(String(character))
            } else {
                word.append(character)
            }
        }
        flush()
        return result
    }
}

/// Mirrors kotlinx.serialization's tagged RichNode JSON, independently of the bridge transport.
public struct NativeInlineStyle: Codable, Equatable, Sendable {
    public var bold: Bool
    public var italic: Bool
    public var strikethrough: Bool
    public var code: Bool

    public init(bold: Bool = false, italic: Bool = false, strikethrough: Bool = false, code: Bool = false) {
        self.bold = bold
        self.italic = italic
        self.strikethrough = strikethrough
        self.code = code
    }

    private enum CodingKeys: String, CodingKey { case bold, italic, strikethrough, code }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        strikethrough = try c.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? false
        code = try c.decodeIfPresent(Bool.self, forKey: .code) ?? false
    }
}

public enum NativeInlineNode: Codable, Equatable, Sendable {
    case text(String, NativeInlineStyle)
    case link(String, String, NativeInlineStyle)
    case sticker(url: String, alt: String?)
    case image(url: String, alt: String?)
    case quoteRef(name: String, floor: String, url: String)
    case lineBreak

    private enum CodingKeys: String, CodingKey { case type, text, url, style, alt, name, floor }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "t": self = .text(try c.decode(String.self, forKey: .text), try c.decodeIfPresent(NativeInlineStyle.self, forKey: .style) ?? .init())
        case "a": self = .link(try c.decode(String.self, forKey: .text), try c.decode(String.self, forKey: .url), try c.decodeIfPresent(NativeInlineStyle.self, forKey: .style) ?? .init())
        case "sticker": self = .sticker(url: try c.decode(String.self, forKey: .url), alt: try c.decodeIfPresent(String.self, forKey: .alt))
        case "iimg": self = .image(url: try c.decode(String.self, forKey: .url), alt: try c.decodeIfPresent(String.self, forKey: .alt))
        case "qref": self = .quoteRef(name: try c.decode(String.self, forKey: .name), floor: try c.decode(String.self, forKey: .floor), url: try c.decode(String.self, forKey: .url))
        case "br": self = .lineBreak
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown inline node discriminator")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text, style):
            try c.encode("t", forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encode(style, forKey: .style)
        case let .link(text, url, style):
            try c.encode("a", forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encode(url, forKey: .url)
            try c.encode(style, forKey: .style)
        case let .sticker(url, alt):
            try c.encode("sticker", forKey: .type)
            try c.encode(url, forKey: .url)
            try c.encode(alt, forKey: .alt)
        case let .image(url, alt):
            try c.encode("iimg", forKey: .type)
            try c.encode(url, forKey: .url)
            try c.encode(alt, forKey: .alt)
        case let .quoteRef(name, floor, url):
            try c.encode("qref", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encode(floor, forKey: .floor)
            try c.encode(url, forKey: .url)
        case .lineBreak: try c.encode("br", forKey: .type)
        }
    }
}

/// All immutable fields from a receive-code marker, not live payment state.
public struct NativeStardustReceive: Codable, Equatable, Sendable {
    public let memberId: Int64
    public let refId: Int64
    public let amount: Int
    public let description: String
    public let onetime: Bool

    public init(memberId: Int64, refId: Int64, amount: Int, description: String = "", onetime: Bool = false) {
        self.memberId = memberId
        self.refId = refId
        self.amount = amount
        self.description = description
        self.onetime = onetime
    }

    private enum CodingKeys: String, CodingKey { case memberId, refId, amount, description, onetime }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        memberId = try c.decode(Int64.self, forKey: .memberId)
        refId = try c.decode(Int64.self, forKey: .refId)
        amount = try c.decode(Int.self, forKey: .amount)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        onetime = try c.decodeIfPresent(Bool.self, forKey: .onetime) ?? false
    }
}

public struct NativeAnsiSpan: Codable, Equatable, Sendable {
    /// Half-open Kotlin String indices: UTF-16 code units, NOT Swift Characters.
    public let start: Int
    public let end: Int
    public let fg: Int?
    public let bg: Int?
    public let bold: Bool
    public let underline: Bool

    public init(start: Int, end: Int, fg: Int? = nil, bg: Int? = nil, bold: Bool = false, underline: Bool = false) {
        self.start = start
        self.end = end
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.underline = underline
    }

    /// Invalid/untrusted cache ranges are ignored, never clamped into a different glyph.
    /// Scalar boundaries (including combining marks/ZWJ) are valid; half a surrogate is not.
    public func range(in text: String) -> Range<String.Index>? {
        guard start >= 0, end > start, end <= text.utf16.count else { return nil }
        let lower = String.Index(utf16Offset: start, in: text)
        let upper = String.Index(utf16Offset: end, in: text)
        guard lower.samePosition(in: text.unicodeScalars) != nil,
              upper.samePosition(in: text.unicodeScalars) != nil else { return nil }
        return lower..<upper
    }

    /// Swift's String.Index → AttributedString.Index conversion rejects boundaries inside a
    /// grapheme cluster. Walk the scalar view instead, so ANSI preceding an accent/ZWJ survives.
    public func attributedRange(in text: AttributedString) -> Range<AttributedString.Index>? {
        let source = String(text.characters)
        guard let range = range(in: source) else { return nil }
        let scalars = source.unicodeScalars
        let startOffset = scalars.distance(from: scalars.startIndex, to: range.lowerBound)
        let endOffset = scalars.distance(from: scalars.startIndex, to: range.upperBound)
        let lower = text.unicodeScalars.index(text.startIndex, offsetBy: startOffset)
        let upper = text.unicodeScalars.index(text.startIndex, offsetBy: endOffset)
        return lower..<upper
    }

    private enum CodingKeys: String, CodingKey { case start, end, fg, bg, bold, underline }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Int.self, forKey: .start)
        end = try c.decode(Int.self, forKey: .end)
        fg = try c.decodeIfPresent(Int.self, forKey: .fg)
        bg = try c.decodeIfPresent(Int.self, forKey: .bg)
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        underline = try c.decodeIfPresent(Bool.self, forKey: .underline) ?? false
    }
}

public struct NativeCode: Codable, Equatable, Sendable {
    public let code: String
    public let language: String?
    public let spans: [NativeAnsiSpan]
    public let columns: Int

    public init(code: String, language: String? = nil, spans: [NativeAnsiSpan] = [], columns: Int = 0) {
        self.code = code
        self.language = language
        self.spans = spans
        self.columns = columns
    }

    private enum CodingKeys: String, CodingKey { case code, language, spans, columns }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        spans = try c.decodeIfPresent([NativeAnsiSpan].self, forKey: .spans) ?? []
        columns = try c.decodeIfPresent(Int.self, forKey: .columns) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
        try c.encode(language, forKey: .language)
        try c.encode(spans, forKey: .spans)
        try c.encode(columns, forKey: .columns)
    }
}

public struct NativeRichTab: Codable, Equatable, Sendable {
    public let title: String
    public let children: [NativeRichNode]

    public init(title: String, children: [NativeRichNode]) {
        self.title = title
        self.children = children
    }
}

public indirect enum NativeRichNode: Codable, Equatable, Sendable {
    case paragraph([NativeInlineNode])
    case heading(level: Int, inlines: [NativeInlineNode])
    case image(url: String, alt: String?)
    case vote(voteId: Int64)
    case stardust(NativeStardustReceive)
    case code(NativeCode)
    case quote([NativeRichNode])
    case tabs([NativeRichTab])
    case fold(title: String, children: [NativeRichNode], open: Bool)
    case list(ordered: Bool, items: [[NativeRichNode]])
    case table(cells: [[[NativeInlineNode]]])
    case divider

    private enum CodingKeys: String, CodingKey {
        case type, inlines, level, url, alt, voteId, children, tabs, title, open, ordered, items, cells, rows
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "p": self = .paragraph(try c.decode([NativeInlineNode].self, forKey: .inlines))
        case "h": self = .heading(level: try c.decode(Int.self, forKey: .level), inlines: try c.decode([NativeInlineNode].self, forKey: .inlines))
        case "img": self = .image(url: try c.decode(String.self, forKey: .url), alt: try c.decodeIfPresent(String.self, forKey: .alt))
        case "vote": self = .vote(voteId: try c.decode(Int64.self, forKey: .voteId))
        case "stardust": self = .stardust(try NativeStardustReceive(from: decoder))
        case "code": self = .code(try NativeCode(from: decoder))
        case "quote": self = .quote(try c.decode([NativeRichNode].self, forKey: .children))
        case "tabs": self = .tabs(try c.decode([NativeRichTab].self, forKey: .tabs))
        case "fold": self = .fold(title: try c.decode(String.self, forKey: .title), children: try c.decode([NativeRichNode].self, forKey: .children), open: try c.decodeIfPresent(Bool.self, forKey: .open) ?? false)
        case "list": self = .list(ordered: try c.decode(Bool.self, forKey: .ordered), items: try c.decode([[NativeRichNode]].self, forKey: .items))
        case "table":
            let cells = try c.decodeIfPresent([[[NativeInlineNode]]].self, forKey: .cells) ?? []
            if cells.isEmpty {
                let rows = try c.decodeIfPresent([[String]].self, forKey: .rows) ?? []
                self = .table(cells: rows.map { $0.map { [.text($0, .init())] } })
            } else {
                self = .table(cells: cells)
            }
        case "hr": self = .divider
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown block node discriminator")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .paragraph(let inlines):
            try c.encode("p", forKey: .type)
            try c.encode(inlines, forKey: .inlines)
        case let .heading(level, inlines):
            try c.encode("h", forKey: .type)
            try c.encode(level, forKey: .level)
            try c.encode(inlines, forKey: .inlines)
        case let .image(url, alt):
            try c.encode("img", forKey: .type)
            try c.encode(url, forKey: .url)
            try c.encode(alt, forKey: .alt)
        case .vote(let voteId):
            try c.encode("vote", forKey: .type)
            try c.encode(voteId, forKey: .voteId)
        case .stardust(let receive):
            try c.encode("stardust", forKey: .type)
            try receive.encode(to: encoder)
        case .code(let code):
            try c.encode("code", forKey: .type)
            try code.encode(to: encoder)
        case .quote(let children):
            try c.encode("quote", forKey: .type)
            try c.encode(children, forKey: .children)
        case .tabs(let tabs):
            try c.encode("tabs", forKey: .type)
            try c.encode(tabs, forKey: .tabs)
        case let .fold(title, children, open):
            try c.encode("fold", forKey: .type)
            try c.encode(title, forKey: .title)
            try c.encode(children, forKey: .children)
            try c.encode(open, forKey: .open)
        case let .list(ordered, items):
            try c.encode("list", forKey: .type)
            try c.encode(ordered, forKey: .ordered)
            try c.encode(items, forKey: .items)
        case .table(let cells):
            try c.encode("table", forKey: .type)
            try c.encode(cells, forKey: .cells)
        case .divider: try c.encode("hr", forKey: .type)
        }
    }
}
