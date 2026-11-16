import Foundation
import NodysseyNativeCore

var failures = 0
var checks = 0
func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures += 1; print("FAIL: \(message)") }
}
func secretPatchTests() throws {
    var draft = SettingsProxyDraft(snapshot: .object([
        "host": .string("localhost"), "port": .integer(8080), "type": .string("HTTP"),
        "scope": .string("EVERYTHING"), "username": .string("reader"), "hasPassword": .bool(true)
    ]))
    check(try draft.payload()["password"] == nil, "untouched password must be omitted, never erase saved credential")
    draft.password = "new transient secret"
    draft.passwordChanged = true
    check(try draft.payload()["password"] == .string("new transient secret"), "edited password must be submitted")
    draft.password = ""
    check(try draft.payload()["password"] == .string(""), "explicit clear must remain distinguishable from omission")
    draft.port = "+80"
    do { _ = try draft.payload(); check(false, "signed port text must not silently normalize") } catch { check(true, "signed port rejected") }
    draft.port = "70000"
    do { _ = try draft.payload(); check(false, "invalid port must not reach bridge") } catch { check(true, "invalid port rejected") }
}
func dohSelectionTests() throws {
    let legacy: [JSONValue] = [
        .object(["id": .string("CLOUDFLARE"), "preset": .string("CLOUDFLARE"), "checked": .bool(true), "bootstrapOverride": .null]),
        .object(["id": .string("custom"), "preset": .null, "customUrl": .string("https://resolver.example/dns-query"), "checked": .bool(true)])
    ]
    let selected = try SettingsDohSelection.select("custom", servers: legacy)
    check(selected.filter { $0["checked"]?.bool == true }.count == 1, "Apple save must not carry legacy multi-selection")
    check(selected[1]["checked"] == .bool(true), "select requested resolver, not first legacy row")
    check(selected[0]["bootstrapOverride"] == .null, "preserve bootstrap default-versus-empty distinction")
    do { _ = try SettingsDohSelection.select("missing", servers: legacy); check(false, "missing resolver must not deselect every row") } catch { check(true, "missing resolver rejected") }
}
func staleCompletionTests() {
    var gate = SettingsRequestGate()
    let old = gate.begin()!
    check(gate.begin() == nil, "double tap cannot queue second mutation")
    gate.invalidate()
    let current = gate.begin()!
    check(!gate.finish(old), "dismissed request cannot publish into reopened screen")
    check(gate.isBusy, "stale completion cannot unlock current write")
    check(gate.finish(current), "current completion publishes")
    check(!gate.isBusy, "current failure/success releases gate")
}
func colorTests() {
    check(SettingsColor.argb("#FFFFFF") == -1, "ARGB must cross bridge as signed Int32")
    check(SettingsColor.argb("000000") == Int64(Int32.min) * 2 + 0xFF000000, "opaque black uses alpha FF")
    check(SettingsColor.argb("#ABC") == nil, "partial input is not a committed color")
    check(SettingsColor.argb(" FFFFFF") == nil, "do not repair malformed hex")
    check(SettingsColor.hex(-1) == "#FFFFFF", "saved negative ARGB survives display conversion")
}
func releaseNotesTests() throws {
    let empty = try SettingsReleaseNotes.decode(.object(["releases": .array([])]))
    check(empty.isEmpty, "valid published empty release list is allowed")
    do { _ = try SettingsReleaseNotes.decode(.object([:])); check(false, "malformed response must never become empty success") } catch { check(true, "missing releases rejected") }
    let release: JSONValue = .object(["tag": .string("v1.2"), "versionName": .string("1.2"), "publishedOn": .string("2026-01-01"), "preRelease": .bool(false), "text": .string("Real published notes"), "htmlUrl": .string("https://evil.example/release")])
    let parsed = try SettingsReleaseNotes.decode(.object(["releases": .array([release])]))
    check(parsed[0].text == "Real published notes", "display actual release text, not a synthesized summary")
    check(parsed[0].url == nil, "reject release links outside original project")
}
func keywordEditedDraftTest() {
    var draft = SettingsKeywordDraft()
    draft.text = "A"
    let submittedRevision = draft.revision
    // The saved success callback runs only after the user has edited again.
    let succeed = { draft.clearAfterSuccess(submittedRevision: submittedRevision) }
    draft.text = "B"
    succeed()
    check(draft.text == "B", "delayed keyword A success must preserve newer draft B")
}
func keywordUnchangedDraftTest() {
    var draft = SettingsKeywordDraft()
    draft.text = "A"
    let submittedRevision = draft.revision
    draft.clearAfterSuccess(submittedRevision: submittedRevision)
    check(draft.text.isEmpty, "successful unchanged keyword A must clear")
}
func keywordReenteredDraftTest() {
    var draft = SettingsKeywordDraft()
    draft.text = "A"
    let submittedRevision = draft.revision
    draft.text = "B"
    draft.text = "A"
    draft.clearAfterSuccess(submittedRevision: submittedRevision)
    check(draft.text == "A", "A to B to A edits must not be mistaken for the submitted revision")
}

