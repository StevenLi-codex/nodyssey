import SwiftUI
import UIKit

@MainActor enum Probe { static var localOpen = 0; static var ownerOpen = 0 }

@main final class BehaviorApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let app = NativeAppModel()
        let actions = NativeRichTextActions(onImage: { _, _ in Probe.ownerOpen += 1 }, imageTapUsesOwner: true)
        let content = VStack {
            NativeRichTextView(nodes: [.paragraph([.text("opening alpha beta 中文🙂 omega", .init())])], actions: actions)
            NativeRichTextView(nodes: [.image(url: "https://example.invalid/a.png", alt: nil)], actions: actions).frame(width: 70, height: 70)
        }.environment(\.nativeRichSelectionEnabled, true).environmentObject(app)
        let root = UIHostingController(rootView: AnyView(content))
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = root
        w.makeKeyAndVisible()
        window = w
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            var selectionPass = false
            if let paragraph = behaviorParagraphs(root).first {
                let text = paragraph.textView
                let range = (text.text as NSString).range(of: "alpha beta")
                UIPasteboard.general.string = "TOP-LEVEL-SENTINEL"
                if range.location != NSNotFound { text.selectedRange = range; text.copy(nil) }
                selectionPass = UIPasteboard.general.string == "alpha beta"
            }
            NotificationCenter.default.post(name: .init("behavior.image"), object: nil)
            try? await Task.sleep(nanoseconds: 100_000_000)
            let imageOwnerPass = Probe.ownerOpen == 1 && Probe.localOpen == 0
            var behavior = runNativeRichSelectionBehavior(in: root)
            let (natural, naturalDetails) = await runNaturalParagraphBehavior(in: root)
            behavior.merge(natural) { _, current in current }
            let tabs: [NativeRichNode] = [.tabs(["A", "B"].map { tab in
                NativeRichTab(title: tab, children: [.paragraph([
                    .text("\(tab) selectable text ", .init()),
                    .image(url: "https://example.invalid/\(tab).png", alt: tab),
                    .link(" \(tab) link", "https://example.invalid/\(tab)", .init())
                ])])
            })]
            root.rootView = AnyView(NativeRichTextView(nodes: tabs, actions: .init(onImage: { _, _ in }, imageTapUsesOwner: true, onLink: { _ in }))
                .environment(\.nativeRichSelectionEnabled, true).environmentObject(app).padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
            let mounted = await MountedTabCase(root: root).run()
            behavior["mounted-tab-reselect-preserves-paragraph"] = mounted["passed"] as? Bool ?? false
            let result: [String: Any] = ["behavior": behavior, "selectionPass": selectionPass, "imageOwnerPass": imageOwnerPass,
                "details": ["natural": naturalDetails, "mounted": mounted], "runtime": UIDevice.current.systemVersion,
                "boundary": "real iOS UIKit/SwiftUI; synthetic loaded image/graph/code/viewer boundaries; staged exact-action seams; not touch"]
            do {
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try data.write(to: documents.appendingPathComponent("result.json"), options: .atomic)
            } catch { print("BEHAVIOR_RESULT_WRITE_FAILED: \(error)") }
        }
        return true
    }
}
