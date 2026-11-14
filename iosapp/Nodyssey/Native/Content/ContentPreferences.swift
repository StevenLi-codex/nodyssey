import Foundation
import NodysseyNativeCore

/// Projection of the shared settings snapshot; no Swift preferences store.
struct ContentPreferences {
    let settings: JSONValue
    var feedSort: String { settings["feedSort"]?.string == "POST_TIME" ? "POST_TIME" : "LAST_REPLY" }
    var homePageBar: Bool { settings["homePageBar"]?.bool ?? true }
}

struct ContentReportMode {
    /// nil follows the shared preference; explicit choices belong to this report only.
    var sourceOverride: Bool? = nil
    func source(settings: JSONValue) -> Bool { sourceOverride ?? (settings["reportFormat"]?.string == "SOURCE") }
}

extension ContentCommand {
    /// The picker reads app.settings; only its shared observer publishes persisted changes.
    @discardableResult
    func setFeedSort(_ sort: String, app: any ContentCommandContext) -> Task<Void, Never>? {
        run(app) {
            guard ["LAST_REPLY", "POST_TIME"].contains(sort) else {
                throw NativeFailure(code: "INVALID_ARGUMENT", message: "Invalid feed sort")
            }
            let generation = app.generation
            _ = try await app.request("settings.set", ["key": .string("feedSort"), "value": .string(sort)])
            try Task.checkCancellation()
            guard generation == app.generation else { throw CancellationError() }
            let snapshot = try await app.request("settings.get", [:])
            try Task.checkCancellation()
            guard generation == app.generation else { throw CancellationError() }
            guard snapshot["feedSort"]?.string == sort else {
                throw NativeFailure(code: "INVALID_DATA", message: "Unable to verify feed sort")
            }
        }
    }
}
