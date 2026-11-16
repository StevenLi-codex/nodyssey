import Foundation
import Testing
import NodysseyNativeCore
@testable import AccountBehavior

/// Synthetic callback transport only; no credentials, network or account mutation.
@MainActor final class ProfileFixture {
    var requests: [(@Sendable (String) -> Void)] = []
    var observations: [(@Sendable (String) -> Void)] = []
    var requestArguments: [String] = []
    var observationCancellations = 0
    var requestCancellations = 0
    var transport: CallbackNativeTransport {
        CallbackNativeTransport(request: { [self] operation, arguments, callback in
            #expect(operation == "profile.self")
            requestArguments.append(arguments); requests.append(callback)
            return NativeCancellation { Task { @MainActor in self.requestCancellations += 1 } }
        }, observe: { [self] operation, _, callback in
            #expect(operation == "profile.self")
            observations.append(callback)
            return NativeCancellation { Task { @MainActor in self.observationCancellations += 1 } }
        })
    }
    static let empty = #"{"ok":true,"data":null}"#
    static let reader = #"{"ok":true,"data":{"uid":123,"name":"Synthetic reader"}}"#
    static let changed = #"{"ok":true,"data":{"uid":123,"name":"Updated by Room"}}"#
    static let offline = #"{"ok":false,"error":{"code":"NETWORK","message":""}}"#
}

@Test @MainActor func disappearingProfileCancelsInitialReadAndObservation() async {
    let fixture = ProfileFixture()
    let profile = AccountSelfProfileState()
    let lifetime = Task { await profile.run(using: fixture.transport, currentGeneration: { 1 }) }
    await eventually { fixture.requests.count == 1 && fixture.observations.count == 1 }
    lifetime.cancel(); await lifetime.value
    await eventually { fixture.requestCancellations == 1 && fixture.observationCancellations == 1 }
    fixture.requests[0](ProfileFixture.reader)
    fixture.observations[0](ProfileFixture.reader)
    try? await Task.sleep(for: .milliseconds(10))
    #expect(profile.value == .null && !profile.isLoading && profile.failure == nil)
}

@Test @MainActor func profileGenerationChangeHidesOldValueBeforeRestartAndRejectsLateRefresh() async {
    let fixture = ProfileFixture()
    let profile = AccountSelfProfileState()
    var generation = 1
    let first = Task { await profile.run(using: fixture.transport, currentGeneration: { generation }) }
    await eventually { fixture.requests.count == 1 && fixture.observations.count == 1 }
    fixture.observations[0](ProfileFixture.reader)
    fixture.requests[0](ProfileFixture.reader)
    await eventually { profile.value["uid"]?.int == 123 && !profile.isLoading }
    let refresh = Task { await profile.refresh() }
    await eventually { fixture.requests.count == 2 }
    generation = 2
    fixture.observations[0](ProfileFixture.changed)
    fixture.requests[1](ProfileFixture.offline)
    await refresh.value
    #expect(profile.value == .null)
    #expect(profile.failure == nil)
    let second = Task { await profile.run(using: fixture.transport, currentGeneration: { generation }) }
    await eventually { fixture.requests.count == 3 && fixture.observations.count == 2 }
    first.cancel(); await first.value
    fixture.requests[2](ProfileFixture.reader)
    fixture.observations[1](ProfileFixture.reader)
    await eventually { profile.value["uid"]?.int == 123 && !profile.isLoading }
    fixture.observations[0](ProfileFixture.changed)
    try? await Task.sleep(for: .milliseconds(10))
    #expect(profile.value["name"]?.string == "Synthetic reader")
    second.cancel(); await second.value
    #expect(profile.value["uid"]?.int == 123)
}

@Test @MainActor func profileReturnRetainsSnapshotAndSkipsFreshNetworkRead() async {
    let fixture = ProfileFixture()
    let profile = AccountSelfProfileState()
    let first = Task { await profile.run(using: fixture.transport, currentGeneration: { 1 }) }
    await eventually { fixture.requests.count == 1 && fixture.observations.count == 1 }
    fixture.observations[0](ProfileFixture.reader)
    fixture.requests[0](ProfileFixture.reader)
    await eventually { profile.value["uid"]?.int == 123 && !profile.isLoading }
    first.cancel(); await first.value
    #expect(profile.value["uid"]?.int == 123, "Tab departure must preserve last Room snapshot")
    let second = Task { await profile.run(using: fixture.transport, currentGeneration: { 1 }) }
    await eventually { fixture.observations.count == 2 }
    #expect(profile.value["uid"]?.int == 123, "Reattachment must not erase loaded profile")
    #expect(fixture.requests.count == 1, "Fresh tab return must not force another network fetch")
    second.cancel(); await second.value
}

