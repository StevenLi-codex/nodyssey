// macOS SwiftUI does not export UIViewRepresentable. Compile-only shape, not UIKit execution.
import SwiftUI
import UIKit
protocol UIViewRepresentable: View where Body == Never {
    associatedtype UIViewType: UIView
    associatedtype Coordinator
    typealias Context = ViewerRepresentableContext<Coordinator>
    func makeCoordinator() -> Coordinator
    func makeUIView(context: Context) -> UIViewType
    func updateUIView(_ view: UIViewType, context: Context)
}
struct ViewerRepresentableContext<C> { let coordinator: C }
extension UIViewRepresentable {
    var body: Never { fatalError("Signature check only") }
}
