import XCTest
import UIKit
final class NativeNavigationUITests: XCTestCase {
    @MainActor func testLightTopGlass() { top([]) }
    @MainActor func testDarkTopGlass() { top(["--dark"]) }
    @MainActor func testCustomTopGlass() { top(["--custom"]) }
    @MainActor private func trace(_ app: XCUIApplication) -> [[String:Any]] {
        let text=app.staticTexts["glass72.transport"].label
        return ((try? JSONSerialization.jsonObject(with:Data(text.utf8))) as? [String:Any])?["events"] as? [[String:Any]] ?? []
    }
    @MainActor private func geometry(_ app: XCUIApplication) -> [String:Any] {
        let probe=app.descendants(matching:.any)["retention.geometry"]
        var result:[String:Any]=[:]
        let wait=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
            guard let text=probe.value as? String,let g=try? JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any] else { return false }
            result=g
            return g["settled"] as? Bool == true && !(g["nativeGlassCandidates"] as? [[String:Any]] ?? []).isEmpty
        },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[wait],timeout:15),.completed,"Bounded settled geometry/native hierarchy")
        return result
    }
    @MainActor @discardableResult private func capture(_ app: XCUIApplication,_ name:String) -> [String:Any] {
        let g=geometry(app)
        let shot=XCTAttachment(screenshot:app.screenshot()); shot.name=name; shot.lifetime = .keepAlways; add(shot)
        // Public XCUIElementSnapshotProviding API: one AX acquisition, then only
        // local snapshot attributes/children. Never issue per-row AX RPCs here.
        // https://developer.apple.com/documentation/xcuiautomation/xcuielementsnapshotproviding/snapshot()
        let snapshot: any XCUIElementSnapshot
        do { snapshot = try app.snapshot() }
        catch { XCTFail("AX snapshot failed: \(error)"); return g }
        var controls:[[String:Any]]=[], texts:[[String:Any]]=[], nodes:[[String:Any]]=[]
        var transport:[[String:Any]]=[]
        func visit(_ node:any XCUIElementSnapshot) {
            let frame=node.frame
            let finite=[frame.minX,frame.minY,frame.width,frame.height].allSatisfy { $0.isFinite }
            if node.identifier == "glass72.transport" {
                transport = ((try? JSONSerialization.jsonObject(with:Data(node.label.utf8))) as? [String:Any])?["events"] as? [[String:Any]] ?? []
            }
            if finite && frame.maxY > 0 && frame.minY < 500 && frame.width > 0 && frame.height > 0 && !node.identifier.contains("glass72") && node.identifier != "retention.geometry" {
                let record:[String:Any]=["label":node.label,"identifier":node.identifier,"type":node.elementType.rawValue,"value":String(describing:node.value),"frame":NSCoder.string(for:frame),"enabled":node.isEnabled,"geometrySource":"public XCUIElementSnapshot.frame"]
                nodes.append(record)
                if node.elementType == .button && frame.minY < 360 { controls.append(record) }
                if node.elementType == .staticText { texts.append(record) }
            }
            node.children.forEach(visit)
        }
        visit(snapshot)
        let record:[String:Any]=["name":name,"geometry":g,"transport":transport,"controls":controls,"texts":texts,"screen":NSCoder.string(for:snapshot.frame),"axAcquisition":"one public app.snapshot(); local immutable attribute traversal; hittability remains in targeted interaction assertions"]
        let data=try! JSONSerialization.data(withJSONObject:record,options:.sortedKeys)
        let metrics=XCTAttachment(data:data,uniformTypeIdentifier:"public.json"); metrics.name=name+"-metrics"; metrics.lifetime = .keepAlways; add(metrics)
        let tree=XCTAttachment(data:try! JSONSerialization.data(withJSONObject:nodes,options:.sortedKeys),uniformTypeIdentifier:"public.json"); tree.name=name+"-ax"; tree.lifetime = .keepAlways; add(tree)
        print("GLASS72 "+String(data:data,encoding:.utf8)!)
        return g
    }
    @MainActor private func glass(_ g:[String:Any]) -> [[String:Any]] {
        (g["nativeGlassCandidates"] as? [[String:Any]] ?? []).filter {
            ($0["class"] as? String ?? "").contains("UIPlatformGlassInteractionView") && (($0["rect"] as? [Double])?[1] ?? 999) < 230 && (($0["rect"] as? [Double])?[2] ?? 0) > 300
        }
    }
    @MainActor private func waitRequest(_ app:XCUIApplication,_ operation:String,_ key:String,_ value:String) {
        let wait=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
            self.trace(app).contains { $0["operation"] as? String == operation && ($0["arguments"] as? [String:Any])?[key] as? String == value }
        },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[wait],timeout:8),.completed,"Transport \(operation) \(key)=\(value)")
    }
    @MainActor private func top(_ args:[String]) {
        let app=XCUIApplication(); app.launchArguments=args; app.launch()
        guard app.staticTexts["Post 0"].waitForExistence(timeout:20) else { XCTFail("Initial feed missing"); return }
        let initial=capture(app,"home-initial")
        XCTAssertEqual(glass(initial).count,2,"Two real top native glass rows")
        let search=app.buttons["Search"].firstMatch
        XCTAssertTrue(search.isHittable); XCTAssertEqual(search.frame.height,44,accuracy:0.5)
        for title in ["Tech","Life"] { XCTAssertGreaterThanOrEqual(app.buttons[title].firstMatch.frame.height,44) }
        let sort=app.buttons.matching(NSPredicate(format:"label CONTAINS[c] %@","Sort")).firstMatch
        guard sort.exists else { XCTFail("Real sort picker missing: "+app.debugDescription); return }
        sort.tap()
        let postTime=app.buttons["Newest post"].firstMatch
        guard postTime.waitForExistence(timeout:5) else { XCTFail("Post time action missing: "+app.debugDescription); return }
        postTime.tap(); waitRequest(app,"feed","sort","POST_TIME"); capture(app,"home-post-time")
        sort.tap()
        let lastReply=app.buttons["Latest reply"].firstMatch
        guard lastReply.waitForExistence(timeout:5) else { XCTFail("Last reply action missing"); return }
        lastReply.tap(); waitRequest(app,"feed","sort","LAST_REPLY")
        for (title,slug) in [("Tech","tech"),("Life","life")] {
            app.buttons[title].firstMatch.tap()
            guard app.staticTexts[slug+" 0"].waitForExistence(timeout:8) else { XCTFail("Board feed absent "+slug); return }
            waitRequest(app,"feed","categorySlug",slug)
        }
        let life=capture(app,"home-life")
        let starts=trace(app).filter { $0["kind"] as? String == "observe" && $0["operation"] as? String == "feed" }.count
        app.tabBars.buttons.element(boundBy:1).tap()
        guard app.staticTexts["Notification 0"].firstMatch.waitForExistence(timeout:8) else { XCTFail("Notification fixture absent"); return }
        app.tabBars.buttons.element(boundBy:0).tap()
        guard app.staticTexts["life 0"].waitForExistence(timeout:8) else { XCTFail("Home return absent"); return }
        let returned=capture(app,"home-tab-return")
        XCTAssertEqual(life["owner"] as? String,returned["owner"] as? String)
        XCTAssertEqual(starts,trace(app).filter { $0["kind"] as? String == "observe" && $0["operation"] as? String == "feed" }.count)
        let a=glass(life),b=glass(returned)
        XCTAssertEqual(a.count,2); XCTAssertEqual(b.count,2)
        XCTAssertEqual(a.compactMap{$0["owner"] as? String},b.compactMap{$0["owner"] as? String},"Glass owner retention")
        XCTAssertEqual(a.compactMap{$0["frame"] as? String},b.compactMap{$0["frame"] as? String},"Glass frame retention")
        app.buttons["Search"].firstMatch.tap()
        let input=app.searchFields.firstMatch
        guard input.waitForExistence(timeout:8) else { XCTFail("Real Search input absent"); return }
        input.tap(); input.typeText("needle\n")
        guard app.staticTexts["Search 0"].waitForExistence(timeout:10) else { XCTFail("Search submission absent"); return }
        waitRequest(app,"search.feed","query","needle"); capture(app,"search-submitted")
        let back=app.navigationBars.buttons["BackButton"].firstMatch
        if !back.exists {
            let close=app.navigationBars.buttons["Close"].firstMatch
            guard close.waitForExistence(timeout:5) else { XCTFail("Native search Close absent"); return }
            close.tap(); print("GLASS72_SEARCH_EXIT Close")
        }
        guard back.waitForExistence(timeout:8) else { XCTFail("Real Back absent after Close"); return }
        back.tap(); print("GLASS72_SEARCH_EXIT Back")
        guard app.staticTexts["life 0"].waitForExistence(timeout:8) else { XCTFail("Search Back did not restore Life"); return }
        capture(app,"home-after-search")
        // Preserve actual geometry RED until after interaction evidence is captured.
        for row in glass(initial) {
            let r=row["rect"] as? [Double] ?? []
            guard r.count==4 else { XCTFail("Missing glass rectangle"); continue }
            XCTAssertEqual(r[0],12,accuracy:0.5,"Glass/card shared left boundary")
            XCTAssertEqual(r[2],Double(app.frame.width)-24,accuracy:0.5,"Glass/card shared right boundary")
            XCTAssertEqual(r[3],44,accuracy:0.5,"44pt glass rows")
        }
        app.terminate()
    }
}
