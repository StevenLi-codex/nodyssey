import Foundation

/// Presentation only: the system scroll view still owns gesture admission and insets.
struct NativeRefreshState: Equatable {
    enum Phase: Equatable { case idle, pulling, refreshing, success }
    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var token: UUID?
    private var thresholdDelivered = false

    @discardableResult mutating func pull(progress: Double, dragging: Bool) -> Bool {
        guard token == nil else { return false }
        guard dragging else {
            self.progress = 0; phase = .idle; thresholdDelivered = false
            return false
        }
        self.progress = progress.isFinite ? max(0, min(1, progress)) : 0
        phase = self.progress > 0 ? .pulling : .idle
        guard self.progress >= 1, !thresholdDelivered else { return false }
        thresholdDelivered = true
        return true
    }

    mutating func begin(_ token: UUID) -> Bool {
        guard self.token == nil else { return false }
        self.token = token; phase = .refreshing; progress = 1
        return true
    }

    mutating func finish(_ token: UUID, success: Bool) {
        guard self.token == token else { return }
        if success { phase = .success }
        else { reset() }
    }

    mutating func collapse(_ token: UUID) {
        guard self.token == token else { return }
        reset()
    }

    mutating func reset() {
        token = nil; phase = .idle; progress = 0; thresholdDelivered = false
    }
}

/// One real operation, including observer completion, per visible owner. A cancelled
/// uncooperative operation must drain before a replacement can enter. Its old token
/// can never publish a check into a reappeared or re-keyed view.
@MainActor final class NativeRefreshCoordinator {
    private(set) var state = NativeRefreshState() {
        didSet { if state != oldValue { onChange?(state) } }
    }
    var onChange: ((NativeRefreshState) -> Void)?
    private var active: Task<Void, Never>?
    private var activeToken: UUID?
    private var visible = true

    deinit { active?.cancel() }

    func appear() { visible = true }

    @discardableResult func pull(progress: Double, dragging: Bool) -> Bool {
        guard visible else { return false }
        return state.pull(progress: progress, dragging: dragging)
    }

    func cancel() {
        visible = false
        state.reset()
        active?.cancel()
    }

    func refresh(
        failure: @escaping @MainActor () -> Bool = { false },
        completion: @escaping @MainActor () async -> Bool = { true },
        settle: @escaping @MainActor () async -> Void = {},
        action: @escaping @MainActor () async -> Void
    ) async {
        guard visible, !Task.isCancelled else { return }
        if let active {
            let token = activeToken
            await withTaskCancellationHandler { await active.value } onCancel: {
                active.cancel()
                Task { @MainActor [weak self] in
                    guard let self, let token, self.activeToken == token else { return }
                    self.state.collapse(token)
                }
            }
            return
        }
        let token = UUID()
        guard state.begin(token) else { return }
        activeToken = token
        let work = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            // No spring, minimum spinner time or haptic delays before network I/O.
            await action()
            guard !Task.isCancelled else { return }
            let completed = await completion()
            guard !Task.isCancelled, let self, self.visible,
                  self.activeToken == token, self.state.token == token else { return }
            let success = completed && !failure()
            self.state.finish(token, success: success)
            if success { await settle() }
            self.state.collapse(token)
        }
        active = work
        await withTaskCancellationHandler { await work.value } onCancel: {
            work.cancel()
            Task { @MainActor [weak self] in
                guard let self, self.activeToken == token else { return }
                self.state.collapse(token)
            }
        }
        guard activeToken == token else { return }
        active = nil; activeToken = nil
        state.collapse(token)
    }
}
