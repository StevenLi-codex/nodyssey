import Foundation

// These topology fixtures execute the extracted shipping resolve/scrollOwners
// methods, not UIKit. The separate iPhoneOS SDK gate checks actual API types.
@MainActor class UIResponder {
    var next: UIResponder?
}
@MainActor class UIView: UIResponder {
    weak var superview: UIView?
    var subviews: [UIView] = []
    var isHidden = false
    var window: UIView? { superview?.window }
    func addSubview(_ child: UIView) {
        subviews.append(child); child.superview = self; child.next = self
    }
}
@MainActor final class Window: UIView {
    override var window: UIView? { self }
}
@MainActor final class UIRefreshControl {}
@MainActor final class UIScrollView: UIView {
    var refreshControl: UIRefreshControl?
    init(refreshable: Bool) {
        refreshControl = refreshable ? UIRefreshControl() : nil
    }
}
@MainActor final class UIViewController: UIResponder {
    let view: UIView
    init(view: UIView) { self.view = view }
}

@MainActor final class Probe: UIView {
    var scroll: UIScrollView?
    var resolving = false
    func attach(_ owner: UIScrollView) { scroll = owner }
    func detach() { scroll = nil }
    func run() { resolve() }
    // SHIPPING_RESOLUTION_METHODS
}

@main struct ScrollResolutionTests {
    @MainActor static func main() {
        let window = Window()
        let root = UIView()
        let controller = UIViewController(view: root)
        window.addSubview(root); root.next = controller
        let list = UIScrollView(refreshable: true)
        let carousel = UIScrollView(refreshable: false)
        let anchor = Probe()
        root.addSubview(list); root.addSubview(carousel); root.addSubview(anchor)
        anchor.run()
        precondition(anchor.scroll === list, "horizontal sibling must not suppress the one actual refresh owner")
        print("PASS refresh owner survives horizontal sibling")

        root.subviews.removeAll(); anchor.superview = nil
        let local = UIView()
        root.addSubview(local); local.addSubview(carousel); local.addSubview(anchor)
        anchor.run()
        precondition(anchor.scroll == nil, "a nearby carousel without a refresh control is not the refresh owner")
        print("PASS nonrefreshable horizontal subtree is not selected")

        local.addSubview(list)
        let second = UIScrollView(refreshable: true)
        local.addSubview(second)
        anchor.run()
        precondition(anchor.scroll == nil, "two real refresh owners must fail closed")
        print("PASS ambiguous actual refresh owners fail closed")

        list.addSubview(carousel); list.addSubview(anchor)
        anchor.run()
        precondition(anchor.scroll === list, "the scroll ancestor must beat sibling search")
        print("PASS refresh ancestor takes precedence")

        carousel.addSubview(anchor)
        anchor.run()
        precondition(anchor.scroll === list, "a nonrefreshable inner scroll must not steal the refresh ancestor")
        print("PASS nested carousel does not steal refresh ancestor")

        let outer = UIScrollView(refreshable: true)
        window.addSubview(outer); outer.addSubview(root)
        root.next = controller
        root.subviews.removeAll(); root.addSubview(anchor)
        anchor.run()
        precondition(anchor.scroll == nil, "a refresh ancestor outside the owning controller must not be borrowed")
        print("PASS resolution stays inside the owning view controller")
    }
}
