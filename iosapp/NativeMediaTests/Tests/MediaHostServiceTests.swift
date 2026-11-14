import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeMedia

/// Synthetic transport exercises production orchestration; never connects to a host.
actor MediaRecordingTransport: NativeTransport {
    var selected = "NODE_IMAGE"
    var calls: [String] = []
    var switchDuringListing = false
    var switchBeforeListing = false
    var restoreOnNextGet = false
    func switchAwayForNextListing() { switchBeforeListing = true }
    var switchBeforeDelete = false
    var deletedProviders: [String] = []
    var deletionArguments: [String: JSONValue]?
    func switchOnNextDelete() { switchBeforeDelete = true }
    func deletions() -> [String] { deletedProviders }
    func lastDeletionArguments() -> [String: JSONValue]? { deletionArguments }
    func switchOnNextListing() { switchDuringListing = true }
    var rows: JSONValue = .array([.object(["id": .string("exact-id"), "url": .string("https://e.test/a.png")])])
    func select(_ name: String) { selected = name }
    func operations() -> [String] { calls }
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        calls.append(operation)
        switch operation {
        case "imageHost.get":
            if restoreOnNextGet { selected = "NODE_IMAGE"; restoreOnNextGet = false }
            return .object(["provider": .string(selected)])
        case "settings.capabilities": return .object(["imageHosts": .array([
            .object(["provider": .string("NODE_IMAGE"), "browsable": .bool(true)]),
            .object(["provider": .string("IMGBB"), "browsable": .bool(false)])])])
        case "imageHost.images":
            if switchBeforeListing { selected = "SMMS"; switchBeforeListing = false; restoreOnNextGet = true }
            if let expected = arguments["expectedProvider"]?.string, expected != selected {
                throw NativeFailure(code: "SOURCE_CHANGED", message: "Provider changed")
            }
            if switchDuringListing { selected = "IMGBB"; switchDuringListing = false }
            return rows
        case "imageHost.delete":
            deletionArguments = arguments
            if switchBeforeDelete { selected = "SMMS"; switchBeforeDelete = false }
            // Test-only contract transport. The real Kotlin gate is exercised by the JVM harness.
            guard arguments["expectedProvider"]?.string == selected else {
                throw NativeFailure(code: "SOURCE_CHANGED", message: "Provider changed")
            }
            deletedProviders.append(selected)
            rows = .array([]); return .null
        default: throw NativeFailure(code: "UNEXPECTED", message: "Unexpected request")
        }
    }
    nonisolated func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Test @MainActor func deleteRequiresConfirmationAndRefusesChangedProvider() async throws {
    let transport = MediaRecordingTransport()
    let service = MediaHostService(transport: transport)
    let images = try await service.list(provider: "NODE_IMAGE")
    #expect(images.count == 1)
    #expect(!(await transport.operations()).contains("imageHost.delete"))
    let ticket = try service.confirmation(for: "exact-id")
    await transport.select("IMGBB")
    await #expect(throws: NativeFailure.self) { try await service.deleteConfirmed(ticket) }
    #expect(!(await transport.operations()).contains("imageHost.delete"))
    await transport.select("NODE_IMAGE")
    try await service.deleteConfirmed(ticket)
    #expect(service.images.isEmpty)
    let operations = await transport.operations()
    #expect(operations.lastIndex(of: "imageHost.images")! > operations.lastIndex(of: "imageHost.delete")!)
}

@Test @MainActor func providerSwitchAfterFinalCheckRejectsWithoutRetryOrRemovingDisplayedRows() async throws {
    let transport = MediaRecordingTransport()
    let service = MediaHostService(transport: transport)
    _ = try await service.list(provider: "NODE_IMAGE")
    let ticket = try service.confirmation(for: "exact-id")
    await transport.switchOnNextDelete()
    do {
        try await service.deleteConfirmed(ticket)
        Issue.record("Stale provider deletion must be rejected")
    } catch let failure as NativeFailure {
        #expect(failure.code == "SOURCE_CHANGED")
    }
    #expect((await transport.deletions()).isEmpty)
    #expect(service.images.map(\.id) == ["exact-id"])
    #expect((await transport.operations()).filter { $0 == "imageHost.delete" }.count == 1)
    #expect((await transport.operations()).last == "imageHost.delete")
    let arguments = await transport.lastDeletionArguments()
    #expect(arguments?["expectedProvider"]?.string == "NODE_IMAGE")
    #expect(arguments?["id"]?.string == "exact-id")
}

@Test @MainActor func switchAwayAndBackAroundListingCannotGrantWrongProviderTicket() async throws {
    let transport = MediaRecordingTransport()
    let service = MediaHostService(transport: transport)
    await transport.switchAwayForNextListing()
    await #expect(throws: NativeFailure.self) { try await service.list(provider: "NODE_IMAGE") }
    #expect(service.images.isEmpty)
    #expect(throws: NativeFailure.self) { try service.confirmation(for: "exact-id") }
}

@Test @MainActor func providerChangeDuringListCannotGrantDeletionPermission() async throws {
    let transport = MediaRecordingTransport()
    let service = MediaHostService(transport: transport)
    await transport.switchOnNextListing()
    await #expect(throws: NativeFailure.self) { try await service.list(provider: "NODE_IMAGE") }
    #expect(service.images.isEmpty)
    #expect(throws: NativeFailure.self) { try service.confirmation(for: "exact-id") }
}

@Test @MainActor func uploadOnlyHostDoesNotRequestAnEmptyGallery() async throws {
    let transport = MediaRecordingTransport()
    await transport.select("IMGBB")
    let service = MediaHostService(transport: transport)
    await #expect(throws: NativeFailure.self) { try await service.list(provider: "IMGBB") }
    #expect(!(await transport.operations()).contains("imageHost.images"))
}
