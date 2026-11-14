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
    func request(_ operation: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
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
await keywordActionTests()
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
