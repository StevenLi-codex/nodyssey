// Compile-only UIKit/PhotosUI signatures for CLT. Not runtime or iOS proof.
import SwiftUI
import NodysseyNativeCore
struct NativeRemoteImage: View { let url: String; var aspectFit = true; var body: some View { EmptyView() } }
@MainActor final class EditorFocus: ObservableObject { func handoff(_ action: () -> Void) { action() }; func refocus() {} }
struct MarkedTextEditor: View {
    @Binding var buffer: EditorBuffer
    let focus: EditorFocus
    var isTitle = false
    var accessibilityLabel: String
    var autofocus = false
    var maximumVisibleLines: Int? = nil
    var body: some View { EmptyView() }
}
struct EditorPhotoPicker: View { let model: EditorViewModel; var body: some View { EmptyView() } }
struct NativeStickerPicker: View { let onSelect: (String) -> Void; var body: some View { EmptyView() } }
