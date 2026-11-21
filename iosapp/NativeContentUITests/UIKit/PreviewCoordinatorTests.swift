// Real-UIKit coordinator ordering regression; not touch/presentation acceptance.
import Foundation
import UIKit
import SwiftUI
import XCTest
import NodysseyNativeCore

@MainActor private final class HeldAnimator: NSObject, UIContextMenuInteractionCommitAnimating {
    var preferredCommitStyle: UIContextMenuInteractionCommitStyle = .dismiss
    var previewViewController: UIViewController? { nil }
    var previewView: UIView? { nil }
    private var completions: [() -> Void] = []
    func addAnimations(_ animations: @escaping () -> Void) {}
    func addCompletion(_ completion: @escaping () -> Void) { completions.append(completion) }
    func finish() { let work = completions; completions.removeAll(); work.forEach { $0() } }
}

final class PreviewCoordinatorReplayTests: XCTestCase {
    @MainActor func testCommitBeforeEndReleasesDisplayedGateExactlyOnce() async throws {
        let app = NativeAppModel()
        let coordinator = ContentPostPreviewInteraction.Coordinator()
        let interaction = UIContextMenuInteraction(delegate: coordinator)
        var gates = Set<UUID>()
        var ends: [UUID] = []
        var commits = 0
        coordinator.configure(app: app, item: .init(postID: 42, summary: .null, routeIdentity: .null,
            onCommit: { commits += 1 }, onMenuStateChanged: { id, active in
                if active { gates.insert(id) } else { gates.remove(id); ends.append(id) }
            }))
        let configuration = try XCTUnwrap(coordinator.contextMenuInteraction(interaction, configurationForMenuAtLocation: .zero))
        coordinator.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: nil)
        XCTAssertEqual(gates.count, 1)
        let commit = HeldAnimator()
        coordinator.contextMenuInteraction(interaction, willPerformPreviewActionForMenuWith: configuration, animator: commit)
        commit.finish()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(commits, 1)
        XCTAssertTrue(gates.isEmpty, "Commit completion left the Home board-swipe gate active")
        coordinator.contextMenuInteraction(interaction, willEndFor: configuration, animator: nil)
        coordinator.cancel()
        XCTAssertEqual(ends.count, 1, "Terminal paths must release one displayed lease exactly once")
        XCTAssertTrue(gates.isEmpty)
        print("COORDINATOR_REPLAY commits=\(commits) gates=\(gates.count) ends=\(ends.count); programmatic, NOT touch")
    }

}
