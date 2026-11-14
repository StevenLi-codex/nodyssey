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
try secretPatchTests()
try dohSelectionTests()
staleCompletionTests()
colorTests()
try releaseNotesTests()
print("Settings behavior checks: \(checks), failures: \(failures)")
exit(failures == 0 ? 0 : 1)
