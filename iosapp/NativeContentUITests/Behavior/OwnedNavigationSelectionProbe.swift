// Appended to the production driver in the disposable simulator target so its
// private controller state can be exercised without adding production test APIs.
#if os(iOS)
extension NativeOwnedNavigationController {
    func exerciseSelectionLifecycle() async throws {
        @MainActor func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: message, code: 1) }
        }
        func descendants(_ owner: UIViewController) -> [UIViewController] { [owner] + owner.children.flatMap(descendants) }
        var links = 0
        let layout: (UUID?, NativeDestination?) -> AnyView = { _, destination in
            AnyView(NativeSelectableParagraph(inlines: [.link("private route text", "https://example.invalid", .init())],
                actions: .init(onLink: { _ in links += 1 }), role: .body, headingLevel: nil,
                inTable: false, stickerSize: 32).id(destination?.id)
                .modifier(NativeOwnedPageEnvironment(inherited: EnvironmentValues())))
        }
        apply(rootID: nil, path: [], active: true, rightToLeft: false, reduceMotion: true, content: layout)
        try await Task.sleep(for: .milliseconds(250))
        let retainedRoot = visible!
        guard let paragraph = descendants(retainedRoot).compactMap({ $0 as? NativeParagraphController }).first else {
            throw NSError(domain: "real paragraph did not mount", code: 1)
        }
        try require(paragraph.isActive && !paragraph.textView.attributedText.string.isEmpty, "initial paragraph inactive")
        paragraph.textView.selectedRange = NSRange(location: 0, length: 7)
        app.open("UserSpace", ["uid": .integer(11)])
        apply(rootID: nil, path: app.homePath, active: true, rightToLeft: false, reduceMotion: true, content: layout)
        try await Task.sleep(for: .milliseconds(180))
        paragraph.activate(URL(string: "nodyssey-inline://item/0")!)
        try require(!paragraph.isActive && paragraph.textView.attributedText.length == 0 && links == 0,
                    "hidden retained route kept canonical selection or link callback")
        let from = visible!
        let lease = app.beginInteractivePop(stack: .home, from: from.id!)!
        let tracking = Motion(lease: lease, from: from, to: retainedRoot, width: view.bounds.width, rtl: false, startX: view.bounds.midX)
        motion = tracking
        attach(retainedRoot)
        view.bringSubviewToFront(from.surface)
        render(tracking, progress: 0.3)
        try require(paragraph.isActive && paragraph.textView.attributedText.length > 0,
                    "first drag frame exposed a blank retained predecessor")
        cancel(tracking, immediate: true)
        await app.updatePath([], for: .home)
        apply(rootID: nil, path: [], active: true, rightToLeft: false, reduceMotion: true, content: layout)
        try await Task.sleep(for: .milliseconds(180))
        try require(visible === retainedRoot && paragraph.isActive && !paragraph.textView.attributedText.string.isEmpty,
                    "return did not restore same live paragraph host")
        apply(rootID: nil, path: [], active: false, rightToLeft: false, reduceMotion: true, content: layout)
        try require(!paragraph.isActive && paragraph.textView.attributedText.length == 0,
                    "inactive tab/sheet failed synchronous revoke")
        apply(rootID: nil, path: [], active: true, rightToLeft: false, reduceMotion: true, content: layout)
        try await Task.sleep(for: .milliseconds(180))
        try require(paragraph.isActive, "reactivation failed")
        app.navigationIdentityWillRevoke.send()
        try require(!paragraph.isActive && paragraph.textView.attributedText.length == 0 && view.isHidden,
                    "identity revocation retained hidden private selection")
    }
}
#endif
