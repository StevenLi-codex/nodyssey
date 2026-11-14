import AppKit
import SwiftUI
import Testing
import NodysseyNativeCore
@testable import NativeContentState

/// Hosts the production ContentRichBody -> NativeRichTextView -> ContentReportView tree.
/// Only the bridge/platform boundaries and the terminal source-code leaf are probes.
@Suite(.serialized) @MainActor
struct ReportCompositionTests {
    @Test func nestedReportsUseLivePreferenceAndRetainOwnerActions() async throws {
        let app = NativeAppModel()
        app.settings = .object(["reportFormat": .string("SOURCE")])
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(Self.fixture.utf8))
        var jumps: [String] = []
        let host = NSHostingView(rootView: ContentRichBody(
            value: value, postID: 9_007_199_254_740_993,
            threadTitle: "Thread", floor: "#7", jump: { jumps.append($0) }
        ).environmentObject(app))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 1600)
        func settle() async throws {
            for _ in 0..<20 {
                host.layoutSubtreeIfNeeded()
                _ = host.fittingSize
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await settle()
        let expected: Set<String> = ["root", "quote", "fold", "tabA", "tabB", "list", "ordinary"]
        #expect(Set(app.parseCalls.compactMap { $0["code"]?.string }) == expected)
        #expect(Set(app.sourceLeaves.values.map { $0.code.code }) == expected)
        let nested = try #require(app.sourceLeaves.values.first { $0.code.code == "list" })
        #expect(nested.code.language == "ansi")
        #expect(nested.code.columns == 83)
        #expect(nested.code.spans.first?.start == 0)
        #expect(nested.code.spans.first?.end == 4)
        #expect(nested.code.spans.first?.bold == true)
        let parsed = try #require(app.parseCalls.first { $0["code"]?.string == "list" })
        #expect(parsed["spans"]?.array?.first?["end"]?.int == 4)
        #expect(nested.actions.codeContent != nil)
        #expect(nested.actions.onCode != nil)
        #expect(nested.actions.onVote != nil)
        nested.actions.onImage?("/sticker.png", "sticker")
        nested.actions.onLink?("#7")
        nested.actions.onLink?("/post-2-1")
        nested.actions.onQuoteReference?("name", "#8", "/post-9007199254740993-1")
        nested.actions.onQuoteReference?("name", "#9", "/post-2-1")
        nested.actions.onStardust?(.init(memberId: 9_007_199_254_740_993, refId: 42, amount: 3, description: "fixture", onetime: true))
        #expect(jumps == ["#7", "#8"])
        #expect(app.links == ["/post-2-1", "/post-2-1#9"])
        #expect(app.routes.first?.0 == "ImageViewer")
        #expect(app.routes.first?.1 == ["urls": .array([.string("/sticker.png")]), "index": .integer(0)])
        #expect(app.routes.last?.0 == "Stardust")
        #expect(app.routes.last?.1 == ["memberId": .integer(9_007_199_254_740_993), "refId": .integer(42), "amount": .integer(3), "description": .string("fixture"), "onetime": .bool(true)])

        app.settings = .object(["reportFormat": .string("ADAPTED")])
        try await settle()
        #expect(Set(app.sourceLeaves.values.map { $0.code.code }) == ["ordinary"])
        app.settings = .object(["reportFormat": .string("SOURCE")])
        try await settle()
        #expect(Set(app.sourceLeaves.values.map { $0.code.code }) == expected)
        // Preference changes must not replace report identity and reparse every code block.
        #expect(app.parseCalls.count == expected.count)
        #expect(app.unexpectedOperations.isEmpty)
    }

    @Test(arguments: [NativeCodeAction.source, .adaptedReport, .compare])
    func nestedReportActionsKeepExplicitOverrideAndComparePreference(_ action: NativeCodeAction) async throws {
        let app = NativeAppModel()
        app.settings = .object(["reportFormat": .string("SOURCE")])
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"[{"type":"quote","children":[{"type":"code","code":"nested","language":null}]}]"#.utf8))
        let host = NSHostingView(rootView: ContentRichBody(value: value, postID: 42, jump: { _ in }).environmentObject(app))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        // Offscreen AppKit window lets lazy List rows in the real sheet compose.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderBack(nil)
        defer {
            for sheet in window.sheets { window.endSheet(sheet); sheet.orderOut(nil) }
            window.orderOut(nil)
            window.contentView = nil
        }
        func settle() async throws {
            for _ in 0..<30 {
                host.layoutSubtreeIfNeeded()
                _ = host.fittingSize
                for sheet in window.sheets {
                    sheet.setContentSize(NSSize(width: 600, height: 800))
                    sheet.contentView?.layoutSubtreeIfNeeded()
                    _ = sheet.contentView?.fittingSize
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await settle()
        let leaf = try #require(app.sourceLeaves.values.first)
        if action == .source { app.settings = .object(["reportFormat": .string("ADAPTED")]) }
        try await settle()
        leaf.actions.onCode?(leaf.code, action)
        try await settle()
        #expect(app.parseCalls.count == 2, "The inherited nested action must mount the real report sheet")
        let sourceCount = app.sourceLeaves.count
        #expect(sourceCount == (action == .compare ? 2 : 1))
        // Flipping settings changes the inline report; explicit sheet overrides stay local.
        app.settings = .object(["reportFormat": .string(action == .source ? "SOURCE" : "ADAPTED")])
        try await settle()
        #expect(app.sourceLeaves.count == (action == .source ? 2 : 0))
        #expect(app.unexpectedOperations.isEmpty)
    }

    private static let fixture = #"""
    [
      {"type":"code","code":"root","language":null},
      {"type":"quote","children":[{"type":"code","code":"quote","language":null}]},
      {"type":"fold","title":"Report","open":true,"children":[
        {"type":"code","code":"fold","language":null},
        {"type":"tabs","tabs":[
          {"title":"A","children":[{"type":"code","code":"tabA","language":null}]},
          {"title":"B","children":[{"type":"code","code":"tabB","language":null},
            {"type":"list","ordered":true,"items":[[
              {"type":"code","code":"list","language":"ansi","columns":83,
               "spans":[{"start":0,"end":4,"bold":true}]},
              {"type":"code","code":"ordinary","language":null}
            ]]}
          ]}
        ]}
      ]}
    ]
    """#
}
