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
            guard let scroll = visit(window).filter({ $0.bounds.height > 300 && $0.contentSize.height > $0.bounds.height }).max(by: { $0.bounds.height < $1.bounds.height }) else {
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
            output["settled"] = stableFrames >= 12
            output["frames"] = stableFrames
            output["history"] = samples
            accessibilityValue = String(data: try! JSONSerialization.data(withJSONObject: output, options: .sortedKeys), encoding: .utf8)!
        }
    }
}
