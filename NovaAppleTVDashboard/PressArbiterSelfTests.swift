#if DEBUG
import Foundation

/// Arrow presses with and without a thumb on the touch surface, in every order the
/// remotes produce them. Each case is a timeline of events; what matters is the
/// steps that come out. See `PressArbiter` and `specs/remote-swipe.md`.
enum PressArbiterSelfTests {
    static func run() {
        let right = 1, down = 2
        func steps(_ actions: [PressArbiter.Action]) -> [RemoteDirection] {
            actions.compactMap { if case .step(let d) = $0 { return d } else { return nil } }
        }
        func repeats(_ actions: [PressArbiter.Action]) -> Bool {
            actions.contains { if case .startRepeat = $0 { return true } else { return false } }
        }

        // No thumb (UI-test presses, the iOS Remote app's buttons): a press steps at
        // once and repeats while held.
        var a = PressArbiter()
        var out = a.pressBegan(type: right, .right, at: 0)
        assert(steps(out) == [.right] && repeats(out), "A press with no thumb steps at once and repeats when held")
        assert(a.pressEnded(type: right, at: 0.1) == [.stopRepeat], "Letting go stops the repeat")

        // Resting thumb on the second-generation clickpad: three clicks, three steps,
        // each as it is released.
        a = PressArbiter()
        a.touchBegan(at: 0)
        var moved: [RemoteDirection] = []
        for i in 0..<3 {
            let t = 1 + Double(i)
            moved += steps(a.pressBegan(type: right, .right, at: t))
            moved += steps(a.pressEnded(type: right, at: t + 0.1))
        }
        assert(moved == [.right, .right, .right], "Every click under a resting thumb counts, at its release")
        assert(steps(a.touchEnded(at: 9)).isEmpty, "and lifting the thumb adds nothing")
        a = PressArbiter()
        a.touchBegan(at: 0)
        moved = steps(a.pressBegan(type: right, .right, at: 1)) + steps(a.pressEnded(type: right, at: 1.1))
            + steps(a.pressBegan(type: down, .down, at: 1.5)) + steps(a.pressEnded(type: down, at: 1.6))
        assert(moved == [.right, .down], "Right then Down under one resting thumb is both")

        // A swipe earlier in the same touch does not swallow later clicks.
        a = PressArbiter()
        a.touchBegan(at: 0)
        a.thumbMoved(at: 0.2)
        _ = a.swipeStepped(at: 0.3)
        moved = steps(a.pressBegan(type: down, .down, at: 2)) + steps(a.pressEnded(type: down, at: 2.1))
        assert(moved == [.down], "A click a while after a swipe, thumb still down, counts")

        // The first-generation remote's edge contact: a press within 150 ms of the
        // swipe's step is the swipe read twice, before or after the step.
        a = PressArbiter()
        a.touchBegan(at: 0)
        _ = a.swipeStepped(at: 0.3)
        moved = steps(a.pressBegan(type: right, .right, at: 0.35)) + steps(a.pressEnded(type: right, at: 0.4))
            + steps(a.touchEnded(at: 0.5))
        assert(moved.isEmpty, "An edge press just after the swipe's step is dropped")
        a = PressArbiter()
        a.touchBegan(at: 0)
        _ = a.pressBegan(type: right, .right, at: 0.1)
        a.thumbMoved(at: 0.15)
        _ = a.swipeStepped(at: 0.3)
        moved = steps(a.pressEnded(type: right, at: 0.35)) + steps(a.touchEnded(at: 0.5))
        assert(moved.isEmpty, "A press held while the touch swipes is part of that swipe")

        // Released while the thumb is moving: a swipe may be starting, so the touch's
        // end decides.
        a = PressArbiter()
        a.touchBegan(at: 0)
        _ = a.pressBegan(type: right, .right, at: 0.1)
        a.thumbMoved(at: 0.15)
        assert(steps(a.pressEnded(type: right, at: 0.2)).isEmpty, "Released mid-roll, it waits")
        assert(steps(a.touchEnded(at: 0.4)) == [.right], "and counts once when the touch ends without a swipe")
        a = PressArbiter()
        a.touchBegan(at: 0)
        _ = a.pressBegan(type: right, .right, at: 0.1)
        a.thumbMoved(at: 0.15)
        _ = a.pressEnded(type: right, at: 0.2)
        _ = a.swipeStepped(at: 0.3)
        assert(steps(a.touchEnded(at: 0.4)).isEmpty, "or is dropped when the touch did swipe")
        a = PressArbiter()
        a.touchBegan(at: 0)
        _ = a.pressBegan(type: right, .right, at: 0.1)
        a.thumbMoved(at: 0.15)
        _ = a.pressEnded(type: right, at: 0.2)
        assert(steps(a.pressBegan(type: right, .right, at: 0.6)) == [.right],
               "A waiting click is settled before the next press, so it is not lost")

        // Holding under a still thumb repeats; a moving thumb does not.
        a = PressArbiter()
        a.touchBegan(at: 0)
        _ = a.pressBegan(type: right, .right, at: 1)
        out = a.holdElapsed(type: right, began: 1, at: 1.45)
        assert(steps(out) == [.right] && repeats(out), "Held still, it steps and repeats")
        assert(a.swipeStepped(at: 2) == [.stopRepeat], "A swipe that moves focus stops the repeat")
        out = a.pressEnded(type: right, at: 2.1)
        assert(steps(out).isEmpty, "and the release adds no step")
        a = PressArbiter()
        a.touchBegan(at: 0)
        _ = a.pressBegan(type: right, .right, at: 1)
        a.thumbMoved(at: 1.2)
        assert(a.holdElapsed(type: right, began: 1, at: 1.45).isEmpty, "Held while the thumb moves, it does not repeat")
        a = PressArbiter()
        a.touchBegan(at: 0)
        _ = a.pressBegan(type: right, .right, at: 1)
        _ = a.pressEnded(type: right, at: 1.1)
        _ = a.pressBegan(type: right, .right, at: 1.3)
        assert(a.holdElapsed(type: right, began: 1, at: 1.45).isEmpty, "An earlier click's hold timer does nothing to a later press")

        // After a swipe with no thumb left on the surface.
        a = PressArbiter()
        a.touchBegan(at: 0)
        _ = a.swipeStepped(at: 0.3)
        _ = a.touchEnded(at: 0.35)
        assert(steps(a.pressBegan(type: right, .right, at: 0.4)).isEmpty, "A press right after a swipe's step is that swipe's")
        _ = a.pressEnded(type: right, at: 0.45)
        assert(steps(a.pressBegan(type: right, .right, at: 1)) == [.right], "a later one counts")

        // A press that begins under the thumb and ends after it lifts counts once.
        a = PressArbiter()
        a.touchBegan(at: 0)
        moved = steps(a.pressBegan(type: right, .right, at: 1)) + steps(a.touchEnded(at: 1.1))
            + steps(a.pressEnded(type: right, at: 1.2))
        assert(moved == [.right], "A tap whose press outlasts the touch counts once")

        // Input turned off: nothing in flight survives.
        a = PressArbiter()
        a.touchBegan(at: 0)
        _ = a.pressBegan(type: right, .right, at: 1)
        _ = a.reset()
        assert(steps(a.pressEnded(type: right, at: 1.1)).isEmpty && steps(a.touchEnded(at: 1.2)).isEmpty,
               "A reset forgets the press")
        print("[NovaTV][tests] press arbitration passed")
    }
}
#endif
