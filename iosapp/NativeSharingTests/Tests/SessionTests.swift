import Foundation
import Testing
@testable import Sharing

@MainActor private func sampleDocument() throws -> FloorShareDocument {
    try FloorShareDocument.make(context: .init(content: content([.paragraph([.text("Real reply", .init())])]), threadTitle: "Thread"), postID: 17, page: 2, floor: "#12", origin: "https://forum.example", language: .english)
}

@MainActor @Test func generationChangeDeletesPrivateImageAndRefusesOldSessionExport() throws {
    let session = FloorShareSession()
    session.prepare(try sampleDocument(), dark: false, generation: 3)
    let url = try #require(session.shareURL(generation: 3))
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(session.shareURL(generation: 4) == nil)
    #expect(session.document == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@MainActor @Test func failedReplacementRemovesOldImageAndCanRetry() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = FloorShareSession()
    let doc = try sampleDocument()
    session.prepare(doc, dark: false, generation: 3)
    let old = try #require(session.shareURL(generation: 3))
    let file = root.appendingPathComponent("file")
    try Data([1]).write(to: file)
    session.prepare(doc, dark: false, generation: 3, root: file)
    #expect(session.failure != nil)
    #expect(session.document == nil)
    #expect(session.shareURL(generation: 3) == nil)
    #expect(!FileManager.default.fileExists(atPath: old.path))
    session.prepare(doc, dark: true, generation: 3)
    let new = try #require(session.shareURL(generation: 3))
    #expect(new != old)
    #expect(session.failure == nil)
    session.finish(activityFailed: true)
    #expect(session.failure != nil)
    #expect(!FileManager.default.fileExists(atPath: new.path))
}

@MainActor @Test func cancellationAndDismissalReleaseWithoutClaimingAShareSucceeded() throws {
    let session = FloorShareSession()
    session.prepare(try sampleDocument(), dark: false, generation: 3)
    let url = try #require(session.shareURL(generation: 3))
    session.finish(activityFailed: false)
    #expect(session.document == nil)
    #expect(session.failure == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    session.clear()
    #expect(session.shareURL(generation: 3) == nil)
}
