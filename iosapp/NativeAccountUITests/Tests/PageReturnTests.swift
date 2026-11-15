import Testing
import NodysseyNativeCore
@testable import AccountBehavior

@Test func leavingPageRetainsRowsButRejectsLateResponse() throws {
    var state = AccountPageState()
    let initial = state.begin(page: 2)
    let payload: JSONValue = .object(["page": .integer(2), "items": .array([.object(["postId": .integer(9007199254740993)])]), "hasNextPage": .bool(true)])
    try state.accept(payload, ticket: initial)
    let late = state.begin(page: 3)
    state.suspend()
    #expect(state.page == 2)
    #expect(state.items.count == 1)
    #expect(state.hasNext)
    let stale: JSONValue = .object(["page": .integer(3), "items": .array([]), "hasNextPage": .bool(false)])
    #expect(try state.accept(stale, ticket: late) == false)
    #expect(state.page == 2)
    state.invalidate()
    #expect(state.items.isEmpty)
}
