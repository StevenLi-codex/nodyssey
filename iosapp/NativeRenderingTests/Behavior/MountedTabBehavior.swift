import SwiftUI
import UIKit

@MainActor enum MountedTabProbe {
    static let notification = Notification.Name("behavior.nodyssey.mounted-tab.action")
    static var invocations: [Int] = []
}

@MainActor final class MountedTabCase {
    struct Sample: Codable, Equatable {
        let body: String
        let selectedLocation: Int?
        let selectedLength: Int
        let selectedText: String?
        let paragraph: String
        let textView: String
        let attachment: String?
        let host: String?
        let hostView: String?
        let hostOwnedByParagraph: Bool
        let hostInWindow: Bool
        let mounted: Bool
        let active: Bool
        let selectable: Bool
        let linkCount: Int
        let selectionBoundaryActive: Bool
    }
    struct Frame: Codable, Equatable {
        let paragraphs: [Sample]
        let invocations: [Int]
    }
    struct Tracked {
        let paragraph: NativeParagraphController
        let attachment: NativeInlineTextAttachment
        let host: UIHostingController<AnyView>
    }
    struct Trail: Codable {
        let frame: Frame
        let elapsedMS: Int
        let samples: Int
    }
    struct Departure: Codable {
        let old: Sample
        let oldAttachmentReleased: Bool
        let oldHostDetached: Bool
        var cleared: Bool { old.body.isEmpty && old.selectedLength == 0 && !old.active && !old.selectable && old.attachment == nil && oldAttachmentReleased && oldHostDetached }
    }
    struct Result: Encodable {
        let test = "mounted-rich-tab-reselect-and-A-B-A"
        let activation = "programmatic exactButtonaction (SwiftUI current-render notification subscriber); no touch"
        let simulatorOS: String
        var passed = false
        var fixtureError: String?
        var failures: [String] = []
        var settled: [String: Trail] = [:]
        var immediate: [String: Frame] = [:]
        var departed: [String: Departure] = [:]
    }
    struct FixtureError: Error { let detail: String }

    let root: UIViewController
    var result = Result(simulatorOS: UIDevice.current.systemVersion)
    init(root: UIViewController) { self.root = root }

