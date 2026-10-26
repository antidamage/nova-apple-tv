#if DEBUG
import Foundation

/// The swipe engine, fed synthetic touches (pad units, 100 Hz), reading back what it
/// asked for. What each case pins down is in `specs/remote-swipe.md`.
enum SwipeEngineSelfTests {
    static func run() {
        func swipe(_ engine: inout RemoteSwipeEngine, from: (x: Double, y: Double), to: (x: Double, y: Double),
                   seconds: Double, at start: Double = 0, begins: Bool = true, ends: Bool = true) -> [SwipeOutput] {
            let count = max(2, Int(seconds * 100))
            var outputs: [SwipeOutput] = []
            for index in 0...count {
                let fraction = Double(index) / Double(count)
                let x = from.x + (to.x - from.x) * fraction, y = from.y + (to.y - from.y) * fraction
                let time = start + seconds * fraction
                if index == 0 && begins { engine.begin(x: x, y: y, at: time) }
                outputs += engine.sample(x: x, y: y, at: time)
            }
            return ends ? outputs + engine.end(at: start + seconds + 0.01) : outputs
        }
        func steps(_ outputs: [SwipeOutput]) -> [RemoteDirection] {
            outputs.compactMap { if case .step(let direction) = $0 { return direction } else { return nil } }
        }
        func panels(_ outputs: [SwipeOutput]) -> [RemoteDirection] {
            outputs.compactMap { if case .panel(let direction) = $0 { return direction } else { return nil } }
        }
        func coast(_ outputs: [SwipeOutput]) -> [TimeInterval]? {
            for output in outputs { if case .coast(_, let delays) = output { return delays } }
            return nil
        }
        func maxLean(_ outputs: [SwipeOutput]) -> Double {
            outputs.reduce(0) { best, output in
                if case .lean(let dx, let dy) = output { return max(best, abs(dx), abs(dy)) }
                return best
            }
        }

        var engine = RemoteSwipeEngine()
        var out = swipe(&engine, from: (0, 0), to: (0.6, 0), seconds: 0.5)
        assert(steps(out) == [.right] && panels(out).isEmpty, "A short swipe (30% of the pad) moves one item")
        assert(out.last == .lean(dx: 0, dy: 0), "The lean is released on lift")
        out = swipe(&engine, from: (0, 0), to: (0.16, 0), seconds: 0.5, at: 10)
        assert(steps(out).isEmpty, "A crawl under the first-step travel moves nothing")
        assert(maxLean(out) > 0 && maxLean(out) < 12, "It leans toward the step without taking it")
        out = swipe(&engine, from: (-0.5, 0), to: (0.5, 0), seconds: 0.8, at: 20)
        assert(steps(out) == [.right] && panels(out) == [.right],
               "A long sideways swipe (50%) takes a step, then switches panel")
        out = swipe(&engine, from: (0.5, 0), to: (-0.5, 0), seconds: 0.8, at: 25)
        assert(steps(out) == [.left] && panels(out) == [.left], "and the same to the left")
        out = swipe(&engine, from: (0, -0.5), to: (0, 0.5), seconds: 0.8, at: 28)
        assert(steps(out) == [.up, .up] && panels(out).isEmpty, "A long swipe up moves two items, not a panel")
        out = swipe(&engine, from: (0, 0), to: (0, 0.6), seconds: 0.5, at: 30)
        assert(steps(out) == [.up], "Swiping up on the pad steps up")
        out = swipe(&engine, from: (0, 0), to: (-0.6, -0.1), seconds: 0.5, at: 40)
        assert(steps(out) == [.left], "A slightly diagonal swipe keeps the dominant axis")
        out = swipe(&engine, from: (0, 0), to: (0.3, 0.3), seconds: 0.5, at: 50)
        assert(steps(out).isEmpty, "A true diagonal commits to neither axis")

        out = swipe(&engine, from: (0, 0), to: (0.16, 0), seconds: 0.04, at: 60)
        assert(steps(out) == [.right] && coast(out) == nil, "A fast short flick steps once and does not coast")
        out = swipe(&engine, from: (0, 0), to: (0, 1.0), seconds: 0.1, at: 70)
        assert(steps(out) == [.up, .up] && coast(out) == [0.11, 0.17], "A hard flick up coasts at most two more")
        var rowEnd = RemoteSwipeEngine()
        rowEnd.canCoast = { _ in false }
        out = swipe(&rowEnd, from: (0, 0), to: (0, 1.0), seconds: 0.1)
        assert(steps(out) == [.up, .up] && coast(out) == nil, "A flick does not coast on out of its column or panel")
        out = swipe(&engine, from: (0, 0), to: (1.0, 0), seconds: 0.1, at: 75)
        assert(steps(out) == [.right] && panels(out) == [.right] && coast(out) == nil,
               "A hard flick sideways ends in the panel switch and does not coast on from it")

        // Reversal: back off from a step and the engine starts over from the turn.
        var turn = RemoteSwipeEngine()
        let there = swipe(&turn, from: (0, 0), to: (0.6, 0), seconds: 0.3, ends: false)
        let back = swipe(&turn, from: (0.6, 0), to: (0.2, 0), seconds: 0.4, at: 0.3, begins: false)
        assert(steps(there) == [.right] && steps(back) == [.left], "Reversing moves back one item")

        // Flow: a swipe soon after a step in the same direction needs less travel.
        var flow = RemoteSwipeEngine()
        _ = swipe(&flow, from: (0, 0), to: (0.6, 0), seconds: 0.3)
        out = swipe(&flow, from: (0, 0), to: (0.2, 0), seconds: 0.5, at: 0.4)
        assert(steps(out) == [.right], "A swipe straight after a step takes the shorter flow travel")
        var rested = RemoteSwipeEngine()
        _ = swipe(&rested, from: (0, 0), to: (0.6, 0), seconds: 0.3)
        out = swipe(&rested, from: (0, 0), to: (0.2, 0), seconds: 0.5, at: 1.5)
        assert(steps(out).isEmpty, "and a rested one needs the full first-step travel")

        // Nowhere to go: the control leans and nothing moves. A panel switch with no
        // panel to go to is the same.
        var wall = RemoteSwipeEngine()
        wall.classify = { _ in .bounce }
        out = swipe(&wall, from: (0, 0), to: (0.8, 0), seconds: 0.6)
        assert(steps(out).isEmpty && maxLean(out) > 10, "At the end of a row the control leans and nothing moves")
        var lastPanel = RemoteSwipeEngine()
        lastPanel.classifyPanel = { _ in .bounce }
        out = swipe(&lastPanel, from: (-0.5, 0), to: (0.5, 0), seconds: 0.8)
        assert(steps(out) == [.right] && panels(out).isEmpty, "A long swipe with no panel beyond only takes its step")

        // Each step of one swipe is judged from where the step before it landed.
        var landed = 0
        var chained = RemoteSwipeEngine()
        chained.didStep = { _ in landed += 1 }
        chained.classify = { _ in landed >= 1 ? .bounce : .move }
        out = swipe(&chained, from: (0, -0.42), to: (0, 0.42), seconds: 0.8)
        assert(steps(out) == [.up] && landed == 1, "A second step with nowhere to go after the first is not taken")

        // An unlocked dial: steps finely, nothing coasts, no panel switch.
        var dial = RemoteSwipeEngine()
        dial.adjusting = true
        dial.classify = { _ in .bounce }
        out = swipe(&dial, from: (0, 0), to: (0, 0.6), seconds: 0.2)
        assert(steps(out) == [.up, .up, .up] && coast(out) == nil, "A dial steps finely and never coasts")
        out = swipe(&dial, from: (-0.5, 0), to: (0.5, 0), seconds: 0.8, at: 10)
        assert(panels(out).isEmpty && !steps(out).isEmpty, "A long sideways swipe on an unlocked dial stays on the dial")

        // The range is learned: the bottom two thirds is one movement, the top third two.
        var learnt = RemoteSwipeEngine()
        learnt.profile = SwipeProfile(firstStepPct: 20, secondStepPct: 50)
        out = swipe(&learnt, from: (0, 0), to: (0.3, 0), seconds: 0.5)
        assert(steps(out).isEmpty, "A swipe under the learned first step moves nothing")
        out = swipe(&learnt, from: (0, 0), to: (0.6, 0), seconds: 0.5, at: 10)
        assert(steps(out) == [.right] && panels(out).isEmpty, "A swipe between the learned steps moves one")
        out = swipe(&learnt, from: (-0.55, 0), to: (0.55, 0), seconds: 0.8, at: 20)
        assert(steps(out) == [.right] && panels(out) == [.right], "A swipe past the learned second step switches panel")
        out = swipe(&learnt, from: (0, -1.0), to: (0, 1.0), seconds: 1.0, at: 30)
        assert(steps(out) == [.up, .up], "and moves no more than two items up or down")
        out = swipe(&engine, from: (0, 0), to: (0.6, 0), seconds: 0.5, at: 40)
        assert(out.contains { if case .measured(let reach) = $0 { return abs(reach - 30) < 0.5 } else { return false } },
               "A finished swipe reports how far it reached")
        out = swipe(&engine, from: (0, 0), to: (0.05, 0), seconds: 0.2, at: 50)
        assert(!out.contains { if case .measured = $0 { return true } else { return false } },
               "A brush that never locks an axis is not a swipe")

        assert(SwipeProfile.learned(from: []) == .initial && SwipeProfile.learned(from: Array(repeating: 30, count: 9)) == .initial,
               "Too few swipes leave the starting profile")
        // 10...49 with one stray brush and one wild flick: the outliers are clipped.
        let reaches = (0..<40).map { 10 + Double($0) } + [2, 95]
        let profile = SwipeProfile.learned(from: reaches)
        assert(abs(profile.firstStepPct - 11.05) < 0.01 && abs(profile.secondStepPct - 35.65) < 0.01,
               "The second step starts two thirds of the way up the clipped range")
        let midway = SwipeProfile.learned(from: Array(repeating: 20, count: 25))
        assert(abs(midway.firstStepPct - 16) < 0.01 && abs(midway.secondStepPct - 34) < 0.01,
               "Fewer than 40 swipes blend with the starting profile")

        let suite = "nova.tv.selftest.swiperange"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = SwipeRangeStore(defaults: defaults)
        assert(store.profile == .initial && store.reaches.isEmpty, "A new install starts from the starting profile")
        store.record(2)
        assert(store.reaches.isEmpty, "A touch under the noise floor is not recorded")
        for index in 0..<250 { store.record(10 + Double(index % 40)) }
        assert(store.reaches.count == SwipeRangeStore.capacity, "Only the latest swipes are kept")
        let reopened = SwipeRangeStore(defaults: defaults)
        assert(reopened.reaches == store.reaches && reopened.profile == store.profile,
               "What was learned is still there after a relaunch")
        defaults.removePersistentDomain(forName: suite)
        print("[NovaTV][tests] swipe engine and learned range passed")
    }
}
#endif
