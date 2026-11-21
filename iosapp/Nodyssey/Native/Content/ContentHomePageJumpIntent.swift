import Foundation

/// A toolbar click keeps its rendered destination even before a pager exists.
struct ContentHomePageJumpScope: Equatable {
    let generation: Int
    let board: String
    let sort: String

    func contains(_ ticket: ContentFeedTicket) -> Bool {
        generation == ticket.generation && board == ticket.board && sort == ticket.sort
    }
}

extension ContentFeedBoardSwipeOwner {
    func admitted(scope: ContentHomePageJumpScope, ticket: ContentFeedTicket?) -> Self? {
        guard isHomeRoot, let ticket, scope.contains(ticket) else { return nil }
        var owner = self
        owner.sort = ticket.sort
        owner.observation = ticket.observation
        return owner
    }
}

struct ContentHomePageJumpIntent: Equatable {
    let id = UUID()
    let scope: ContentHomePageJumpScope

    // Shared by the toolbar consumer and regression tests, including the
    // owner-not-installed loading interval.
    static func take(_ pending: inout Self?, current: ContentHomePageJumpScope,
                     owner: ContentFeedTicket?) -> ContentFeedTicket? {
        guard let intent = pending else { return nil }
        guard intent.scope == current else { pending = nil; return nil }
        guard let owner, current.contains(owner) else { return nil }
        pending = nil
        return owner
    }
}

struct ContentHomePageJumpSheet {
    struct Presentation: Equatable {
        let id = UUID()
        let ticket: ContentFeedTicket
    }

    private(set) var presentation: Presentation?
    var owner: ContentFeedTicket? { presentation?.ticket }

    mutating func present(_ ticket: ContentFeedTicket) { presentation = .init(ticket: ticket) }
    mutating func cancel() { presentation = nil }

    @discardableResult
    mutating func dismiss(_ presented: Presentation?, current: ContentFeedTicket?,
                          scope: ContentHomePageJumpScope) -> Bool {
        // A pager can host multiple presentations. A retained action must match both.
        guard let presented, presentation == presented, current == presented.ticket,
              scope.contains(presented.ticket) else { return false }
        cancel()
        return true
    }

    mutating func take(_ page: Int64, presented: Presentation?, current: ContentFeedTicket?,
                       scope: ContentHomePageJumpScope) -> Int64? {
        dismiss(presented, current: current, scope: scope) ? page : nil
    }
}
