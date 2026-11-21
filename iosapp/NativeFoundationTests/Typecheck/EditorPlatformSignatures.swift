// Compile-only UIKit/PhotosUI signatures for CLT. Not runtime or iOS proof.
import SwiftUI
import NodysseyNativeCore
struct NativeRemoteImage: View { let url: String; var aspectFit = true; var onOpen: (() -> Void)? = nil; var body: some View { EmptyView() } }
@MainActor final class EditorFocus: ObservableObject { func handoff(preservingInput: Bool = false, _ action: () -> Void) { action() }; var awaitingReplyEmojiMeasurement: Bool { fatalError("Signature fixture") }; func applyBody(_ buffer: EditorBuffer) { fatalError("Signature fixture") }; func applyReplyInputMode(_ mode: EditorReplyInputMode) { fatalError("Signature fixture") }; func refocus() {} }
struct MarkedTextEditor: View {
    @Binding var buffer: EditorBuffer
    let focus: EditorFocus
    var isTitle = false
    var accessibilityLabel: String
    var autofocus = false
    var maximumVisibleLines: Int? = nil
    var replyInputContent: AnyView? = nil
    var onReplyInputMode: ((EditorReplyInputMode) -> Void)? = nil
    var body: some View { EmptyView() }
}
struct EditorPhotoPicker: View { let model: EditorViewModel; var body: some View { EmptyView() } }
struct NativeStickerPicker: View { let onSelect: (String) -> Void; var compactKeyboard = false; var onManage: (() -> Void)? = nil; var body: some View { EmptyView() } }
