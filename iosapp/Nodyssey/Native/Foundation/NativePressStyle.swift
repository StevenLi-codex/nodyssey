import SwiftUI

private struct NativeCardMotionDisabledKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    /// The root supplies the existing e-ink preference; accessibility remains
    /// system-owned and is read independently by each motion consumer.
    var nativeCardMotionDisabled: Bool {
        get { self[NativeCardMotionDisabledKey.self] }
        set { self[NativeCardMotionDisabledKey.self] = newValue }
    }
}

/// Button-owned feedback keeps cancellation, scrolling and accessibility actions
/// native. No gesture recognizer or navigation-wide animation transaction.
struct NativeCardPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativeCardMotionDisabled) private var motionDisabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion && !motionDisabled ? 0.97 : 1)
            // Scale only the presentation; retain the unscaled padded hit region.
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.92 : 1)
            // response/dampingFraction is available on the supported iOS 16 floor.
            .animation(reduceMotion || motionDisabled ? nil : .spring(response: 0.25, dampingFraction: 0.82), value: configuration.isPressed)
    }
}
