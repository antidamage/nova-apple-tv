import Foundation

/// What the remote's feel is made of now that the swipe distances are learned
/// from the person using it. Everything else is a constant: there are no settings.
/// See `specs/remote-swipe.md`.
enum SwipeFeel {
    /// Pad widths per second at lift for a short swipe to count as a flick.
    static let flickSpeed = 1.5
    /// Extra lift speed for each item a flick coasts.
    static let coastSpeedPerItem = 1.5
    static let coastMax = 2
    /// Lean of the focused control toward the swipe, in points.
    static let nudgePx = 12.0
    /// A held clickpad edge repeats after `holdDelay`, then every `repeatInterval`.
    static let holdDelay: TimeInterval = 0.45
    static let repeatInterval: TimeInterval = 0.18
    /// One touch moves one item in the lower two thirds of the user's range; above it,
    /// sideways it also switches panel and up or down it moves a second item.
    static let maxStepsPerTouch = 2
    /// Touches shorter than this are noise (a resting thumb), not swipes.
    static let noiseFloorPct = 4.0
}

/// The travel, in % of the pad's width, a swipe needs: `firstStepPct` for one
/// item and `secondStepPct` for two. Everything the engine measures in distance
/// follows from these two.
struct SwipeProfile: Equatable {
    var firstStepPct: Double
    var secondStepPct: Double

    /// Used until enough swipes have been seen, and blended away as they arrive.
    static let initial = SwipeProfile(firstStepPct: 12, secondStepPct: 40)

    /// Travel from the first step to the second.
    var nextStepPct: Double { max(8, secondStepPct - firstStepPct) }
    var flowFirstStepPct: Double { firstStepPct * 0.7 }
    var adjustStepPct: Double { firstStepPct * 0.7 }
    var reversalPct: Double { max(5, firstStepPct * 0.8) }
    var flickMinTravelPct: Double { firstStepPct * 0.5 }

    static let minimumSamples = 10
    static let fullTrustSamples = 40
    /// Clipping the outliers: the range is the 5th to the 95th percentile of the
    /// swipes seen, so one wild flick or an accidental brush does not stretch it.
    static let clip = (low: 0.05, high: 0.95)

    /// The profile for the swipes seen so far. The bottom two thirds of the
    /// range is one movement and the top third two, so the second step starts
    /// two thirds of the way from the low end to the high end.
    static func learned(from reaches: [Double]) -> SwipeProfile {
        guard reaches.count >= minimumSamples else { return initial }
        let sorted = reaches.sorted()
        let low = percentile(sorted, clip.low)
        let high = percentile(sorted, clip.high)
        let first = min(30, max(8, low))
        let second = min(80, max(first + 8, low + (high - low) * 2 / 3))
        let weight = min(1, Double(reaches.count - minimumSamples) / Double(fullTrustSamples - minimumSamples))
        return SwipeProfile(
            firstStepPct: initial.firstStepPct + (first - initial.firstStepPct) * weight,
            secondStepPct: initial.secondStepPct + (second - initial.secondStepPct) * weight)
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        let position = fraction * Double(sorted.count - 1)
        let below = Int(position.rounded(.down)), above = Int(position.rounded(.up))
        return sorted[below] + (sorted[above] - sorted[below]) * (position - Double(below))
    }
}

/// The swipes this person has made, kept on the device. The app writes only what
/// it has measured, never a default, so an update or a reinstall over the top
/// leaves it as it was.
final class SwipeRangeStore {
    static let shared = SwipeRangeStore()
    /// The reaches measured from UIKit touches. The first key held reaches read
    /// from the GameController values, a different measure, and is left as it was.
    static let key = "nova.tv.swipeReaches.v2"
    static let capacity = 200

    private let defaults: UserDefaults
    private(set) var reaches: [Double]
    private(set) var profile: SwipeProfile

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reaches = (defaults.array(forKey: Self.key) as? [Double]) ?? []
        profile = SwipeProfile.learned(from: reaches)
    }

    /// One finished swipe's reach: how far, in % of the pad, it travelled along its axis.
    func record(_ reach: Double) {
        guard reach.isFinite, reach >= SwipeFeel.noiseFloorPct else { return }
        reaches.append(min(100, reach))
        if reaches.count > Self.capacity { reaches.removeFirst(reaches.count - Self.capacity) }
        profile = SwipeProfile.learned(from: reaches)
        defaults.set(reaches, forKey: Self.key)
    }
}
