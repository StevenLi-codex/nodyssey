// Signature-only UIKit boundary for macOS CLT. Not an iOS SDK and never app-linked.
// Methods trap: this module cannot validate gesture dispatch, scroll physics or view layout.
import Foundation
import CoreGraphics
public class UIImage: NSObject {}
public class NSLayoutConstraint {
    public static func activate(_ constraints: [NSLayoutConstraint]) { fatalError() }
}
public class NSLayoutAnchor<T> {
    public func constraint(equalTo: NSLayoutAnchor<T>) -> NSLayoutConstraint { fatalError() }
}
public class UILayoutGuide {
    public var leadingAnchor: NSLayoutAnchor<NSObject> { fatalError() }
    public var trailingAnchor: NSLayoutAnchor<NSObject> { fatalError() }
    public var topAnchor: NSLayoutAnchor<NSObject> { fatalError() }
    public var bottomAnchor: NSLayoutAnchor<NSObject> { fatalError() }
    public var widthAnchor: NSLayoutAnchor<NSObject> { fatalError() }
    public var heightAnchor: NSLayoutAnchor<NSObject> { fatalError() }
}
open class UIView: NSObject {
    public enum ContentMode { case scaleAspectFit }
    public var contentMode: ContentMode = .scaleAspectFit
    public var isAccessibilityElement = false
    public var accessibilityLabel: String?
    public var translatesAutoresizingMaskIntoConstraints = true
    public var transform = CGAffineTransform.identity
    public var bounds = CGRect.zero
    public var superview: UIView? { fatalError() }
    public var gestureRecognizers: [UIGestureRecognizer]? { fatalError() }
    public var leadingAnchor: NSLayoutAnchor<NSObject> { fatalError() }
    public var trailingAnchor: NSLayoutAnchor<NSObject> { fatalError() }
    public var topAnchor: NSLayoutAnchor<NSObject> { fatalError() }
    public var bottomAnchor: NSLayoutAnchor<NSObject> { fatalError() }
    public var widthAnchor: NSLayoutAnchor<NSObject> { fatalError() }
    public var heightAnchor: NSLayoutAnchor<NSObject> { fatalError() }
    public func addSubview(_ view: UIView) { fatalError() }
    public func addGestureRecognizer(_ recognizer: UIGestureRecognizer) { fatalError() }
    open func layoutSubviews() { fatalError() }
    open func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { fatalError() }
    public static func animate(withDuration: TimeInterval, animations: @escaping () -> Void) { fatalError() }
}
public class UIImageView: UIView { public var image: UIImage? }
public protocol UIScrollViewDelegate: AnyObject {
    func viewForZooming(in scrollView: UIScrollView) -> UIView?
}
open class UIScrollView: UIView {
    public weak var delegate: UIScrollViewDelegate?
    public var minimumZoomScale: CGFloat = 1
    public var maximumZoomScale: CGFloat = 1
    public var zoomScale: CGFloat = 1
    public var bouncesZoom = true
    public var isZooming: Bool { fatalError() }
    public var contentLayoutGuide: UILayoutGuide { fatalError() }
    public var frameLayoutGuide: UILayoutGuide { fatalError() }
    public var panGestureRecognizer: UIPanGestureRecognizer { fatalError() }
    public func setZoomScale(_ scale: CGFloat, animated: Bool) { fatalError() }
    public func zoom(to rect: CGRect, animated: Bool) { fatalError() }
}
public protocol UIGestureRecognizerDelegate: AnyObject {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool
}
public class UIGestureRecognizer: NSObject {
    public enum State { case possible, began, changed, ended, cancelled, failed }
    public var state: State { fatalError() }
    public var view: UIView? { fatalError() }
    public var numberOfTouches: Int { fatalError() }
    public weak var delegate: UIGestureRecognizerDelegate?
    public init(target: Any?, action: Selector?) { super.init() }
    public func location(in view: UIView?) -> CGPoint { fatalError() }
    public func require(toFail otherGestureRecognizer: UIGestureRecognizer) { fatalError() }
}
public class UITapGestureRecognizer: UIGestureRecognizer {
    public var numberOfTapsRequired = 1
}
public class UIScreenEdgePanGestureRecognizer: UIPanGestureRecognizer {}
public class UIPanGestureRecognizer: UIGestureRecognizer {
    public var maximumNumberOfTouches = 0
    public func velocity(in view: UIView?) -> CGPoint { fatalError() }
    public func translation(in view: UIView?) -> CGPoint { fatalError() }
}
