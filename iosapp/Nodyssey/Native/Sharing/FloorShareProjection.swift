import Foundation

/// Local to sharing so every export uses the same language as its preview.
/// Unknown locales retain the app's Simplified Chinese fallback.
struct FloorShareCopy {
    let language: FloorShareLanguage
    private func pick(_ en: String, _ hans: String, _ hant: String) -> String {
        switch language { case .english: return en; case .simplifiedChinese: return hans; case .traditionalChinese: return hant }
    }
    var share: String { pick("Share", "分享", "分享") }
    var image: String { pick("Share floor as image", "将楼层分享为图片", "將樓層分享為圖片") }
    var link: String { pick("Share link", "分享链接", "分享連結") }
    var close: String { pick("Close", "关闭", "關閉") }
    var retry: String { pick("Retry", "重试", "重試") }
    var export: String { pick("Share image", "分享图片", "分享圖片") }
    var disclosure: String { pick("Text-only card · images, styling and interactive content are not reproduced. Read the original for full content.", "文字卡片 · 不含图片、原文样式及交互内容。完整内容请查看原帖。", "文字卡片 · 不含圖片、原文樣式及互動內容。完整內容請查看原帖。") }
    var truncated: String { pick("Excerpt only — long content was shortened. Read the original below.", "内容过长，仅显示节选。完整内容请查看下方原帖。", "內容過長，僅顯示節選。完整內容請查看下方原帖。") }
    var omittedImage: String { pick("[Image omitted]", "[图片未包含]", "[圖片未包含]") }
    var omittedSticker: String { pick("[Sticker omitted]", "[表情未包含]", "[表情未包含]") }
    var omittedPoll: String { pick("[Poll omitted]", "[投票未包含]", "[投票未包含]") }
    var omittedPayment: String { pick("[Payment code omitted]", "[收款码未包含]", "[收款碼未包含]") }
    var omittedFold: String { pick("[Collapsed content omitted]", "[折叠内容未包含]", "[摺疊內容未包含]") }
    var omittedTabs: String { pick("[Other tabs omitted]", "[其他标签页未包含]", "[其他標籤頁未包含]") }
    var missing: String { pick("This share entry has no loaded floor content. Share the link instead.", "此分享入口没有已加载的楼层正文，请改为分享链接。", "此分享入口沒有已載入的樓層正文，請改為分享連結。") }
    var failed: String { pick("The image could not be prepared or shared. Retry, or share the link instead.", "无法生成或分享图片。请重试，或改为分享链接。", "無法產生或分享圖片。請重試，或改為分享連結。") }
    var invalid: String { pick("This floor is unavailable, hidden, or has changed. Return to the thread and try again.", "此楼层不可用、已隐藏或内容已变更。请返回主题后重试。", "此樓層不可用、已隱藏或內容已變更。請返回主題後重試。") }
    func message(for error: Error) -> String {
        switch error as? FloorShareError {
        case .missingContext: return missing
        case .invalidContent, .blockedContent, .invalidSource: return invalid
        default: return failed
        }
    }
}

/// Deterministic text projection from the canonical decoded model. This never resolves a URL.
struct FloorShareProjection {
    private(set) var text = ""
    private(set) var truncated = false
    private var lines = 1
    private var count = 0
    private var visited = 0
    let copy: FloorShareCopy

    init(copy: FloorShareCopy) {
        self.copy = copy
    }

    mutating func append(_ value: String) {
        guard !truncated else { return }
        for character in value {
            guard count < 6000, !(character.isNewline && lines >= 100) else { truncated = true; return }
            text.append(character)
            count += 1
            if character.isNewline { lines += 1 }
        }
    }
    mutating func inlines(_ items: [NativeInlineNode]) {
        for item in items {
            guard !truncated else { return }
            switch item {
            case .text(let text, _), .link(let text, _, _): append(text)
            case .quoteRef(let name, let floor, _): append("\(name) \(floor)")
            case .lineBreak: append("\n")
            case .image: append(copy.omittedImage)
            case .sticker: append(copy.omittedSticker)
            }
        }
    }
    mutating func blocks(_ nodes: [NativeRichNode], depth: Int = 0) {
        guard depth < 32 else { truncated = true; return }
        for (index, node) in nodes.enumerated() {
            guard !truncated, visited < 2000 else { truncated = true; return }
            visited += 1
            if index > 0 { append("\n\n") }
            switch node {
            case .paragraph(let items), .heading(_, let items): inlines(items)
            case .image: append(copy.omittedImage)
            case .vote: append(copy.omittedPoll)
            case .stardust: append(copy.omittedPayment)
            case .code(let code): append(code.code)
            case .quote(let children): append("› "); blocks(children, depth: depth + 1)
            case .fold(let title, let children, let open):
                append(title + "\n")
                if open { blocks(children, depth: depth + 1) } else { append(copy.omittedFold) }
            case .tabs(let tabs):
                if let first = tabs.first { append(first.title + "\n"); blocks(first.children, depth: depth + 1) }
                if tabs.count > 1 { append("\n" + copy.omittedTabs) }
            case .list(let ordered, let items):
                for (index, children) in items.enumerated() {
                    if index > 0 { append("\n") }
                    append(ordered ? "\(index + 1). " : "• ")
                    blocks(children, depth: depth + 1)
                    if truncated { break }
                }
            case .table(let rows):
                for (rowIndex, row) in rows.enumerated() {
                    if rowIndex > 0 { append("\n") }
                    for (index, cell) in row.enumerated() {
                        if index > 0 { append(" | ") }
                        inlines(cell)
                        if truncated { break }
                    }
                    if truncated { break }
                }
            case .divider: append("—")
            }
        }
    }
}
