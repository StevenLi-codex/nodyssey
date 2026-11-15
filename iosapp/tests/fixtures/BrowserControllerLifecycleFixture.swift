MainActor.assumeIsolated {
    _ = NSApplication.shared
    var events: [String] = []
    NativeBrowserSession.started = { events.append("seed") }
    let controller = AuthenticationController(url: "", goal: .login,
        onFailure: { _ in events.append("error") }, onClosed: { events.append("dismiss") },
        onTeardown: { events.append("release") })
    controller.viewDidLoad()
    guard events == ["seed"] else { fatalError("Seed was not reached: \(events)") }
    controller.close(notify: true)
    guard events == ["seed"], NativeBrowserSession.pendingClose != nil else {
        fatalError("Presenter released before final drain: \(events)")
    }
    NativeBrowserSession.pendingClose?(nil)
    guard events == ["seed", "release", "dismiss"] else { fatalError("Wrong terminal order: \(events)") }
    controller.close(notify: true)
    guard events == ["seed", "release", "dismiss"] else { fatalError("Double termination") }
    var premature: [String] = []
    let unloaded = AuthenticationController(url: "", goal: .login,
        onFailure: { _ in }, onClosed: { premature.append("dismiss") }, onTeardown: { premature.append("release") })
    unloaded.close(notify: true)
    guard premature == ["release", "dismiss"] else { fatalError("Close before viewDidLoad hung") }
    print("PASS: production browser controller + real WKWebView; seed-close waits for bridge drain, exactly-once teardown, pre-load close (offline synthetic Kotlin boundary)")
}
