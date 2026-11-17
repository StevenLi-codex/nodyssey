import XCTest
import UIKit
final class NativeNavigationUITests: XCTestCase {
    @MainActor func testSmokeRealRootAndDetail() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Post 0"].waitForExistence(timeout: 15), app.debugDescription)
        capture(app, "smoke-home")
        app.staticTexts["Post 0"].tap()
        XCTAssertTrue(app.staticTexts["Opening body"].waitForExistence(timeout: 10), app.debugDescription)
        capture(app, "smoke-detail")
        XCTAssertEqual(app.tabBars.count, 0)
        guard back(app) else { return }
        XCTAssertTrue(app.staticTexts["Post 0"].waitForExistence(timeout: 8))
    }
    @MainActor func testCanvasRouteSampling() {
        let app=launch()
        XCTAssertTrue(app.staticTexts["Post 0"].waitForExistence(timeout:15),app.debugDescription)
        capture(app,"sampling-home"); verifyCanvas(app,"sampling-home")
        app.staticTexts["Post 0"].tap()
        XCTAssertTrue(app.staticTexts["Opening body"].waitForExistence(timeout:8),app.debugDescription)
        capture(app,"sampling-detail"); verifyCanvas(app,"sampling-detail",detail:true)
        guard back(app) else { return }
        app.tabBars.buttons.element(boundBy:1).tap()
        XCTAssertTrue(app.staticTexts["Notification 0"].firstMatch.waitForExistence(timeout:8),app.debugDescription)
        capture(app,"sampling-notifications"); verifyCanvas(app,"sampling-notifications")
        app.tabBars.buttons.element(boundBy:2).tap()
        XCTAssertTrue(app.staticTexts["Retained reader"].waitForExistence(timeout:8))
        capture(app,"sampling-profile"); verifyCanvas(app,"sampling-profile")
    }
    @MainActor func testLightCanvasAndNavigation() { matrix([]) }
    @MainActor func testDarkCanvasAndNavigation() { matrix(["--dark"]) }
    @MainActor func testCustomCanvasAndNavigation() { matrix(["--custom"]) }
    @MainActor func testCustomDarkCanvasAndNavigation() { matrix(["--custom", "--dark"]) }
    @MainActor private func launch(_ args: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = args; app.launch(); return app
    }
    @MainActor @discardableResult private func back(_ app: XCUIApplication) -> Bool {
        let button = app.navigationBars.buttons["BackButton"].firstMatch
        guard button.waitForExistence(timeout: 8) else {
            XCTFail("Navigation BackButton missing: " + app.debugDescription); return false
        }
        button.tap(); return true
    }
    // Only Search owns this two-step exit; ordinary detail pops never dismiss search.
    @MainActor private func exitSearch(_ app: XCUIApplication) -> Bool {
        guard app.searchFields.firstMatch.waitForExistence(timeout: 8) else {
            XCTFail("Search route missing before exit"); return false
        }
        let navBack = app.navigationBars.buttons["BackButton"].firstMatch
        if !navBack.exists {
            let close = app.navigationBars.buttons["Close"].firstMatch
            guard close.waitForExistence(timeout: 5) else {
                XCTFail("Active search has neither native Close nor BackButton"); return false
            }
            print("GLASS71_SEARCH_EXIT dismiss-native-search")
            close.tap()
        }
        guard navBack.waitForExistence(timeout: 8) else {
            XCTFail("Search dismissal did not expose navigation BackButton: " + app.debugDescription); return false
        }
        capture(app,"search-dismissed")
        print("GLASS71_SEARCH_EXIT navigate-back")
        guard back(app) else { return false }
        guard app.staticTexts["life 0"].waitForExistence(timeout: 8) else {
            XCTFail("Search Back did not return to Life feed: " + app.debugDescription); return false
        }
        return true
    }
    @MainActor private func reachEnd(_ app: XCUIApplication, _ name: String, lastRow: String) -> Bool {
        for swipe in 0...24 {
            let g = geometry(app)
            guard let content = g["contentH"] as? NSNumber, let viewport = g["viewportH"] as? NSNumber,
                  let inset = g["insetBottom"] as? NSNumber, let offset = g["offsetY"] as? NSNumber else {
                XCTFail("Missing end-of-scroll geometry"); return false
            }
            let remaining = max(0,content.doubleValue - viewport.doubleValue + inset.doubleValue - offset.doubleValue)
            print("GLASS71_END \(name) swipe=\(swipe) remaining=\(remaining)")
            if remaining <= 1 && app.staticTexts[lastRow].exists {
                capture(app,name); verifyCanvas(app,name); return true
            }
            guard swipe < 24 else { break }
            app.swipeUp(velocity: .fast)
        }
        capture(app,name+"-unreached")
        XCTFail("Bounded scroll failed to reach \(lastRow) within 1 point of maximum"); return false
    }
    @MainActor private func trace(_ app: XCUIApplication) -> [[String: Any]] {
        let text = app.staticTexts["glass71.transport"].label
        return ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String:Any])?["events"] as? [[String:Any]] ?? []
    }
    @MainActor private func geometry(_ app: XCUIApplication) -> [String: Any] {
        let probe = app.descendants(matching: .any)["retention.geometry"]
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let text = probe.value as? String, let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return false }
            return value["settled"] as? Bool == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 8), .completed)
        return (try? JSONSerialization.jsonObject(with: Data((probe.value as? String ?? "{}").utf8))) as? [String: Any] ?? [:]
    }
    @MainActor @discardableResult private func capture(_ app: XCUIApplication, _ name: String) -> [String: Any] {
        let g = geometry(app)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let record: [String:Any] = ["name":name,"geometry":g,"transport":trace(app),"screen":NSCoder.string(for:app.frame),"tabs":app.tabBars.count]
        let data = try! JSONSerialization.data(withJSONObject:record,options:.sortedKeys)
        let metrics = XCTAttachment(data:data,uniformTypeIdentifier:"public.json"); metrics.name = name+"-metrics"; metrics.lifetime = .keepAlways; add(metrics)
        let tree=XCTAttachment(string:app.debugDescription); tree.name=name+"-ax"; tree.lifetime = .keepAlways; add(tree)
        print("GLASS71 " + String(data:data,encoding:.utf8)!)
        return g
    }
    @MainActor private func matrix(_ args: [String]) {
        let app=launch(args)
        XCTAssertTrue(app.staticTexts["Post 0"].waitForExistence(timeout:15),app.debugDescription)
        let home=capture(app,"home-initial")
        XCTAssertFalse((home["layerClasses"] as? [String:Int] ?? [:]).isEmpty,"Read-only native layer traversal must produce real records")
        verifyCanvas(app,"home-initial")
        for _ in 0..<3 { app.swipeUp() }
        let before=capture(app,"home-scrolled")
        let starts=trace(app).filter { $0["kind"] as? String == "observe" && $0["operation"] as? String == "feed" }.count
        app.tabBars.buttons.element(boundBy:2).tap()
        XCTAssertTrue(app.staticTexts["Retained reader"].waitForExistence(timeout:8))
        capture(app,"profile-initial"); verifyCanvas(app,"profile-initial")
        for _ in 0..<4 { app.swipeUp() }
        capture(app,"profile-end"); verifyCanvas(app,"profile-end")
        app.tabBars.buttons.element(boundBy:0).tap()
        let after=capture(app,"home-return")
        XCTAssertEqual(before["owner"] as? String,after["owner"] as? String,"Retained feed scroll owner")
        XCTAssertEqual((before["offsetY"] as? NSNumber)?.doubleValue ?? -999,(after["offsetY"] as? NSNumber)?.doubleValue ?? 999,accuracy:3,"Feed tab-return offset")
        XCTAssertEqual(starts,trace(app).filter { $0["kind"] as? String == "observe" && $0["operation"] as? String == "feed" }.count,"Tab return must not reopen feed observer")
        guard reachEnd(app,"home-end",lastRow:"Post 59") else { return }
        // Different board means different data. Require canonical request/state, not same offset.
        app.buttons["Tech"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["tech 0"].waitForExistence(timeout:8),app.debugDescription)
        capture(app,"home-tech")
        let event=trace(app).last { $0["kind"] as? String == "observe" && $0["operation"] as? String == "feed" }
        XCTAssertEqual((event?["arguments"] as? [String:Any])?["categorySlug"] as? String,"tech")
        app.buttons["Life"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["life 0"].waitForExistence(timeout:8))
        capture(app,"home-life")
        app.buttons["Search"].firstMatch.tap()
        let search=app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout:8),app.debugDescription)
        search.tap(); search.typeText("needle\n")
        XCTAssertTrue(app.staticTexts["Search 0"].waitForExistence(timeout:10),app.debugDescription)
        capture(app,"search-submitted"); verifyCanvas(app,"search-submitted")
        let searched=trace(app).last { $0["operation"] as? String == "search.feed" }
        XCTAssertEqual((searched?["arguments"] as? [String:Any])?["query"] as? String,"needle")
        app.staticTexts["Search 0"].tap()
        XCTAssertTrue(app.staticTexts["Opening body"].waitForExistence(timeout:8),app.debugDescription)
        capture(app,"detail-from-search"); verifyCanvas(app,"detail-from-search",detail:true)
        for _ in 0..<5 { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Reply body 12"].exists,"Final reply reachable")
        capture(app,"detail-end"); verifyCanvas(app,"detail-end",detail:true)
        guard back(app) else { return }
        guard app.searchFields.firstMatch.waitForExistence(timeout:8) else { XCTFail("Search missing after detail pop"); return }
        guard reachEnd(app,"search-end",lastRow:"Search 59") else { return }
        guard exitSearch(app) else { return }
        capture(app,"home-after-search")
        app.tabBars.buttons.element(boundBy:1).tap()
        XCTAssertTrue(app.staticTexts["Notification 0"].firstMatch.waitForExistence(timeout:8),app.debugDescription)
        capture(app,"notifications-initial"); verifyCanvas(app,"notifications-initial")
        app.staticTexts["Notification 0"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Opening body"].waitForExistence(timeout:8),app.debugDescription)
        capture(app,"detail-from-notification"); verifyCanvas(app,"detail-from-notification",detail:true)
        guard back(app) else { return }
        capture(app,"notifications-return")
        for _ in 0..<8 { app.swipeUp() }
        capture(app,"notifications-end"); verifyCanvas(app,"notifications-end")
        // Native classes/owners/frames are evidence, not an optional-array glass assertion.
        // Empty glass candidates remain an explicit observation boundary.
    }
    @MainActor private func verifyCanvas(_ app: XCUIApplication,_ name:String,detail:Bool=false) {
        let image=app.screenshot().image.cgImage!,w=image.width,h=image.height
        var bytes=[UInt8](repeating:0,count:w*h*4)
        bytes.withUnsafeMutableBytes { b in
            CGContext(data:b.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
        }
        let scale=CGFloat(w)/app.frame.width
        func pixel(_ x:CGFloat,_ y:CGFloat)->[Int] { let n=(Int(y*scale)*w+Int(x*scale))*4;return Array(bytes[n..<n+3]).map(Int.init) }
        if !detail,app.tabBars.count>0 {
            let edge=app.tabBars.firstMatch.frame.minY
            for x:CGFloat in [0,1,2,4] {
                let a=pixel(x,edge-1),b=pixel(x,edge+1)
                let jump=zip(a,b).map { abs($0-$1) }.max()!
                print("GLASS71_SEAM \(name) x=\(x) y=\(edge) above=\(a) below=\(b) jump=\(jump)")
                XCTAssertLessThanOrEqual(jump,2,"Shared canvas seam outside glass/shadow")
            }
        }
        // Never assert material pixels are opaque. Sample extreme-left canvas,
        // excluding native navigation/float rails; retain raw strips for review.
        let sampleYs: [CGFloat]=[app.frame.height/2,app.frame.height-150,app.frame.height-12]
        print("GLASS71_STRIP \(name) " + sampleYs.map { "\($0):\(pixel(1,$0))" }.joined(separator:" "))
        if detail {
            XCTAssertEqual(app.tabBars.count,0,"Detail hides root tab chrome")
            let a=pixel(1,app.frame.height-150),b=pixel(1,app.frame.height-12)
            let jump=zip(a,b).map { abs($0-$1) }.max()!
            print("GLASS71_DETAIL_CANVAS \(name) above=\(a) safeBottom=\(b) jump=\(jump)")
            XCTAssertLessThanOrEqual(jump,2,"Detail bottom safe-area canvas continuity outside reply rail")
        }
    }
}