#if SETTINGS_ACTION_TESTS
import SwiftUI

// Synthetic delayed app boundary. Compile the actual SettingsComponents.swift:
// neither SettingsAction nor its request/session gate is duplicated here.
@MainActor final class NativeAppModel: ObservableObject {
    @Published var settings: JSONValue = .null
    @Published var generation = 0
    var arguments: [String: JSONValue] = [:]
    var requestCount = 0
    var pending: CheckedContinuation<JSONValue, Error>?
    var returned = false
    var respond: ((String, [String: JSONValue]) async throws -> JSONValue)?
    func request(_ operation: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        if let respond { return try await respond(operation, arguments) }
        precondition(operation == "keywords.add")
        self.arguments = arguments
        requestCount += 1
        defer { returned = true }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func open(_ route: String, _ arguments: [String: JSONValue] = [:]) { fatalError("Not exercised") }
}
@MainActor final class NativeStore: ObservableObject {
    @Published var isLoading = false
    @Published var failure: NativeFailure?
}
struct NativeFailureView: View {
    let failure: NativeFailure
    var retry: (() -> Void)? = nil
    var body: some View { EmptyView() }
}
@MainActor func waitForKeywordAction(_ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline { await Task.yield() }
    return condition()
}
@MainActor func keywordActionTests() async {
    let cases: [(name: String, edits: [String], fail: Bool, changeGeneration: Bool, cancel: Bool, expected: String)] = [
        ("edited success", ["B"], false, false, false, "B"),
        ("unchanged success", [], false, false, false, ""),
        ("reentered success", ["B", "A"], false, false, false, "A"),
        ("unchanged failure", [], true, false, false, "A"),
        ("edited failure", ["B"], true, false, false, "B"),
        ("generation changed before lifecycle cancellation", [], false, true, false, "A"),
        ("generation cancellation", [], false, true, true, "A")
    ]
    for scenario in cases {
        let app = NativeAppModel()
        let action = SettingsAction()
        var draft = SettingsKeywordDraft()
        draft.text = "A"
        let submittedRevision = draft.revision
        var readback: JSONValue = .null
        action.run(app, "keywords.add", ["kind": .string("BLOCK"), "text": .string(draft.text)]) {
            readback = $0
            draft.clearAfterSuccess(submittedRevision: submittedRevision)
        }
        action.run(app, "keywords.add", ["text": .string("duplicate")]) { _ in
            check(false, "\(scenario.name): duplicate must not publish")
        }
        guard await waitForKeywordAction({ app.pending != nil }) else {
            check(false, "\(scenario.name): request did not start")
            action.cancel()
            continue
        }
        for edit in scenario.edits { draft.text = edit }
        check(app.arguments["text"] == .string("A") && app.requestCount == 1,
              "\(scenario.name): captures A and rejects duplicate submission")
        if scenario.changeGeneration { app.generation += 1 }
        if scenario.cancel { action.cancel() } // Same call made by SettingsLifecycle.
        let response: JSONValue = .array([.string("A")])
        let pending = app.pending!
        app.pending = nil
        if scenario.fail {
            pending.resume(throwing: NativeFailure(code: "INVALID_ARGUMENT", message: "Synthetic invalid keyword"))
        } else {
            // Deliberately deliver even after cancellation to exercise the late-reply guard.
            pending.resume(returning: response)
        }
        guard await waitForKeywordAction({ app.returned }) else {
            check(false, "\(scenario.name): completion did not return")
            continue
        }
        check(draft.text == scenario.expected, "\(scenario.name): preserves or clears the correct draft")
        let publishes = !scenario.fail && !scenario.changeGeneration
        check(readback == (publishes ? response : .null), "\(scenario.name): only current success publishes readback")
        check(!action.busy, "\(scenario.name): releases the request gate")
        check((action.failure?.code == "INVALID_ARGUMENT") == scenario.fail,
              "\(scenario.name): failure is not converted to success")
    }
}
@MainActor func themeActionTests() async {
    // Scripted bridge receipts, not a replacement preference store. DataStore reopen
    // is covered independently by NativeSettingsPersistenceTest.
    for (key, value, source) in [("seedColor", JSONValue.integer(-65536), "CUSTOM"),
                                  ("presetId", JSONValue.string("reimu"), "PRESET")] {
        let app = NativeAppModel()
        let action = SettingsAction()
        let before: JSONValue = .object(["colorSource": .string(source == "CUSTOM" ? "PRESET" : "CUSTOM")])
        let written: JSONValue = .object([key: value, "colorSource": before["colorSource"]!])
        let applied: JSONValue = .object([key: value, "colorSource": .string(source)])
        app.settings = before
        var calls: [(String, [String: JSONValue])] = []
        app.respond = { operation, arguments in
            calls.append((operation, arguments))
            if operation == "settings.get" { return applied }
            return arguments["key"] == .string("colorSource") ? applied : written
        }
        action.setting(app, key, value)
        _ = await waitForKeywordAction { !action.busy }
        check(app.settings == applied, "\(key): choosing a color activates its source, not just its dormant value")
        check(calls.map(\.0) == ["settings.set", "settings.set", "settings.get"], "\(key): verify active color through authoritative readback")
        check(calls.first?.1 == ["key": .string(key), "value": value], "\(key): preserves exact bridge payload")
        check(action.failure == nil, "\(key): valid readback succeeds")
    }
    for outcome in ["sourceRefused", "finalMismatch", "readFailure", "cancel", "generation"] {
        let app = NativeAppModel()
        let action = SettingsAction()
        var operations: [String] = []
        var continuation: CheckedContinuation<JSONValue, Error>?
        app.respond = { operation, arguments in
            operations.append(operation)
            if operations.count == 1 {
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }
            if arguments["key"] == .string("colorSource") {
                return .object(["colorSource": .string(outcome == "sourceRefused" ? "PRESET" : "CUSTOM")])
            }
            if outcome == "readFailure" { throw NativeFailure(code: "NETWORK", message: "Synthetic read failure") }
            return .object(["seedColor": .integer(-1), "colorSource": .string("PRESET")])
        }
        action.setting(app, "seedColor", .integer(-65536))
        guard await waitForKeywordAction({ continuation != nil }) else { check(false, "theme write did not start"); continue }
        if outcome == "cancel" { action.cancel() }
        if outcome == "generation" { app.generation += 1 }
        continuation!.resume(returning: .object(["seedColor": .integer(-65536), "colorSource": .string("PRESET")]))
        _ = await waitForKeywordAction { !action.busy }
        // Yield once after a cancelled action's already-cleared busy flag.
        await Task.yield()
        check(app.settings == .null, "\(outcome): unverified or obsolete color never publishes")
        check(!action.busy, "\(outcome): color gate released")
        if ["cancel", "generation"].contains(outcome) {
            check(operations == ["settings.set"], "\(outcome): stale color cannot activate a source or read")
        } else {
            check(action.failure?.code == (outcome == "readFailure" ? "NETWORK" : "INVALID_DATA"), "\(outcome): explicit color failure remains visible")
        }
    }
    for key in ["seedColor", "presetId", "themeMode", "colorSource", "paletteStyle"] {
        let app = NativeAppModel()
        let action = SettingsAction()
        app.respond = { _, _ in .object([:]) }
        action.setting(app, key, key == "seedColor" ? .integer(-1) : .string("unacknowledged"))
        _ = await waitForKeywordAction { !action.busy }
        check(action.failure?.code == "INVALID_DATA", "\(key): missing/mismatched color readback must be visible failure")
        check(app.settings == .null, "\(key): ignored value must not be published as saved")
    }
}
@MainActor func realPresetReceiptTests() async throws {
    // Receipts produced by production Kotlin dispatch + file-backed DataStore.
    // Replay only the transport boundary through the unchanged native action.
    let url = URL(fileURLWithPath: "preset-snapshots.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let rows = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: url))
    check(rows.count == 18, "actual catalogue x three modes reached DataStore reopen")
    for row in rows {
        let app = NativeAppModel()
        let action = SettingsAction()
        app.settings = row["before"]!
        let preset = row["reopened"]!["presetId"]!
        var operations: [String] = []
        app.respond = { operation, args in
            operations.append(operation)
            if operation == "settings.get" { return row["readback"]! }
            return args["key"] == .string("colorSource") ? row["activated"]! : row["written"]!
        }
        action.setting(app, "presetId", preset)
        _ = await waitForKeywordAction { !action.busy }
        check(action.failure == nil, "real preset receipt succeeds")
        check(app.settings == row["readback"]!, "real preset reaches published consumer snapshot")
        check(operations == ["settings.set", "settings.set", "settings.get"], "real preset activates before authoritative read")
        check(app.settings["presetId"] == row["reopened"]!["presetId"], "published preset matches actual reopened store")
    }
}
await keywordActionTests()
await themeActionTests()
try await realPresetReceiptTests()
#endif

keywordEditedDraftTest()
keywordUnchangedDraftTest()
keywordReenteredDraftTest()
try secretPatchTests()
try dohSelectionTests()
staleCompletionTests()
colorTests()
try releaseNotesTests()
print("Settings behavior checks: \(checks), failures: \(failures)")
exit(failures == 0 ? 0 : 1)
