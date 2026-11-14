import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeMedia

@Test func uploadStagingCopiesOriginalBytesAndEnforcesBoundedLocalFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("animation.gif")
    let original = Data([71, 73, 70, 56, 57, 97, 1, 2, 3, 4])
    try original.write(to: source)
    let stager = try MediaUploadFileStager(directory: root.appendingPathComponent("queue"), byteLimit: 10)
    let copy = try stager.copy(source)
    try FileManager.default.removeItem(at: source)
    #expect(try Data(contentsOf: copy) == original)
    #expect(copy.pathExtension == "gif")
    #expect(copy.isFileURL)
    #expect(throws: CocoaError.self) { try stager.copy(URL(string: "https://e.test/remote.gif")!) }
    let large = root.appendingPathComponent("large.gif")
    try Data(repeating: 1, count: 11).write(to: large)
    #expect(throws: CocoaError.self) { try stager.copy(large) }
    #expect(throws: CocoaError.self) { try stager.copy(root) }
}
