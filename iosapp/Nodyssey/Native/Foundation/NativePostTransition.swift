import SwiftUI
import NodysseyNativeCore

/// One home-feed handoff, not a second navigation owner. Destination UUIDs keep
/// repeated visits to the same post from borrowing another route's source.
@MainActor final class NativePostTransition: ObservableObject {
    struct Source: Hashable {
        let feedID: UUID
        let postID: Int64
    }
    private struct Link {
        let destinationID: UUID
        let source: Source
        let generation: Int
    }
    @Published private var link: Link?

    func record(destination: NativeDestination, source: Source, generation: Int) {
        guard destination.route == "PostDetail", destination.arguments["postId"]?.int == source.postID else { return }
        link = Link(destinationID: destination.id, source: source, generation: generation)
    }

    func source(for destination: NativeDestination, directDestinationID: UUID?, generation: Int) -> Source? {
        guard let link, link.generation == generation,
              destination.id == directDestinationID, destination.id == link.destinationID,
              destination.route == "PostDetail", destination.arguments["postId"]?.int == link.source.postID else { return nil }
        return link.source
    }
}

struct NativePostTransitionContext {
    let namespace: Namespace.ID
    let handoff: NativePostTransition
}
private struct NativePostTransitionKey: EnvironmentKey {
    static let defaultValue: NativePostTransitionContext? = nil
}
extension EnvironmentValues {
    var nativePostTransition: NativePostTransitionContext? {
        get { self[NativePostTransitionKey.self] }
        set { self[NativePostTransitionKey.self] = newValue }
    }
}

extension View {
    func nativePostTransitionSource(_ source: NativePostTransition.Source?) -> some View {
        modifier(NativePostTransitionSource(source: source))
    }
    func nativePostTransitionDestination(_ source: NativePostTransition.Source?, namespace: Namespace.ID) -> some View {
        modifier(NativePostTransitionDestination(source: source, namespace: namespace))
    }
}

private struct NativePostTransitionSource: ViewModifier {
    @Environment(\.nativePostTransition) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativeCardMotionDisabled) private var motionDisabled
    let source: NativePostTransition.Source?
    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS) && compiler(>=6.0)
        if #available(iOS 18.0, *), !reduceMotion, !motionDisabled, let context, let source {
            content.matchedTransitionSource(id: source, in: context.namespace)
        } else { content }
        #else
        content
        #endif
    }
}

private struct NativePostTransitionDestination: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativeCardMotionDisabled) private var motionDisabled
    let source: NativePostTransition.Source?
    let namespace: Namespace.ID
    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS) && compiler(>=6.0)
        if #available(iOS 18.0, *), !reduceMotion, !motionDisabled, let source {
            content.navigationTransition(.zoom(sourceID: source, in: namespace))
        } else { content }
        #else
        content
        #endif
    }
}
