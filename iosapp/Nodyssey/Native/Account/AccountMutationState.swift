import Foundation

struct AccountMutationState {
    enum Phase { case idle, writing, reading, savedNeedsRefresh, uncertain, reconciled, verified, rejected }
    private(set) var phase: Phase = .idle
    private(set) var ticket: UUID?
    private var readbackCanResolveUncertainty = true
    var blocksWrite: Bool { ![.idle, .verified, .reconciled, .rejected].contains(phase) }
    mutating func rejectBeforeWrite(_ id: UUID) { if ticket == id && phase == .writing { phase = .rejected } }
    mutating func begin(confirmed: Bool, readbackCanResolveUncertainty: Bool = true) -> UUID? {
        guard confirmed, !blocksWrite else { return nil }
        self.readbackCanResolveUncertainty = readbackCanResolveUncertainty
        let id = UUID(); ticket = id; phase = .writing; return id
    }
    mutating func acknowledge(_ id: UUID) { if ticket == id && phase == .writing { phase = .reading } }
    mutating func writeFailed(_ id: UUID) { if ticket == id { phase = .uncertain } }
    mutating func readFailed(_ id: UUID) { if ticket == id && phase == .reading { phase = .savedNeedsRefresh } }
    // Only an acknowledged write can ever be labelled saved. A successful status read
    // can unlock a new confirmation for observable values, but never proves a password.
    mutating func refreshed(_ id: UUID) {
        guard ticket == id else { return }
        if [.reading, .savedNeedsRefresh].contains(phase) { phase = .verified }
        else if phase == .uncertain && readbackCanResolveUncertainty { phase = .reconciled }
    }
    mutating func invalidate() { ticket = nil; phase = .idle }
}
