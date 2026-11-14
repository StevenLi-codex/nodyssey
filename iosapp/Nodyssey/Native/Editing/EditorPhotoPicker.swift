import SwiftUI
@preconcurrency import PhotosUI
import UniformTypeIdentifiers
import NodysseyNativeCore

/// File representations are copied while the provider URL is valid. Never loads UIImage/Data.
struct EditorPhotoPicker: UIViewControllerRepresentable {
    let model: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 8
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    @MainActor final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: EditorPhotoPicker
        init(_ parent: EditorPhotoPicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            parent.model.importFiles(results.prefix(8).map { result in
                let provider = result.itemProvider
                return { try await Self.copy(provider) }
            })
        }
        private static func copy(_ provider: NSItemProvider) async throws -> URL {
            try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                    do {
                        guard let url else { throw CocoaError(.fileReadUnknown) }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                        guard size > 0, size <= 25 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeEditorAttachments", isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let target = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
                        try FileManager.default.copyItem(at: url, to: target)
                        continuation.resume(returning: target)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
    }
}
