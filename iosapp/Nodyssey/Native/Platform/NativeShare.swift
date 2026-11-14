import SwiftUI
import UIKit

/// Present in .sheet; share only user-selected text, public links, or loaded images.
/// Image sharing passes UIImage, never an authenticated request URL or its headers.
struct NativeShare: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: (Bool) -> Void = { _ in }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // Saving belongs to NativeImageViewer's explicit add-only Photos flow.
        controller.excludedActivityTypes = [.saveToCameraRoll]
        controller.completionWithItemsHandler = { _, completed, _, _ in
            DispatchQueue.main.async { onComplete(completed) }
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY,
                                        width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