@Test @MainActor func profileStaleReturnKeepsRoomValueAndCoalescesRefresh() async {
    let fixture = ProfileFixture()
    var uptime: TimeInterval = 100
    let profile = AccountSelfProfileState(now: { uptime })
    let first = Task { await profile.run(using: fixture.transport, currentGeneration: { 1 }) }
    await eventually { fixture.requests.count == 1 && fixture.observations.count == 1 }
    fixture.observations[0](ProfileFixture.reader); fixture.requests[0](ProfileFixture.reader)
    await eventually { !profile.isLoading && profile.value["uid"]?.int == 123 }
    first.cancel(); await first.value
    uptime = 161
    let returned = Task { await profile.run(using: fixture.transport, currentGeneration: { 1 }) }
    await eventually { fixture.requests.count == 2 && fixture.observations.count == 2 }
    #expect(profile.value["uid"]?.int == 123)
    await profile.refresh()
    #expect(fixture.requests.count == 2)
    fixture.requests[1](ProfileFixture.offline)
    await eventually { profile.failure?.code == "NETWORK" }
    #expect(profile.value["uid"]?.int == 123)
    fixture.observations[1](ProfileFixture.changed)
    await eventually { profile.value["name"]?.string == "Updated by Room" }
    returned.cancel(); await returned.value
    #expect(profile.value["name"]?.string == "Updated by Room")
    profile.invalidate()
    #expect(profile.value == .null)
}

@Test @MainActor func failedInitialFetchKeepsNullVisibleAndRetryDoesNotReplaceObserver() async {
    let fixture = ProfileFixture()
    let profile = AccountSelfProfileState()
    let lifetime = Task { await profile.run(using: fixture.transport, currentGeneration: { 1 }) }
    await eventually { fixture.requests.count == 1 && fixture.observations.count == 1 }
    fixture.observations[0](ProfileFixture.empty)
    fixture.requests[0](ProfileFixture.offline)
    await eventually { profile.failure?.code == "NETWORK" && !profile.isLoading }
    #expect(profile.value == .null)
    let retry = Task { await profile.refresh() }
    await eventually { fixture.requests.count == 2 }
    fixture.observations[0](ProfileFixture.reader)
    fixture.requests[1](ProfileFixture.reader)
    await retry.value
    #expect(profile.value["uid"]?.int == 123)
    #expect(profile.failure == nil)
    #expect(fixture.observations.count == 1 && fixture.observationCancellations == 0)
    fixture.observations[0](ProfileFixture.empty)
    await eventually { profile.value == .null }
    lifetime.cancel(); await lifetime.value
}

@Test @MainActor func failedPullRefreshDoesNotCancelFutureRoomUpdates() async {
    let fixture = ProfileFixture()
    let profile = AccountSelfProfileState()
    let lifetime = Task { await profile.run(using: fixture.transport, currentGeneration: { 1 }) }
    await eventually { !fixture.observations.isEmpty }
    fixture.requests.first?(ProfileFixture.reader)
    fixture.observations.first?(ProfileFixture.reader)
    await eventually { profile.value["uid"]?.int == 123 }
    let before = fixture.requests.count
    let refresh = Task { await profile.refresh() }
    await eventually { fixture.requests.count == before + 1 }
    fixture.requests.last?(ProfileFixture.offline)
    await refresh.value
    #expect(profile.failure?.code == "NETWORK")
    #expect(profile.value["uid"]?.int == 123)
    #expect(fixture.observationCancellations == 0)
    fixture.observations.first?(ProfileFixture.changed)
    await eventually { profile.value["name"]?.string == "Updated by Room" }
    #expect(profile.failure?.code == "NETWORK")
    lifetime.cancel(); await lifetime.value
}

@Test @MainActor func emptyRoomStartsInitialProfileFetchAlongsideObservation() async {
    let fixture = ProfileFixture()
    let profile = AccountSelfProfileState()
    let lifetime = Task { await profile.run(using: fixture.transport, currentGeneration: { 1 }) }
    await eventually { !fixture.observations.isEmpty }
    fixture.observations.first?(ProfileFixture.empty)
    await eventually { fixture.requests.count == 1 }
    #expect(profile.isLoading)
    #expect(fixture.requestArguments.first?.contains("refresh") == true)
    fixture.requests.first?(ProfileFixture.reader)
    fixture.observations.first?(ProfileFixture.reader)
    await eventually { profile.value["uid"]?.int == 123 }
    #expect(profile.failure == nil)
    lifetime.cancel(); await lifetime.value
}
