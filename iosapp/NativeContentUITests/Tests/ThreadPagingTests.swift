import Testing
import NodysseyNativeCore
@testable import NativeContentState

@Test @MainActor func cancelledPageTaskReleasesLoadingWithoutClearingNewerRequest() async {
    var load = ContentThreadPageLoad()
    let ticket = load.begin()
    let task = Task { () -> Bool in
        do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { }
        return Task.isCancelled
    }
    task.cancel()
    load.finish(ticket, cancelled: await task.value)
    #expect(!load.loading)
    let next = load.begin()
    load.finish(ticket, cancelled: true)
    #expect(load.loading)
    load.finish(next, cancelled: false)
    #expect(!load.loading)
    let queued = load.begin()
    load.depart() // SwiftUI can disappear before its task body starts.
    #expect(!load.loading)
    let returned = load.begin()
    load.finish(queued, cancelled: false)
    #expect(load.loading)
    load.finish(returned, cancelled: false)
    #expect(!load.loading)
}

@Test func loadedFloorJumpUsesRepositoryPageWithoutNetworkAndLatestMeansBottom() {
    let thread: JSONValue = .object([
        "firstLoadedPage": .integer(3), "lastLoadedPage": .integer(4), "totalPages": .integer(8),
        "comments": .array([.object(["floor": .string("#21")]), .object(["floor": .string("#45")])]),
        "commentPages": .array([.integer(3), .integer(4)])
    ])
    let loaded = ContentThreadJump(target: .init(floor: "#45", page: nil), thread: thread)
    #expect(loaded.target.page == 4)
    #expect(loaded.loadPage == nil)
    let adjacent = ContentThreadJump(target: .init(floor: nil, page: 5), thread: thread)
    #expect(adjacent.loadPage == 5 && adjacent.extend)
    let distant = ContentThreadJump(target: .init(floor: nil, page: 8), thread: thread, bottom: true)
    #expect(distant.loadPage == 8 && !distant.extend && distant.bottom)
}

@Test func pageEntrySharesKeyboardValidationAndSwitchClearsInput() {
    var entry = ContentJumpEntry()
    entry.update("123456789x")
    #expect(entry.text == "123456")
    #expect(entry.target(total: 8)?.page == 8)
    entry.toggleUnit()
    #expect(entry.text.isEmpty && entry.floor)
    #expect(entry.target(total: 8) == nil)
    entry.update("21")
    #expect(entry.target(total: 8)?.floor == "#21")
    #expect(entry.target(total: 8)?.page == 3)
    entry.update("0")
    #expect(entry.target(total: 8)?.floor == "#0")
}

@Test func quoteExcerptMatchesAndroidParagraphAndHeadingOnlyWithoutTruncation() {
    let nodes: JSONValue = .array([
        .object(["type": .string("p"), "inlines": .array([.object(["type": .string("t"), "text": .string("  full paragraph  ")]), .object(["type": .string("iimg"), "alt": .string("not quoted")])])]),
        .object(["type": .string("code"), "code": .string("not quoted")]),
        .object(["type": .string("h"), "inlines": .array([.object(["type": .string("a"), "text": .string(String(repeating: "long", count: 40))])])])
    ])
    #expect(ContentQuoteContext.text(nodes) == "full paragraph\n" + String(repeating: "long", count: 40))
}
