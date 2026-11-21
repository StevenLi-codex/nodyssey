// Append to a disposable copy of NativeOwnedNavigation.swift for same-file
// access. These are programmatic UIKit regressions, not touch acceptance.
#if os(iOS)
@MainActor private final class LiveMotionDeparture {
    var prepares = 0
    var terminations = 0
    var valid = true
    var pending: CheckedContinuation<Bool, Never>?

    func resolve(_ accepted: Bool) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: accepted)
    }
}

extension NativeOwnedNavigationController {
    static func exerciseLiveMotionPolicy(makeOwner: () -> NativeOwnedNavigationController) async -> String {
        var results: [String] = []
        // Run independently so the baseline can expose both reported animators.
        for scenario in ["push", "commit", "cancel", "reverse", "heldAccept", "heldReject",
                         "invalidLease", "invalidDraft", "deferredPath", "tracking"] {
            do {
                try await makeOwner().exerciseLiveMotionPolicy(scenario)
                results.append("PASS \(scenario)")
            } catch {
                results.append("FAIL \(scenario): \((error as NSError).domain)")
            }
        }
        return results.joined(separator: "\n")
    }

    private func exerciseLiveMotionPolicy(_ scenario: String) async throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: message, code: 1) }
        }
        func eventually(_ condition: () -> Bool, _ message: String) async throws {
            for _ in 0..<120 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw NSError(domain: message, code: 1)
        }
        func applyPolicy(_ reduced: Bool) {
            apply(rootID: nil, path: app.path(for: .home), active: true,
                  rightToLeft: false, reduceMotion: reduced) { _, route in
                AnyView(Text(route?.route ?? "probe root"))
            }
        }
        func assertAtRest(_ target: Page, _ views: [Page]) throws {
            try require(motion == nil && projection == nil, "animator ownership remains")
            let expected = [Optional<UUID>.none] + app.path(for: .home).map { Optional($0.id) }
            try require(pages.map(\.id) == expected && target.id == expected.last!, "page projection diverged from path")
            try require(visible === target && target.parent === self, "wrong visible controller")
            try require(view.subviews.count == 1 && target.surface.superview === view &&
                        target.surface.transform == .identity && target.surface.isUserInteractionEnabled &&
                        !target.surface.accessibilityElementsHidden, "wrong resting surface")
            for page in views {
                try require(page.surface.layer.animationKeys()?.isEmpty ?? true, "residual transition layer animation")
            }
        }
        func pause(_ animator: UIViewPropertyAnimator?) throws -> UIViewPropertyAnimator {
            guard let animator, animator.state == .active else { throw NSError(domain: "normal animator did not start", code: 1) }
            animator.pauseAnimation()
            animator.fractionComplete = 0.35
            return animator
        }

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = self
        window.makeKeyAndVisible()
        let departure = LiveMotionDeparture()
        defer { departure.resolve(false); detach(); window.isHidden = true; window.rootViewController = nil }
        applyPolicy(false)
        guard let root = visible else { throw NSError(domain: "missing root", code: 1) }
        try require(root.surface.window === window && view.bounds.width > 0, "root must be mounted")
        app.open("UserSpace", ["uid": .integer(17)])
        if scenario == "push" {
            applyPolicy(false)
            let animator = try pause(projection)
            let target = pages.last!
            applyPolicy(true)
            try require(projection == nil && animator.state != .active, "policy left active push projection")
            try assertAtRest(target, [root, target])
            // normal → reduced → normal on the same owner.
            app.open("PostDetail", ["postId": .integer(18)])
            applyPolicy(false)
            try require(projection?.state == .active, "normal animation did not resume")
            try await eventually({ projection == nil }, "normal control did not finish")
            try assertAtRest(pages.last!, [target, pages.last!])
            return
        }
        applyPolicy(false)
        try await eventually({ projection == nil }, "initial push did not finish")
        let to = visible!
        app.open("PostDetail", ["postId": .integer(18)])
        applyPolicy(false)
        try await eventually({ projection == nil }, "detail push did not finish")
        let from = visible!
        let originalPath = app.path(for: .home)
        let held = scenario == "heldAccept" || scenario == "heldReject"
        app.registerDismissal(destinationID: from.id!, close: {
            departure.prepares += 1
            if held { return await withCheckedContinuation { departure.pending = $0 } }
            return true
        }, revoke: {}, terminate: { departure.terminations += 1 }, validate: { departure.valid })
        guard let lease = app.beginInteractivePop(stack: .home, from: from.id!) else {
            throw NSError(domain: "missing interactive lease", code: 1)
        }
        let swipe = Motion(lease: lease, from: from, to: to, width: view.bounds.width,
                           rtl: false, startX: view.bounds.midX)
        motion = swipe
        attach(to)
        view.bringSubviewToFront(from.surface)
        render(swipe, progress: 0.62)
        try require(swipe.to === to && to.surface.window === window, "predecessor host not retained")
        var animator: UIViewPropertyAnimator?

        switch scenario {
        case "tracking":
            applyPolicy(true)
            try require(motion === swipe && !swipe.cancelling && swipe.animator == nil &&
                        departure.prepares == 0 && departure.terminations == 0 && app.path(for: .home) == originalPath,
                        "policy ended an unreleased gesture")
            render(swipe, progress: 0.75)
            try require(from.surface.transform.tx > 0, "finger-driven rendering stopped")
            cancel(swipe)
        case "cancel":
            cancel(swipe)
            animator = try pause(swipe.animator)
            applyPolicy(true)
        default:
            release(swipe)
            if held {
                try await eventually({ departure.pending != nil }, "prepare did not suspend")
                applyPolicy(true)
                try require(motion === swipe && !swipe.cancelling && swipe.animator == nil &&
                            departure.terminations == 0 && app.path(for: .home) == originalPath,
                            "policy completed or cancelled a held preparation")
                departure.resolve(scenario == "heldAccept")
                try await eventually({ motion == nil || swipe.animator != nil }, "held prepare did not resolve")
                try require(swipe.animator == nil, "held prepare restarted an old-policy animator")
            } else {
                try await eventually({ swipe.animator?.state == .active }, "prepared settle did not start")
                try require(departure.terminations == 0 && app.path(for: .home) == originalPath,
                            "terminated before matching visual commit")
                animator = try pause(swipe.animator)
                // Keep a previously deferred normal-policy render in flight.
                applyPolicy(false)
                switch scenario {
                case "reverse": cancel(swipe)
                case "invalidLease": app.cancelInteractivePop(lease)
                case "invalidDraft": departure.valid = false
                case "deferredPath": app.open("UserSpace", ["uid": .integer(19)])
                default: break
                }
                applyPolicy(true)
            }
        }

        try require(motion == nil && animator?.state != .active, "policy left active settle animator")
        let committed = scenario == "commit" || scenario == "heldAccept"
        let expectedPrepares = scenario == "cancel" || scenario == "tracking" ? 0 : 1
        try require(departure.prepares == expectedPrepares && departure.terminations == (committed ? 1 : 0),
                    "incorrect prepare/terminate counts")
        if scenario == "deferredPath" {
            try require(app.path(for: .home).count == originalPath.count + 1 &&
                        Array(app.path(for: .home).dropLast()) == originalPath && !app.isInteractivePopCurrent(lease),
                        "deferred path redid stale navigation")
            try assertAtRest(pages.last!, [from, to, pages.last!])
        } else {
            try require(app.path(for: .home) == (committed ? Array(originalPath.dropLast()) : originalPath),
                        "incorrect final model path")
            try assertAtRest(committed ? to : from, [from, to])
        }
        try require(!app.commitInteractivePop(lease, visible: to.id), "late callback consumed old lease")
        guard let replacement = app.beginInteractivePop(stack: .home, from: pages.last!.id!) else {
            throw NSError(domain: "terminal left old lease blocking fresh navigation", code: 1)
        }
        app.cancelInteractivePop(replacement)
    }
}
#endif
