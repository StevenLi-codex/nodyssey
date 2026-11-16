// Disposable diagnostic scaffolding. Do not ship or add to permanent appearance tests.
// Read-only UIKit inspection: no tint assignments, layout forcing, view replacement or swizzling.
import SwiftUI
import UIKit
import NodysseyNativeCore

struct ThemeTintProbe: UIViewRepresentable {
    let settings: JSONValue
    let checkpoint: Int
    let scope: String
    @Environment(\.colorScheme) private var scheme

    final class Anchor: UIView {
        var token = UUID()
    }
    func makeUIView(context: Context) -> Anchor {
        let view = Anchor(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }
    func updateUIView(_ view: Anchor, context: Context) {
        let token = UUID(); view.token = token
        let keys = ["themeMode", "colorSource", "presetId", "paletteStyle", "seedColor", "einkMode"]
        let snapshot = keys.reduce(into: [String: String]()) { result, key in
            result[key] = settings[key].map { String(describing: $0) } ?? "null"
        }
        let scope = scope, checkpoint = checkpoint, scheme = scheme == .dark ? "dark" : "light"
        // Sample after the current SwiftUI transaction without forcing UIKit layout.
        Task { @MainActor [weak view] in
            for delay in [100, 400] + Array(repeating: 1000, count: 600) {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                guard let view, view.token == token, let window = view.window else { return }
                ThemeUIKitSnapshot.emit(window: window, settings: snapshot, scheme: scheme,
                                        scope: scope + "-" + String(describing: ObjectIdentifier(view)), checkpoint: checkpoint, delay: delay)
            }
        }
    }
}

@MainActor enum ThemeUIKitSnapshot {
    static func rgba(_ input: UIColor?, traits: UITraitCollection) -> Any {
        guard let input else { return NSNull() }
        let value = input.resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard value.getRed(&r, green: &g, blue: &b, alpha: &a) else { return value.description }
        return [r, g, b, a].map { Double($0) }
    }
    static func menu(_ menu: UIMenu) -> [String: Any] {
        ["title": menu.title, "children": menu.children.map { element -> [String: Any] in
            if let submenu = element as? UIMenu { return self.menu(submenu) }
            if let action = element as? UIAction {
                return ["title": action.title, "state": action.state.rawValue, "attributes": action.attributes.rawValue]
            }
            return ["class": String(describing: type(of: element)), "title": element.title]
        }]
    }
    static func emit(window: UIWindow, settings: [String: String], scheme: String,
                     scope: String, checkpoint: Int, delay: Int) {
        var nodes: [[String: Any]] = []
        func walk(_ view: UIView, path: String, depth: Int) {
            guard depth < 60, nodes.count < 5000 else { return }
            let bounds = view.convert(view.bounds, to: window)
            let traits = view.traitCollection
            var row: [String: Any] = [
                "path": path, "class": String(describing: type(of: view)),
                "identity": String(describing: ObjectIdentifier(view)),
                "frame": [Double(bounds.minX), Double(bounds.minY), Double(bounds.width), Double(bounds.height)],
                "tint": rgba(view.tintColor, traits: traits), "hidden": view.isHidden,
                "alpha": Double(view.alpha), "tintAdjustmentMode": view.tintAdjustmentMode.rawValue,
                "interfaceStyle": traits.userInterfaceStyle.rawValue
            ]
            row["accessibilityLabel"] = view.accessibilityLabel ?? ""
            row["accessibilityValue"] = view.accessibilityValue ?? ""
            row["contextMenuInteractions"] = view.interactions.compactMap { interaction in
                interaction is UIContextMenuInteraction ? String(describing: ObjectIdentifier(interaction)) : nil
            }
            if let control = view as? UIControl { row["enabled"] = control.isEnabled }
            if let text = view as? UILabel {
                row["text"] = text.text ?? ""
                row["textColor"] = rgba(text.textColor, traits: traits)
                var runs: [[String: Any]] = []
                if let attributed = text.attributedText {
                    attributed.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                        if let color = value as? UIColor { runs.append(["range": [range.location, range.length], "color": rgba(color, traits: traits)]) }
                    }
                }
                row["foregroundRuns"] = runs
            }
            if let button = view as? UIButton {
                row["title"] = button.currentTitle ?? ""
                row["titleColor"] = rgba(button.currentTitleColor, traits: traits)
                if #available(iOS 15, *) {
                    row["configurationForeground"] = rgba(button.configuration?.baseForegroundColor, traits: traits)
                    row["configurationTitle"] = button.configuration?.title ?? ""
                }
                if let buttonMenu = button.menu { row["menu"] = menu(buttonMenu) }
            }
            if let bar = view as? UITabBar {
                row["selectedTint"] = rgba(bar.tintColor, traits: traits)
                row["unselectedTint"] = rgba(bar.unselectedItemTintColor, traits: traits)
            }
            nodes.append(row)
            for (index, child) in view.subviews.enumerated() { walk(child, path: path + "/" + String(index), depth: depth + 1) }
        }
        walk(window, path: "window", depth: 0)
        let report: [String: Any] = ["scope": scope, "checkpoint": checkpoint, "delayMillis": delay, "timestamp": Date().timeIntervalSince1970,
            "swiftUIEnvironmentScheme": scheme, "settings": settings, "nodes": nodes]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print("THEME70_UIKIT " + String(decoding: data, as: UTF8.self))
            let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("theme70-uikit.jsonl")
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data([10]))
        } catch { print("THEME70_DIAGNOSTIC_SERIALIZATION_ERROR", error) }
    }
}
