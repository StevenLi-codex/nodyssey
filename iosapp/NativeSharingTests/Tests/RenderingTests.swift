import Foundation
import SwiftUI
import Testing
#if canImport(AppKit)
import AppKit
#endif
@testable import Sharing

@MainActor @Test func actualRendererProducesPNGAndDisclosesHeightReduction() throws {
    let fixture = try content([.paragraph([.text(String(repeating: "A real long reply. 中文測試 👩🏽‍💻\n", count: 500), .init())])])
    for language in [FloorShareLanguage.english, .simplifiedChinese, .traditionalChinese] {
        for dark in [false, true] {
            let document = try FloorShareDocument.make(context: .init(content: fixture, threadTitle: "A forum thread / 主题 / 主題"), postID: 17, page: 2, floor: "#12", origin: "https://forum.example", language: language)
            let rendered = try FloorShareRenderer.render(document, dark: dark)
            #expect(Array(rendered.png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
            #expect(rendered.document.truncated)
            #expect(rendered.document.source == document.source)
            #expect(rendered.document.author == document.author)
            #expect(rendered.document.body.count < document.body.count)
            #if canImport(AppKit)
            let bitmap = try #require(NSBitmapImageRep(data: rendered.png))
            #expect(bitmap.pixelsWide == 780)
            #expect(bitmap.pixelsHigh > 0 && bitmap.pixelsHigh <= 4000)
            #endif
            if let directory = ProcessInfo.processInfo.environment["SHARING_RENDER_OUTPUT"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try rendered.png.write(to: folder.appendingPathComponent("\(language)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}

@Test func temporaryArtifactIsUniquePrivateAndRemovedIdempotently() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try FloorShareArtifact(png: Data([1, 2, 3]), root: root)
    let second = try FloorShareArtifact(png: Data([4, 5, 6]), root: root)
    #expect(first.url != second.url)
    #expect(try Data(contentsOf: first.url) == Data([1, 2, 3]))
    let permissions = try FileManager.default.attributesOfItem(atPath: first.url.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    try first.remove()
    try first.remove()
    #expect(!FileManager.default.fileExists(atPath: first.url.path))
    #expect(FileManager.default.fileExists(atPath: second.url.path))
    try second.remove()
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func artifactIsRemovedOnOwnerReleaseAndFailedWriteDoesNotLeaveDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var artifact: FloorShareArtifact? = try .init(png: Data([1]), root: root)
    let url = try #require(artifact?.url)
    artifact = nil
    #expect(!FileManager.default.fileExists(atPath: url.path))
    let regularFile = root.appendingPathComponent("not-a-directory")
    try Data([1]).write(to: regularFile)
    #expect(throws: (any Error).self) { try FloorShareArtifact(png: Data([1]), root: regularFile) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["not-a-directory"])
}
