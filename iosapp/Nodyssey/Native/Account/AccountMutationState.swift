import Foundation

struct AccountMutationState {
    enum Phase { case idle, writing, reading, savedNeedsRefresh, uncertain, verified }
    private(set) var phase: Phase = .idle
    private(set) var ticket: UUID?
    var blocksWrite: Bool { ![.idle, .verified].contains(phase) }
    mutating func begin(confirmed: Bool) -> UUID? {
        guard confirmed, !blocksWrite else { return nil }
        let id = UUID(); ticket = id; phase = .writing; return id
    }
    mutating func acknowledge(_ id: UUID) { if ticket == id && phase == .writing { phase = .reading } }
    mutating func writeFailed(_ id: UUID) { if ticket == id { phase = .uncertain } }
    mutating func readFailed(_ id: UUID) { if ticket == id && phase == .reading { phase = .savedNeedsRefresh } }
    mutating func refreshed(_ id: UUID) { if ticket == id && phase != .writing { phase = .verified } }
    mutating func invalidate() { ticket = nil; phase = .idle }
}
