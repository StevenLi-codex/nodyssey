import SwiftUI
import UIKit

// Diagnostic only. Observe UIKit geometry; never set offsets/insets or call layoutIfNeeded.
struct RetentionGeometryProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeLabel { ProbeLabel() }
    func updateUIView(_ view: ProbeLabel, context: Context) {}
    static func dismantleUIView(_ view: ProbeLabel, coordinator: ()) { view.link?.invalidate() }
    final class ProbeLabel: UILabel {
        var link: CADisplayLink?
        var last = ""
        var stableFrames = 0
        var samples: [[String: Any]] = []
        var nativeSnapshot: [String: Any] = [:]
        var nativeSampleTime: CFTimeInterval = 0
        func nativeHierarchy(_ window: UIWindow) -> [String: Any] {
            var views: [String:Int] = [:], layers: [String:Int] = [:]
            var candidates: [[String:Any]] = []
            func relevant(_ name: String) -> Bool {
                ["glass","backdrop","material","visualeffect"].contains { name.lowercased().contains($0) }
            }
            func visitView(_ view: UIView) {
                guard !view.isHidden, view.alpha > 0.01 else { return }
                let name = String(reflecting: type(of:view))
                views[name,default:0] += 1
                if relevant(name) {
                    candidates.append(["kind":"view","class":name,"owner":String(describing:ObjectIdentifier(view)),"frame":NSCoder.string(for:view.convert(view.bounds,to:window))])
                }
                view.subviews.forEach(visitView)
            }
            func visitLayer(_ layer: CALayer) {
                guard !layer.isHidden, layer.opacity > 0.01 else { return }
                let name = String(reflecting:type(of:layer))
                layers[name,default:0] += 1
                if relevant(name) {
                    candidates.append(["kind":"layer","class":name,"owner":String(describing:ObjectIdentifier(layer)),"frame":NSCoder.string(for:layer.convert(layer.bounds,to:window.layer))])
                }
                layer.sublayers?.forEach(visitLayer)
            }
            visitView(window); visitLayer(window.layer)
            return ["viewClasses":views,"layerClasses":layers,"nativeGlassCandidates":candidates]
        }
        override init(frame: CGRect) {
            super.init(frame: frame)
            text = ""; isAccessibilityElement = true
            accessibilityIdentifier = "retention.geometry"; accessibilityLabel = "retention.geometry"
            isUserInteractionEnabled = false
            link = CADisplayLink(target: self, selector: #selector(sample))
            link?.add(to: .main, forMode: .common)
        }
        required init?(coder: NSCoder) { fatalError() }
        @objc func sample() {
            guard let window else { return }
            func visit(_ view: UIView) -> [UIScrollView] {
                guard !view.isHidden, view.alpha > 0.01, view.convert(view.bounds, to: window).intersects(window.bounds) else { return [] }
                return (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(visit)
            }
            guard let scroll = visit(window).filter({ $0.bounds.height > 300 }).max(by: { $0.bounds.height < $1.bounds.height }) else {
                stableFrames = 0; accessibilityValue = "{}"; return
            }
            let rect = scroll.convert(scroll.bounds, to: window)
            let values: [String: Any] = [
                "owner": String(describing: ObjectIdentifier(scroll)),
                "offsetX": scroll.contentOffset.x, "offsetY": scroll.contentOffset.y,
                "viewportX": rect.minX, "viewportY": rect.minY, "viewportW": rect.width, "viewportH": rect.height,
                "contentW": scroll.contentSize.width, "contentH": scroll.contentSize.height,
                "insetTop": scroll.adjustedContentInset.top, "insetBottom": scroll.adjustedContentInset.bottom,
                "safeTop": scroll.safeAreaInsets.top, "safeBottom": scroll.safeAreaInsets.bottom,
                "tracking": scroll.isTracking, "dragging": scroll.isDragging, "decelerating": scroll.isDecelerating]
            let data = try! JSONSerialization.data(withJSONObject: values, options: .sortedKeys)
            let key = String(data: data, encoding: .utf8)!
            let idle = !scroll.isTracking && !scroll.isDragging && !scroll.isDecelerating
            stableFrames = key == last && idle ? min(stableFrames + 1, 12) : 0
            if key != last {
                var record = values; record["time"] = CACurrentMediaTime()
                samples.append(record); if samples.count > 180 { samples.removeFirst() }
                last = key
            }
            var output = values
            func effects(_ view: UIView) -> [[String: Any]] {
                guard !view.isHidden, view.alpha > 0.01 else { return [] }
                var own: [[String: Any]] = []
                if let effect = view as? UIVisualEffectView {
                    own = [["owner": String(describing: ObjectIdentifier(effect)), "class": String(describing: type(of: effect)), "effect": String(describing: effect.effect), "frame": NSCoder.string(for: effect.convert(effect.bounds, to: window)), "alpha": effect.alpha]]
                }
                return own + view.subviews.flatMap(effects)
            }
            output["effects"] = effects(window)
            if CACurrentMediaTime() - nativeSampleTime >= 1 {
                nativeSnapshot = nativeHierarchy(window); nativeSampleTime = CACurrentMediaTime()
            }
            for (key,value) in nativeSnapshot { output[key] = value }
            output["settled"] = stableFrames >= 12
            output["frames"] = stableFrames
            output["history"] = samples
            accessibilityValue = String(data: try! JSONSerialization.data(withJSONObject: output, options: .sortedKeys), encoding: .utf8)!
        }
    }
}
