import AppKit
import SwiftUI
import Testing
@testable import NativeRendering

/// Mount the actual production SwiftUI tree: missing propagation through any recursive
/// container loses a code slot here. No source-string or parallel tree-walker assertions.
@Suite(.serialized) @MainActor
struct CodeSlotTests {
    @Test func nestedCodeUsesOwnerSlotWithoutChangingPayloadOrActions() throws {
        let nodes = try JSONDecoder().decode([NativeRichNode].self, from: Data(Self.fixture.utf8))
        var rendered: [String: NativeCode] = [:]
        var events: [String] = []
        let actions = NativeRichTextActions(
            onImage: { url, alt in events.append("image:\(url):\(alt ?? "")") },
            onVote: { events.append("vote:\($0)") },
            onLink: { events.append("link:\($0)") },
            onQuoteReference: { events.append("quote:\($0):\($1):\($2)") },
            onCode: { code, action in events.append("code:\(code.code):\(action)") },
            codeContent: { code, inherited in
                rendered[code.code] = code
                // The nested source/report controls must retain the owner's original actions.
                if code.code == "list" {
                    inherited.onImage?("/image.png", "alt")
                    inherited.onVote?(9_007_199_254_740_993)
                    inherited.onLink?("/post-1-1#3")
                    inherited.onQuoteReference?("name", "#3", "/post-1-1")
                    inherited.onCode?(code, .source)
                }
                return AnyView(Text(code.code))
            }
        )
        let host = NSHostingView(rootView: NativeRichTextView(nodes: nodes, actions: actions))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 1200)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        #expect(Set(rendered.keys) == ["root", "quote", "fold", "tabA", "tabB", "list"])
        #expect(rendered["list"]?.language == "ansi")
        #expect(rendered["list"]?.columns == 83)
        #expect(rendered["list"]?.spans.first?.bold == true)
        #expect(rendered["list"]?.spans.first?.start == 0)
        #expect(rendered["list"]?.spans.first?.end == 4)
        #expect(events.contains("image:/image.png:alt"))
        #expect(events.contains("vote:9007199254740993"))
        #expect(events.contains("link:/post-1-1#3"))
        #expect(events.contains("quote:name:#3:/post-1-1"))
        #expect(events.contains("code:list:source"))
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
               "spans":[{"start":0,"end":4,"bold":true}]}
            ]]}
          ]}
        ]}
      ]}
    ]
    """#
}
