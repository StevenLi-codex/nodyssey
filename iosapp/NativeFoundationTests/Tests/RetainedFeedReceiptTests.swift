import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeFoundation

@MainActor private final class ReceiptCallbackProbe {
    var requests: [(@Sendable (String) -> Void)] = []
    var arguments: [[String: JSONValue]] = []
    var observations: [(@Sendable (String) -> Void)] = []
    lazy var transport = CallbackNativeTransport(request: { [weak self] name, json, reply in
        precondition(name == "paging.refresh")
        self?.arguments.append((try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)).object) ?? [:])
        self?.requests.append(reply)
        return NativeCancellation { }
    }, observe: { [weak self] _, _, reply in
        self?.observations.append(reply)
        return NativeCancellation { }
    })
    func emit(_ value: JSONValue, at index: Int) throws {
        let data = try JSONEncoder().encode(JSONValue.object(["ok": .bool(true), "data": value]))
        observations[index](String(decoding: data, as: UTF8.self))
    }
}

@MainActor private final class ReceiptFlight {
    var result: Bool?
    var joined: Bool?
    var first: Task<Void, Never>?
    var second: Task<Void, Never>?
}

@Suite @MainActor struct RetainedFeedReceiptTests {
    @Test func actualRoomPagingTraceRequiresEachCommandReceiptAndJoinsWaiters() async throws {
        let url = try #require(Bundle.module.url(forResource: "RetainedRefreshTrace", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        let events = fixture.nativeArray("events")
        #expect(!events.isEmpty)
        let probe = ReceiptCallbackProbe()
        let app = NativeAppModel(transport: probe.transport)
        let store = NativeStore(refreshTimeout: 2)
        defer { store.cancel() }
        var observer = -1
        var currentPager = ""
        var tokenMap: [String: String] = [:]
        var flight: ReceiptFlight?
        var commandCount = 0
        var completedCount = 0
        var currentToken = ""
        func mapped(_ snapshot: JSONValue) -> JSONValue {
            var fields = snapshot.object ?? [:]
            for name in ["refreshReceipt", "refreshFailure"] {
                if let old = fields[name]?.string, let actual = tokenMap[old] { fields[name] = .string(actual) }
            }
            return .object(fields)
        }
        for event in events {
            switch event.nativeString("kind") {
            case "observe":
                observer += 1
                let args = event["arguments"]?.object ?? [:]
                currentPager = args["pagerId"]?.string ?? ""
                #expect(store.observeRetained(app, "feed", args))
                try await eventually { probe.observations.count == observer + 1 }
            case "command":
                commandCount += 1
                let args = event["arguments"]?.object ?? [:]
                let next = ReceiptFlight()
                next.first = Task { next.result = await store.refreshRetained(app, "paging.refresh", ["pagerId": args["pagerId"]!], mode: .paging) }
                flight = next
                try await eventually { probe.requests.count == commandCount }
                currentToken = probe.arguments.last?["refreshToken"]?.string ?? "MISSING-TOKEN"
                #expect(currentToken != "MISSING-TOKEN", "Opt-in feeds bind transport to a new per-command token")
                #expect(!tokenMap.values.contains(currentToken), "A lifetime token cannot complete a second command")
                tokenMap[args["refreshToken"]?.string ?? ""] = currentToken
                next.second = Task { next.joined = await store.refreshRetained(app, "paging.refresh", ["pagerId": args["pagerId"]!], mode: .paging) }
                for _ in 0..<30 { await Task.yield() }
                #expect(probe.requests.count == commandCount, "Multiple Swift waiters share one remote command")
            case "command_ack":
                probe.requests[commandCount - 1](#"{"ok":true,"data":null}"#)
                for _ in 0..<30 { await Task.yield() }
                #expect(flight?.result == nil && flight?.joined == nil, "ACK is not a Room presentation receipt")
            case "snapshot":
                let snapshot = mapped(event["snapshot"] ?? .null)
                guard snapshot.nativeString("pagerId") == currentPager else { continue }
                try probe.emit(snapshot, at: observer)
                for _ in 0..<30 { await Task.yield() }
                if let flight, snapshot["refreshReceipt"]?.string != currentToken && snapshot["refreshFailure"]?.string != currentToken {
                    #expect(flight.result == nil && flight.joined == nil,
                            "Cached Loading/NotLoading, old token, and previous Error must not finish this command")
                }
            case "first_store_style_terminal":
                let expected = event["snapshot"]?["refresh"]?.nativeString("status") != "Error"
                let current = try #require(flight)
                await current.first?.value
                await current.second?.value
                #expect(current.result == expected && current.joined == expected)
                #expect(store.value.nativeArray("items") == event["snapshot"]?.nativeArray("items"))
                completedCount += 1
                flight = nil
            case "closed":
                store.cancel()
                if let flight {
                    await flight.first?.value; await flight.second?.value
                    #expect(flight.result == false && flight.joined == false, "Closing a held old owner cannot succeed")
                }
                flight = nil
            default: break
            }
        }
        #expect(commandCount == 12 && completedCount == 11)
        #expect(probe.requests.count == commandCount && probe.observations.count == 4)
    }

