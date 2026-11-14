import Foundation

/// Exactly one locally-created image. No shared directory sweep or content-based filenames.
/// The preview/session owns this lease until activity completion, cancellation or dismissal.
final class FloorShareArtifact {
    let url: URL
    private let directory: URL

    init(png: Data, root: URL = FileManager.default.temporaryDirectory) throws {
        directory = root.appendingPathComponent("nodyssey-floor-" + UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent("Nodyssey.png")
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            try png.write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            #if os(iOS)
            try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            #endif
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    deinit { try? remove() }
}
