import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeLibrary

// The Linux companion replays these EXECUTED Swift requests through the unchanged
// NativeAccount handler and real NetworkProfile/NetworkAssets repositories. No
// balance result here is a simulated repository assertion.
@MainActor @Test func repositoryAttendanceReadbackTrace() async throws {
    for uncertain in [false, true] {
        var trace: [JSONValue] = []
        _ = try await LibraryOperations.signAttendance(mode: "FIXED_FIVE") { op, args in
            trace.append(.object(["operation": .string(op), "arguments": .object(args)]))
            if uncertain && op == "attendance.sign" { throw NativeFailure(code: "NETWORK", message: "") }
            return .null
        }
        let payload: JSONValue = .object(["scenario": .string(uncertain ? "uncertainAttendance" : "attendance"), "requests": .array(trace)])
        print("LIBRARY_REPOSITORY_TRACE:" + String(decoding: try JSONEncoder().encode(payload), as: UTF8.self))
    }
}

@MainActor @Test func repositoryPaymentReadbackTrace() async throws {
    for uncertain in [false, true] {
        var trace: [JSONValue] = []
        let payment = try LibraryPayment(recipient: "9007199254740993", amount: "8", refId: "0", onetime: false)
        _ = try await LibraryOperations.pay(payment, confirmed: true) { op, args in
            trace.append(.object(["operation": .string(op), "arguments": .object(args)]))
            if uncertain && op == "assets.transfer" { throw NativeFailure(code: "NETWORK", message: "") }
            return .null
        }
        let payload: JSONValue = .object(["scenario": .string(uncertain ? "uncertainPayment" : "payment"), "requests": .array(trace)])
        print("LIBRARY_REPOSITORY_TRACE:" + String(decoding: try JSONEncoder().encode(payload), as: UTF8.self))
    }
}
