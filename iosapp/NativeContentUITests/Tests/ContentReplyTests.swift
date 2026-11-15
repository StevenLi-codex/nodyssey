import Testing
import NodysseyNativeCore
@testable import NativeContentState

@Test func guestReplyRequestsSignInWithoutComposerArguments() {
    #expect(ContentReplyAction.resolve(postID: 9007199254740993, signedIn: false, loaded: true, quote: nil) == .signIn)
}

@Test func directReplyWaitsForThreadAndDoesNotInheritQuote() {
    #expect(ContentReplyAction.resolve(postID: 42, signedIn: true, loaded: false, quote: nil) == .unavailable)
    #expect(ContentReplyAction.resolve(postID: 9007199254740993, signedIn: true, loaded: true, quote: nil) == .compose([
        "postId": .integer(9007199254740993), "reply": .bool(true)
    ]))
}

@Test func floorReplyPreservesQuotationAndRejectsOverflowFloor() {
    let nodes: JSONValue = .array([.object(["type": .string("p"), "inlines": .array([.object(["type": .string("t"), "text": .string("quoted text")])])])])
    let quote: JSONValue = .object(["floor": .string("#21"), "authorName": .string("reader"), "nodes": nodes])
    #expect(ContentReplyAction.resolve(postID: 42, signedIn: true, loaded: true, quote: quote) == .compose([
        "postId": .integer(42), "reply": .bool(true), "quotedFloor": .integer(21),
        "replyToAuthor": .string("reader"), "replyToText": .string("quoted text")
    ]))
    #expect(ContentReplyAction.resolve(postID: 42, signedIn: true, loaded: true, quote: .object(["floor": .string("#2147483648")])) == .compose([
        "postId": .integer(42), "reply": .bool(true)
    ]))
}
