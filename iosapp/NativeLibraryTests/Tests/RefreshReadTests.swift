import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeLibrary

@Test @MainActor func bookmarkRefreshJoinsToolbarAndFencesOldFailure() async {
    let read = LibraryRefreshReadState()
    var release: CheckedContinuation<JSONValue, any Error>?
    var calls = 0
    var generation = 1
    var failures: [NativeFailure] = []
    var published: [JSONValue] = []
    let request: @MainActor () async throws -> JSONValue = {
        calls += 1
        return try await withCheckedThrowingContinuation { release = $0 }
    }
    let first = Task { await read.run(key: "1", current: { generation == 1 }, request: request, publish: { published.append($0) }, fail: { failures.append($0) }) }
    while release == nil { await Task.yield() }
    var joinedDone = false
    let joined = Task { let result = await read.run(key: "1", current: { generation == 1 }, request: request, publish: { published.append($0) }, fail: { failures.append($0) }); joinedDone = true; return result }
    for _ in 0..<20 { await Task.yield() }
    #expect(calls == 1 && !joinedDone && read.isLoading)
    generation = 2
    release?.resume(throwing: NativeFailure(code: "NETWORK", message: ""))
    #expect(await first.value == false)
    #expect(await joined.value == false)
    #expect(failures.isEmpty && published.isEmpty && !read.isLoading)
}

@Test @MainActor func readbackDoesNotPublishOldGenerationFailure() async {
    var release: CheckedContinuation<JSONValue, any Error>?
    var current = true
    var failures: [NativeFailure] = []
    let task = Task { await LibraryRefreshReadState.read(current: { current }, request: {
        try await withCheckedThrowingContinuation { release = $0 }
    }, publish: { _ in Issue.record("No successful value expected") }, fail: { failures.append($0) }) }
    while release == nil { await Task.yield() }
    current = false
    release?.resume(throwing: NativeFailure(code: "NETWORK", message: ""))
    #expect(await task.value == false)
    #expect(failures.isEmpty)
}
