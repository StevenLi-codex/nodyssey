import Foundation

public struct NativeFailure: Error, Codable, Equatable, Sendable, LocalizedError {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum NativeEnvelope {
    public static func decode(_ json: String) throws -> JSONValue {
        let invalid = NativeFailure(code: "INVALID_ENVELOPE", message: "Invalid native response")
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)),
              let ok = root["ok"]?.bool else { throw invalid }
        if ok {
            guard let data = root["data"] else { throw invalid }
            return data
        }
        guard let code = root["error"]?["code"]?.string, !code.isEmpty,
              let message = root["error"]?["message"]?.string else { throw invalid }
        throw NativeFailure(code: code, message: message)
    }
}