    private func controllers(_ vc: UIViewController) -> [NativeParagraphController] {
        if let paragraph = vc as? NativeParagraphController { return [paragraph] }
        return vc.children.flatMap { controllers($0) }
    }
    private func id(_ object: AnyObject) -> String { String(describing: ObjectIdentifier(object)) }
    private func body(_ tab: String) -> String { "\(tab) selectable text \u{FFFC} \(tab) link" }
    private func attachment(_ paragraph: NativeParagraphController) -> NativeInlineTextAttachment? {
        let text = paragraph.textView.attributedText ?? NSAttributedString(string: "")
        let index = (text.string as NSString).range(of: "\u{FFFC}").location
        guard index != NSNotFound else { return nil }
        return text.attribute(.attachment, at: index, effectiveRange: nil) as? NativeInlineTextAttachment
    }
    private func sample(_ paragraph: NativeParagraphController) -> Sample {
        let textView = paragraph.textView
        let text = textView.attributedText ?? NSAttributedString(string: "")
        let range = textView.selectedRange
        let media = attachment(paragraph)
        var linkCount = 0
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value != nil { linkCount += 1 }
        }
        let selectedText = range.length > 0 && range.location <= text.length && range.length <= text.length - range.location
            ? (text.string as NSString).substring(with: range) : nil
        return Sample(body: text.string, selectedLocation: range.location == NSNotFound ? nil : range.location,
            selectedLength: range.length, selectedText: selectedText, paragraph: id(paragraph), textView: id(textView),
            attachment: media.map(id), host: media?.host.map(id), hostView: media?.host?.viewIfLoaded.map(id),
            hostOwnedByParagraph: media?.host?.parent === paragraph,
            hostInWindow: media?.host?.viewIfLoaded?.window != nil, mounted: textView.window != nil && !textView.bounds.isEmpty,
            active: paragraph.isActive && textView.selectionActive, selectable: textView.isSelectable, linkCount: linkCount,
            selectionBoundaryActive: NativeRichInteractionBoundary.hasActiveTextSelection(in: textView))
    }
    private func frame() -> Frame {
        Frame(paragraphs: controllers(root).map(sample).sorted { $0.paragraph < $1.paragraph }, invocations: MountedTabProbe.invocations)
    }
    private func settle(_ label: String, when ready: (Frame) -> Bool = { _ in true }) async throws -> Frame {
        let start = ProcessInfo.processInfo.systemUptime
        var previous: Frame?, equal = 0
        for tick in 1...40 {
            try await Task.sleep(nanoseconds: 80_000_000)
            let current = frame()
            equal = (current == previous) ? equal + 1 : 1
            previous = current
            let ms = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
            if (ms >= 450 && equal >= 3 && ready(current)) || tick == 40 {
                result.settled[label] = Trail(frame: current, elapsedMS: ms, samples: tick)
                guard equal >= 3 && ready(current) else { throw FixtureError(detail: "Did not settle: \(label)") }
                return current
            }
        }
        throw FixtureError(detail: "Missing sample: \(label)")
    }
    private func active(_ sample: Sample, _ tab: String) -> Bool {
        sample.body == body(tab) && sample.active && sample.selectable && sample.mounted && sample.linkCount == 1
            && sample.attachment != nil && sample.host != nil && sample.hostOwnedByParagraph
    }
    private func tracked(_ tab: String) -> Tracked? {
        guard let owner = controllers(root).first(where: { active(sample($0), tab) }), let media = attachment(owner),
              let host = media.host else { return nil }
        return Tracked(paragraph: owner, attachment: media, host: host)
    }
    private func select(_ tab: String, in owner: Tracked) throws -> Sample {
        let text = owner.paragraph.textView
        let wanted = "\(tab) selectable"
        let range = (text.attributedText.string as NSString).range(of: wanted)
        guard range.location != NSNotFound else { throw FixtureError(detail: "Missing selection input for \(tab)") }
        text.selectedRange = range
        let selected = sample(owner.paragraph)
        guard selected.selectedText == wanted, selected.selectionBoundaryActive else {
            throw FixtureError(detail: "UIKit selection not established for \(tab): \(selected)")
        }
        return selected
    }
    private func invoke(_ index: Int, label: String) throws {
        let expected = MountedTabProbe.invocations + [index]
        NotificationCenter.default.post(name: MountedTabProbe.notification, object: index)
        result.immediate[label] = frame()
        guard MountedTabProbe.invocations == expected else { throw FixtureError(detail: "Not exactly one mounted Button subscriber for \(label)") }
    }
    private func departed(_ old: Tracked, label: String) -> Bool {
        let value = Departure(old: sample(old.paragraph), oldAttachmentReleased: old.attachment.host == nil,
            oldHostDetached: old.host.parent == nil && old.host.viewIfLoaded?.window == nil)
        result.departed[label] = value
        return value.cleared
    }
    private func check(_ outcome: Bool, _ label: String) { if !outcome { result.failures.append(label) } }

    private func scenario() async throws {
        let initial = try await settle("initial-A", when: { $0.paragraphs.contains { self.active($0, "A") } })
        guard let a = tracked("A"), initial.paragraphs.filter(\.active).count == 1 else {
            throw FixtureError(detail: "Expected exactly one initially active paragraph")
        }
        let aSelected = try select("A", in: a)
        result.immediate["before-reselect-A"] = frame()
        try invoke(0, label: "reselect-A")
        let reselected = try await settle("reselect-A")
        check(reselected.paragraphs.contains(aSelected), "same-tab A lost body, selection, or text/attachment host identity")
        check(result.immediate["reselect-A"]?.paragraphs.contains(aSelected) == true && a.attachment.host === a.host,
              "same-tab A revoked synchronously")

        try invoke(1, label: "A-to-B")
        let aImmediatelyCleared = departed(a, label: "A-to-B immediate")
        let switched = try await settle("A-to-B")
        check(aImmediatelyCleared && departed(a, label: "A-to-B settled"), "A-to-B did not clear/revoke old A")
        check(switched.paragraphs.filter(\.active).count == 1, "A-to-B did not leave exactly one active paragraph")
        guard let b = tracked("B") else { check(false, "B body, link or hosted attachment not active after A-to-B"); return }
        check(b.paragraph !== a.paragraph && b.attachment !== a.attachment && b.host !== a.host, "B reused an old A owner")
        _ = try select("B", in: b)
        result.immediate["before-B-to-A"] = frame()
        try invoke(0, label: "B-to-A")
        let bImmediatelyCleared = departed(b, label: "B-to-A immediate")
        let returned = try await settle("B-to-A")
        check(bImmediatelyCleared && departed(b, label: "B-to-A settled"), "B-to-A did not clear/revoke old B")
        guard let newA = tracked("A") else { check(false, "A body, link or hosted attachment not restored after B-to-A"); return }
        let newSample = sample(newA.paragraph)
        check(returned.paragraphs.filter(\.active).count == 1 && newA.paragraph === a.paragraph && newSample.textView == aSelected.textView
                && newSample.selectedLength == 0 && newA.attachment !== a.attachment && newA.host !== a.host,
              "returned A did not keep its mounted text owner and restore a fresh attachment with no stale selection")

        let returnSelected = try select("A", in: newA)
        result.immediate["before-reselect-returned-A"] = frame()
        try invoke(0, label: "reselect-returned-A")
        let returnReselected = try await settle("reselect-returned-A")
        check(returnReselected.paragraphs.contains(returnSelected), "same-tab returned A lost body, selection, or text/attachment host identity")
        check(result.immediate["reselect-returned-A"]?.paragraphs.contains(returnSelected) == true && newA.attachment.host === newA.host,
              "same-tab returned A revoked synchronously")
    }

    func run() async -> [String: Any] {
        do { try await scenario() }
        catch let error as FixtureError { result.fixtureError = error.detail }
        catch { result.fixtureError = String(describing: error) }
        result.passed = result.fixtureError == nil && result.failures.isEmpty
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try! JSONSerialization.jsonObject(with: encoder.encode(result))) as! [String: Any]
    }
}
