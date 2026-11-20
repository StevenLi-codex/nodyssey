import Combine
import Foundation

/// Accumulate finger travel privately; only a visible rail change invalidates the List.
@MainActor
final class ContentFeedDragState: ObservableObject {
    @Published private(set) var expanded = true
    private var direction = ContentFeedDirection()

    func record(translation: CGFloat) {
        direction.record(translation: translation)
        publishIfChanged()
    }

    func endGesture() {
        direction.endGesture()
    }

    func reset() {
        direction = ContentFeedDirection()
        publishIfChanged()
    }

    private func publishIfChanged() {
        if expanded != direction.expanded { expanded = direction.expanded }
    }
}
