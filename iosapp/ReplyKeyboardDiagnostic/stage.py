from pathlib import Path
import shutil,re,hashlib,json,os
repo=Path.cwd()
stage=Path(os.environ['RUNNER_TEMP'])/'ReplyKeyboard'
stage.mkdir(exist_ok=True)
# A disposable app host: exact production reply presentation/model/UIKit input,
# no Kotlin initialization, network transport, account state or private data.
for path in ['iosapp/Nodyssey.xcodeproj','iosapp/NativeCore']:
    shutil.copytree(repo/path,stage/path,dirs_exist_ok=True)
app=stage/'iosapp/Nodyssey'; (app/'Native').mkdir(parents=True,exist_ok=True)
files=['Editing/EditorThreadReply.swift','Editing/EditorState.swift','Editing/EditorViewModel.swift','Editing/MarkedTextEditor.swift','Rendering/RichDocument.swift']
hashes={}
for name in files:
    src=repo/'iosapp/Nodyssey/Native'/name
    shutil.copy2(src,app/'Native'/src.name)
    hashes[name]=hashlib.sha256(src.read_bytes()).hexdigest()
# Toolbar is copied verbatim; panel/preview/photo surfaces are explicit boundaries.
src=repo/'iosapp/Nodyssey/Native/Editing/EditorPanels.swift'
(app/'Native/EditorToolbar.swift').write_text(src.read_text().split('struct EditorPanelView: View {')[0])
project=stage/'iosapp/Nodyssey.xcodeproj/project.pbxproj'
s=project.read_text()
s=s.replace('A1000000000000000000002 /* AppIcon.icon in Resources */,','')
s=s.replace('A1000000000000000000070 /* Build Kotlin framework */,','')
s=re.sub(r'\s*FRAMEWORK_SEARCH_PATHS = \([^;]+;', '',s)
s=re.sub(r'\s*OTHER_LDFLAGS = \([^;]+;', '',s)
project.write_text(s)
(app/'Info.plist').write_text('''<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string><key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string><key>CFBundleName</key><string>$(PRODUCT_NAME)</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>68</string><key>CFBundleShortVersionString</key><string>1.0</string><key>UILaunchScreen</key><dict/></dict></plist>''')
(app/'App.swift').write_text('''import SwiftUI
import NodysseyNativeCore
@main struct ReplyKeyboardProbe: App {
    @StateObject private var app = NativeAppModel()
    var body: some Scene { WindowGroup { Host().environmentObject(app) } }
}
struct Host: View {
    @StateObject private var owner = EditorReplyLifetime()
    var body: some View {
        NavigationStack { Text("Network-free production reply host")
            .modifier(EditorThreadReplyPresentation(owner: owner, covered: false, onPublished: { _ in fatalError("No publishing in probe") }))
            .task { await owner.open(postID: 9, transport: FixtureTransport(), generation: 1) }
        }
    }
}
''')
(app/'Native/FixtureContracts.swift').write_text('''import SwiftUI
import NodysseyNativeCore
@MainActor final class NativeAppModel: ObservableObject {
    let transport: any NativeTransport = FixtureTransport()
    var generation = 1
    var settings: JSONValue = .null
    var departureRunning = false
}
struct FixtureTransport: NativeTransport {
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        switch operation {
        case "draft.comment.get": return .null
        case "draft.comment.save": return .object([:])
        default: throw NativeFailure(code: "PROBE_BOUNDARY", message: "No network or publishing in probe: " + operation)
        }
    }
    func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error> { AsyncThrowingStream { $0.finish() } }
}
func EL(_ key: String) -> String { key }
struct NativeFailureView: View { let failure: NativeFailure; var retry: (() -> Void)? = nil; var body: some View { Text(failure.message) } }
struct EditorRichPreview: View { let nodes: [NativeRichNode]; var body: some View { Text("Preview boundary") } }
struct EditorPanelView: View { let panel: EditorPanel; let model: EditorViewModel; var embedded = false; var body: some View { Text("Panel boundary") } }
struct EditorPhotoPicker: View { let model: EditorViewModel; var body: some View { Text("Photo boundary") } }
''')
test=stage/'iosapp/NativeNavigationUITests';test.mkdir(exist_ok=True)
(test/'NativeNavigationUITests.swift').write_text('''import XCTest
final class NativeNavigationUITests: XCTestCase {
    @MainActor func testShortReplyWithSoftwareKeyboard() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let field = app.textViews["body"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        if !app.keyboards.firstMatch.waitForExistence(timeout: 10) { field.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "Software keyboard must really be open")
        let tutorial = app.buttons["Continue"]
        if tutorial.waitForExistence(timeout: 3) { tutorial.tap() }
        XCTAssertTrue(app.keyboards.keys["space"].waitForExistence(timeout: 10), "Normal software keyboard keys must be visible, not keyboard onboarding")
        field.typeText("short reply")
        sleep(2)
        let keyboard = app.keyboards.firstMatch.frame
        let header = app.buttons["close"].frame
        let body = field.frame
        print("REPLY68 keyboard=\\(keyboard) header=\\(header) body=\\(body)")
        print(app.debugDescription)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "short-reply-keyboard-open"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertLessThanOrEqual(body.height, 120, "Typing a short reply must not choose long-editor mode")
        XCTAssertGreaterThanOrEqual(header.minY, keyboard.minY - 310, "The composer above the actual keyboard must remain compact")
        XCTAssertLessThanOrEqual(body.maxY, keyboard.minY + 1, "Input must remain above the software keyboard")
        app.buttons["expand"].tap()
        XCTAssertTrue(app.buttons["collapse"].waitForExistence(timeout: 5))
        field.typeText("\\nsecond line\\nthird line\\nfourth line")
        XCTAssertTrue(app.keyboards.keys["space"].exists)
        XCTAssertTrue((field.value as? String)?.contains("fourth line") == true)
        app.buttons["collapse"].tap()
        sleep(2)
        XCTAssertGreaterThanOrEqual(app.buttons["close"].frame.minY, app.keyboards.firstMatch.frame.minY - 310)
        XCTAssertTrue((field.value as? String)?.contains("fourth line") == true, "Collapsing must retain input")
    }
}
''')
(stage/'sources.json').write_text(json.dumps(hashes,indent=2))
print(stage)
