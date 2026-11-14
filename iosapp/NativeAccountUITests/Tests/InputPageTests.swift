import Foundation
import Testing
import NodysseyNativeCore
@testable import AccountBehavior

@Test func avatarChecksActualBytesRatherThanPickerExtension() throws {
    #expect(throws: (any Error).self) { try AccountInputState.avatar(Data("not-an-image".utf8)) }
    let png = Data([137,80,78,71,13,10,26,10,1])
    #expect(try AccountInputState.avatar(png) == "image/png")
    #expect(throws: (any Error).self) { try AccountInputState.avatar(Data(repeating: 0, count: 6_291_457)) }
}
@Test func passwordsMustMatchAndMeetSharedMinimum() {
    #expect(!AccountInputState.validPassword(current: "old", new: "1234567", confirmation: "1234567"))
    #expect(!AccountInputState.validPassword(current: "old", new: "12345678", confirmation: "mismatch"))
    #expect(AccountInputState.validPassword(current: "old", new: "12345678", confirmation: "12345678"))
}
@Test func pageReplacementKeepsInt64AndRejectsStaleSession() throws {
    var page = AccountPageState()
    let old = page.begin(page: 1)
    page.invalidate()
    let rows: JSONValue = .object(["page": .integer(1), "hasNextPage": .bool(true), "items": .array([
        .object(["postId": .integer(9_007_199_254_740_993), "title": .string("one")])])])
    let ignored = try page.accept(rows, ticket: old)
    #expect(!ignored && page.items.isEmpty)
    let current = page.begin(page: 2)
    let accepted = try page.accept(.object(["page": .integer(2), "hasNextPage": .bool(false), "items": rows["items"]!]), ticket: current)
    #expect(accepted && page.page == 2 && !page.hasNext)
    #expect(page.items[0]["postId"]?.int == 9_007_199_254_740_993)
    #expect(page.filtered(query: "ONE", board: "", newestFirst: false).count == 1)
}
