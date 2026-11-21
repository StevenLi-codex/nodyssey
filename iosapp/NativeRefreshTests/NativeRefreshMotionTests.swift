import Foundation

@main struct NativeRefreshMotionTests {
    static func main() {
        let standard = NativeRefreshMotionPolicy(reduceMotion: false, appMotionDisabled: false)
        precondition(!standard.disabled)
        precondition(standard.repeats(in: .refreshing))
        precondition(standard.animatesPhase(.success))
        precondition(!standard.animatesPhase(.pulling))
        precondition(!standard.repeats(in: .success))
        for (reduce, appOff) in [(false, true), (true, false), (true, true)] {
            let off = NativeRefreshMotionPolicy(reduceMotion: reduce, appMotionDisabled: appOff)
            precondition(off.disabled, "system OR existing app e-ink preference must suppress ring motion")
            precondition(!off.repeats(in: .refreshing), "no repeatForever when motion is off")
            precondition(!off.animatesPhase(.success))
        }
        let onAgain = NativeRefreshMotionPolicy(reduceMotion: false, appMotionDisabled: false)
        precondition(onAgain.repeats(in: .refreshing), "a new normal policy must resume the same ring")
        print("PASS actual refresh motion policy normal -> app e-ink -> normal; system Reduce Motion truth table")
        print("PASS refresh-only repetition, no phase animation while dragging, and static success policy")
    }
}
