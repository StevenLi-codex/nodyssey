import Foundation
import Testing
@testable import NativeContentState
import NodysseyNativeCore

@Test func reopenedFeedUsesStoredSortAndHidesOptionalPageBar() {
    let stored: JSONValue = .object(["feedSort": .string("POST_TIME"), "homePageBar": .bool(false)])
    let reopened = ContentPreferences(settings: stored)
    #expect(reopened.feedSort == "POST_TIME")
    #expect(!reopened.homePageBar)
    let defaults = ContentPreferences(settings: .null)
    #expect(defaults.feedSort == "LAST_REPLY")
    #expect(defaults.homePageBar)
}

@Test func reportDefaultFollowsSettingsUntilExplicitPerReportOverride() {
    let source: JSONValue = .object(["reportFormat": .string("SOURCE")])
    let adapted: JSONValue = .object(["reportFormat": .string("ADAPTED")])
    var report = ContentReportMode()
    #expect(report.source(settings: source))
    #expect(!report.source(settings: adapted))
    report.sourceOverride = false
    #expect(!report.source(settings: source))
    report.sourceOverride = true
    #expect(report.source(settings: adapted))
    #expect(!ContentReportMode().source(settings: .null))
    #expect(ContentReportMode().source(settings: source))
}

@Test @MainActor func sortSelectionUsesExactSettingsMutationAndAuthoritativeReadback() async {
    let app = ScriptedContentContext()
    let command = ContentCommand()
    var persisted: JSONValue = .object(["feedSort": .string("LAST_REPLY")])
    app.respond = { operation, arguments in
        if operation == "settings.set" {
            #expect(arguments == ["key": .string("feedSort"), "value": .string("POST_TIME")])
            persisted = .object(["feedSort": .string("POST_TIME")])
        }
        return persisted
    }
    await command.setFeedSort("POST_TIME", app: app)?.value
    #expect(app.calls.map(\.0) == ["settings.set", "settings.get"])
    #expect(command.failure == nil)
    #expect(ContentPreferences(settings: persisted).feedSort == "POST_TIME")
}

@Test @MainActor func sortReadbackMismatchIsNotReportedAsSuccess() async {
    let app = ScriptedContentContext()
    let command = ContentCommand()
    app.respond = { _, _ in .object(["feedSort": .string("LAST_REPLY")]) }
    await command.setFeedSort("POST_TIME", app: app)?.value
    #expect(command.failure?.code == "INVALID_DATA")
}

@Test(arguments: ["cancel", "session"])
@MainActor func obsoleteSortSelectionNeverStartsAWrite(_ reason: String) async {
    let app = ScriptedContentContext()
    let command = ContentCommand()
    let task = command.setFeedSort("POST_TIME", app: app)
    if reason == "cancel" { command.cancel() } else { app.generation += 1 }
    await task?.value
    #expect(app.calls.isEmpty)
    #expect(command.failure == nil)
}

@Test @MainActor func failedSortWriteDoesNotReadbackOrInventPersistedPreference() async {
    let app = ScriptedContentContext()
    let command = ContentCommand()
    app.respond = { _, _ in throw NativeFailure(code: "NETWORK", message: "Write failed") }
    await command.setFeedSort("POST_TIME", app: app)?.value
    #expect(command.failure?.code == "NETWORK")
    #expect(app.calls.map(\.0) == ["settings.set"])
}
