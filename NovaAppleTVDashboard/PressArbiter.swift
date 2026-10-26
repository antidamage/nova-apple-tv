import Foundation

/// Decides what an arrow press on the remote does when a thumb may also be on the
/// touch surface. It is pure: the controller reports what happened and when, and
/// carries out what comes back. The rules are in `specs/remote-swipe.md`.
///
/// A press is the touch's own **edge contact**, read twice, only if the touch moved
/// focus within `contactWindow` before the press began, or while it was held. Any
/// other press under a thumb is a click: it counts once as it is released, unless
/// the thumb was moving when it was released (a swipe may be starting), in which
/// case the touch's end decides. Held for the hold delay under a still thumb, it
/// counts and repeats.
struct PressArbiter {
    enum Action: Equatable {
        case step(RemoteDirection)
        case startRepeat(type: Int, RemoteDirection, after: TimeInterval)
        case stopRepeat
    }

    static let contactWindow: TimeInterval = 0.15

    private struct Pending {
        let type: Int
        let direction: RemoteDirection
        let began: TimeInterval
        var contact: Bool
        var fired = false
        var released = false
    }

    private var touchDown = false
    private var lastStepAt: TimeInterval?
    private var lastMoveAt: TimeInterval?
    private var pending: Pending?
    private var repeating: Int?

    private func stepRecently(before t: TimeInterval) -> Bool {
        lastStepAt.map { t - $0 < Self.contactWindow } ?? false
    }

    mutating func touchBegan(at t: TimeInterval) {
        touchDown = true
        lastMoveAt = nil
    }

    /// The thumb has moved by more than a resting wobble.
    mutating func thumbMoved(at t: TimeInterval) {
        lastMoveAt = t
    }

    /// The touch moved focus (a swipe step or a panel switch).
    mutating func swipeStepped(at t: TimeInterval) -> [Action] {
        lastStepAt = t
        if pending?.fired == false { pending?.contact = true }
        guard repeating != nil else { return [] }
        repeating = nil
        return [.stopRepeat]
    }

    mutating func touchEnded(at t: TimeInterval) -> [Action] {
        touchDown = false
        guard let held = pending, !held.fired, held.released else { return [] }
        pending = nil
        return held.contact ? [] : [.step(held.direction)]
    }

    mutating func pressBegan(type: Int, _ direction: RemoteDirection, at t: TimeInterval) -> [Action] {
        var out: [Action] = []
        // A click left waiting for its touch to end is settled now, so no click is lost.
        if let earlier = pending, !earlier.fired, earlier.released, !earlier.contact { out.append(.step(earlier.direction)) }
        pending = nil
        if !touchDown {
            if stepRecently(before: t) { return out }
            repeating = type
            return out + [.step(direction), .startRepeat(type: type, direction, after: SwipeFeel.holdDelay)]
        }
        pending = Pending(type: type, direction: direction, began: t, contact: stepRecently(before: t))
        return out
    }

    /// The hold delay has passed since the press of `type` that began at `began`.
    mutating func holdElapsed(type: Int, began: TimeInterval, at t: TimeInterval) -> [Action] {
        guard var held = pending, held.type == type, held.began == began, !held.fired, !held.released, !held.contact, touchDown,
              lastMoveAt.map({ $0 < held.began }) ?? true else { return [] }
        held.fired = true
        pending = held
        repeating = type
        return [.step(held.direction), .startRepeat(type: type, held.direction, after: SwipeFeel.repeatInterval)]
    }

    mutating func pressEnded(type: Int, at t: TimeInterval) -> [Action] {
        var out: [Action] = []
        if repeating == type {
            repeating = nil
            out.append(.stopRepeat)
        }
        guard var held = pending, held.type == type else { return out }
        if held.fired || held.contact {
            pending = nil
            return out
        }
        if touchDown, lastMoveAt.map({ $0 >= held.began }) == true {
            // The thumb is moving: a swipe may be starting, so the touch's end decides.
            held.released = true
            pending = held
            return out
        }
        pending = nil
        return out + [.step(held.direction)]
    }

    /// Input was turned off: forget everything in flight.
    mutating func reset() -> [Action] {
        pending = nil
        touchDown = false
        guard repeating != nil else { return [] }
        repeating = nil
        return [.stopRepeat]
    }
}