    @Test func receiptCanArriveWithoutLoadingAndCancelledWaiterCannotCancelJoinedWork() async throws {
        let probe = ReceiptCallbackProbe()
        let app = NativeAppModel(transport: probe.transport)
        let store = NativeStore(refreshTimeout: 1)
        defer { store.cancel() }
        store.observeRetained(app, "feed", ["pagerId": .string("pager")])
        try await eventually { probe.observations.count == 1 }
        func snapshot(_ token: String?) -> JSONValue {
            .object(["pagerId": .string("pager"), "items": .array([]), "refreshReceiptVersion": .integer(1),
                     "remoteRefreshComplete": .bool(true), "refreshReceipt": token.map(JSONValue.string) ?? .null,
                     "refresh": .object(["status": .string("NotLoading")])])
        }
        try probe.emit(snapshot(nil), at: 0)
        try await eventually { store.hasValue }
        let first = Task { await store.refreshRetained(app, "paging.refresh", ["pagerId": .string("pager")], mode: .paging) }
        try await eventually { probe.requests.count == 1 }
        var result: Bool?
        let joined = Task { result = await store.refreshRetained(app, "paging.refresh", ["pagerId": .string("pager")], mode: .paging) }
        for _ in 0..<30 { await Task.yield() }
        first.cancel()
        #expect(await first.value == false)
        probe.requests[0](#"{"ok":true,"data":null}"#)
        try probe.emit(snapshot("old-lifetime-token"), at: 0)
        for _ in 0..<30 { await Task.yield() }
        #expect(result == nil)
        let token = try #require(probe.arguments[0]["refreshToken"]?.string)
        try probe.emit(snapshot(token), at: 0)
        await joined.value
        #expect(result == true && probe.requests.count == 1)
    }

    @Test func matchingPresentationSurvivesLocalLoadingBeforeCommandAck() async throws {
        let held = HeldReceiptRefresh()
        defer { held.store.cancel() }
        let refresh = try await held.start()
        try await held.presentReceiptThenLoad()

        held.acknowledge() // No subsequent snapshot or receipt is delivered.

        #expect(await refresh.value == true)
        #expect(held.store.failure == nil)
        #expect(held.store.value["refresh"]?.nativeString("status") == "Loading")
        #expect(held.probe.requests.count == 1)
    }

    @Test func laterNonmatchingTerminalDoesNotEraseMatchingPresentation() async throws {
        let held = HeldReceiptRefresh()
        defer { held.store.cancel() }
        let refresh = try await held.start()
        try await held.presentReceiptThenLoad()
        try await held.present("NotLoading", receipt: "older-command")

        held.acknowledge()

        #expect(await refresh.value == true)
        #expect(held.store.failure == nil)
    }

    @Test func ownerRevocationRejectsLateAckAfterMatchingPresentationAndLocalLoading() async throws {
        let held = HeldReceiptRefresh()
        defer { held.store.cancel() }
        held.app.session = .object(["identityEpoch": .string("first"), "isSignedIn": .bool(true)])
        let generation = held.app.generation
        let refresh = try await held.start()
        try await held.presentReceiptThenLoad()

        held.app.session = .object(["identityEpoch": .string("next"), "isSignedIn": .bool(true)])
        held.acknowledge()

        #expect(held.app.generation != generation)
        #expect(await refresh.value == false)
        #expect(held.store.value == .null)
        #expect(held.store.failure == nil)
    }

    @Test func commandErrorWinsAfterMatchingPresentationAndLocalLoading() async throws {
        let held = HeldReceiptRefresh()
        defer { held.store.cancel() }
        let refresh = try await held.start()
        try await held.presentReceiptThenLoad()

        held.probe.requests[0](#"{"ok":false,"error":{"code":"COMMAND_FAILED","message":"Rejected"}}"#)

        #expect(await refresh.value == false)
        #expect(held.store.failure?.code == "COMMAND_FAILED")
    }

    @Test func legacyNewLoadingClearsOldTerminalBeforeAck() async throws {
        let held = HeldReceiptRefresh(advertisesReceipt: false)
        defer { held.store.cancel() }
        let refresh = try await held.start()
        #expect(held.probe.arguments[0]["refreshToken"] == nil)
        try await held.present("Loading")
        try await held.present("NotLoading")
        try await held.present("Loading")

        held.acknowledge() // The latest Loading never receives a terminal.

        #expect(await refresh.value == false)
        #expect(held.store.failure?.code == "REFRESH_TIMEOUT")
    }
}

@MainActor private struct HeldReceiptRefresh {
    let probe: ReceiptCallbackProbe
    let app: NativeAppModel
    let store = NativeStore(refreshTimeout: 1)
    let advertisesReceipt: Bool
    let arguments: [String: JSONValue] = ["pagerId": .string("pager")]

    init(advertisesReceipt: Bool = true) {
        let probe = ReceiptCallbackProbe()
        self.probe = probe
        self.app = NativeAppModel(transport: probe.transport)
        self.advertisesReceipt = advertisesReceipt
    }

    func start() async throws -> Task<Bool, Never> {
        #expect(store.observeRetained(app, "feed", arguments))
        try await eventually { probe.observations.count == 1 }
        try await present("NotLoading")
        let refresh = Task { await store.refreshRetained(app, "paging.refresh", arguments, mode: .paging) }
        try await eventually { probe.requests.count == 1 }
        return refresh
    }

    func present(_ status: String, receipt: String? = nil) async throws {
        var fields: [String: JSONValue] = ["pagerId": .string("pager"), "items": .array([]),
                                          "refresh": .object(["status": .string(status)])]
        if advertisesReceipt { fields["refreshReceiptVersion"] = .integer(1) }
        if let receipt { fields["refreshReceipt"] = .string(receipt) }
        let snapshot = JSONValue.object(fields)
        try probe.emit(snapshot, at: 0)
        try await eventually { store.value == snapshot }
    }

    func presentReceiptThenLoad() async throws {
        let token = try #require(probe.arguments[0]["refreshToken"]?.string)
        try await present("NotLoading", receipt: token)
        try await present("Loading")
    }

    func acknowledge() {
        probe.requests[0](#"{"ok":true,"data":null}"#)
    }
}
