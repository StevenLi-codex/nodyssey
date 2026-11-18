import Foundation
import Testing
@testable import AccountBehavior

@Test @MainActor func cancelledPageReadReleasesBusyBeforeUncooperativeDrain() async {
    let work = AccountReadFlightState()
    var release: CheckedContinuation<Void, Never>?
    var published = false
    let task = Task { await work.run(key: "page", current: { true }) { accepted in
        await withCheckedContinuation { release = $0 }
        if accepted() { published = true }
        return true
    } }
    while release == nil { await Task.yield() }
    task.cancel()
    for _ in 0..<50 { await Task.yield() }
    #expect(!work.isLoading)
    release?.resume()
    #expect(await task.value == false)
    #expect(!published)
}
