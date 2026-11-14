import Foundation
import Testing
@testable import NodysseyNativeCore

struct JSONValueTests {
    @Test func requiredIdentityRejectsMissingAndWrongTypes() throws {
        for value: JSONValue in [.null, .object([:]), .object(["id": .string("7")]), .object(["id": .bool(true)]), .object(["id": .number(7)])] {
            #expect(throws: NativeFailure(code: "INVALID_DATA", message: "Expected integer field: id")) {
                try value.requireInt("id")
            }
        }
        #expect(try JSONValue.object(["id": .integer(Int64.max)]).requireInt("id") == Int64.max)
    }

    @Test func envelopesDistinguishAcknowledgementFailureAndMalformedPayload() throws {
        #expect(try NativeEnvelope.decode(#"{"ok":true,"data":null}"#) == .null)
        #expect(try NativeEnvelope.decode(#"{"ok":true,"data":{"id":9007199254740993}}"#)["id"]?.int == 9007199254740993)
        #expect(throws: NativeFailure(code: "AUTH_REQUIRED", message: "Sign in")) {
            try NativeEnvelope.decode(#"{"ok":false,"error":{"code":"AUTH_REQUIRED","message":"Sign in"}}"#)
        }
        for source in ["not-json", #"{"ok":1,"data":0}"#, #"{"ok":true}"#, #"{"ok":false,"error":{}}"#, #"{"ok":false,"error":{"code":"X","message":3}}"#] {
            #expect(throws: NativeFailure(code: "INVALID_ENVELOPE", message: "Invalid native response")) {
                try NativeEnvelope.decode(source)
            }
        }
    }

    @Test func nestedPayloadRoundTripsIntegerIdentityWithoutDoubleRounding() throws {
        let source = #"{"id":9223372036854775807,"rows":[{"id":9007199254740993}],"negative":-9223372036854775808,"ratio":1.25,"flag":true,"name":"hello","empty":null}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
        #expect(value["id"]?.int == Int64.max)
        #expect(value["rows"]?.array?.first?["id"]?.int == 9007199254740993)
        #expect(value["negative"]?.int == Int64.min)
        #expect(value["ratio"] == .number(1.25))
        #expect(value["flag"]?.bool == true)
        #expect(value["name"]?.string == "hello")
        #expect(value["empty"] == .null)
        #expect(value.object?.count == 7)
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
    }
}
