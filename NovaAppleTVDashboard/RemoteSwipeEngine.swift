import Foundation

/// What taking the next step in a direction would do, as the band answers it.
enum SwipeStepKind {
    /// Lands on another control.
    case move
    /// There is nowhere to go. The control leans, nothing moves.
    case bounce
}

/// What the engine asks of the band. Lean is the focused control's offset in
/// points, screen axes (y grows downward).
enum SwipeOutput: Equatable {
    case step(RemoteDirection)
    /// The second step of a long horizontal swipe: switch to the next panel.
    case panel(RemoteDirection)
    case lean(dx: Double, dy: Double)
    /// Carry on in `direction` after lift; one step after each delay.
    case coast(RemoteDirection, delays: [TimeInterval])
    /// A finished swipe's reach, in % of the pad, for the range the engine learns from.
    case measured(reach: Double)
}

/// Turns one touch on the Siri Remote's surface into steps. It is pure: the
/// caller supplies positions and times, and applies the outputs. The behaviour,
/// and what every number means, is in `specs/remote-swipe.md`.
///
/// Positions are the pad's own units, -1...1 per axis with y up, so a distance in
/// "% of the pad" is `delta * 50`.
struct RemoteSwipeEngine {
    /// The user's swipe range, as learned so far (`SwipeRangeStore`).
    var profile = SwipeProfile.initial
    /// An unlocked dial is being adjusted: vertical travel steps by
    /// `adjustStepPct`, nothing is a boundary or a bounce, and nothing coasts.
    var adjusting = false
    var classify: (RemoteDirection) -> SwipeStepKind = { _ in .move }
    /// Called the moment a step is taken, before the next one is judged. The band
    /// moves focus here, so a swipe of several steps classifies each one from
    /// where the one before it landed, not from where the swipe began.
    var didStep: (RemoteDirection) -> Void = { _ in }
    /// Whether a panel switch in a direction would go anywhere, and the switch itself.
    var classifyPanel: (RemoteDirection) -> SwipeStepKind = { _ in .move }
    var didPanel: (RemoteDirection) -> Void = { _ in }
    /// Whether the next step in a direction stays in the same column and panel. A
    /// flick coasts only while it does.
    var canCoast: (RemoteDirection) -> Bool = { _ in true }

    static let axisLockPct = 3.0
    static let axisDominance = 1.4
    static let flowWindow: TimeInterval = 0.35
    static let velocityWindow: TimeInterval = 0.08
    static let coastGaps: [TimeInterval] = [0.11, 0.17, 0.23, 0.29]

    private var active = false
    private var beganAt: TimeInterval = 0
    private var startX = 0.0
    private var startY = 0.0
    private var horizontal: Bool?
    private var sign = 1.0
    private var anchor = 0.0
    private var peakTravel = 0.0
    private var peakCoord = 0.0
    private var steps = 0
    private var minCoord = 0.0
    private var maxCoord = 0.0
    private var blocked = false
    private var panelTaken = false
    private var samples: [(t: TimeInterval, c: Double)] = []
    private var lastStepAt: TimeInterval?
    private var lastStepDirection: RemoteDirection?
    private var lastLean = (dx: 0.0, dy: 0.0)

    /// Whether this touch has committed to an axis, which is what makes it a swipe
    /// rather than a tap or a click.
    var hasLockedAxis: Bool { horizontal != nil }

    mutating func begin(x: Double, y: Double, at t: TimeInterval) {
        active = true
        beganAt = t
        startX = x
        startY = y
        horizontal = nil
        steps = 0
        blocked = false
        panelTaken = false
        peakTravel = 0
        samples.removeAll()
        lastLean = (0, 0)
    }

    mutating func sample(x: Double, y: Double, at t: TimeInterval) -> [SwipeOutput] {
        guard active else { return [] }
        if horizontal == nil {
            let dx = (x - startX) * 50, dy = (y - startY) * 50
            guard max(abs(dx), abs(dy)) >= Self.axisLockPct else { return [] }
            if abs(dx) >= abs(dy) * Self.axisDominance {
                horizontal = true; sign = dx > 0 ? 1 : -1; anchor = startX
            } else if abs(dy) >= abs(dx) * Self.axisDominance {
                horizontal = false; sign = dy > 0 ? 1 : -1; anchor = startY
            } else {
                return []
            }
            peakCoord = anchor
            minCoord = anchor
            maxCoord = anchor
            peakTravel = 0
        }
        let coord = horizontal == true ? x : y
        samples.append((t, coord))
        minCoord = min(minCoord, coord)
        maxCoord = max(maxCoord, coord)
        samples.removeAll { t - $0.t > Self.velocityWindow }

        var travel = (coord - anchor) * sign * 50
        if travel > peakTravel {
            peakTravel = travel
            peakCoord = coord
        } else if peakTravel - travel >= profile.reversalPct {
            // Backed off far enough to mean it: start over from the turning point.
            anchor = peakCoord
            sign = -sign
            steps = 0
            blocked = false
            panelTaken = false
            travel = (coord - anchor) * sign * 50
            peakTravel = travel
            peakCoord = coord
        }

        var out: [SwipeOutput] = []
        var progress = 0.0
        while true {
            // One movement below the top third of the user's range, two above it.
            if !adjusting && steps >= SwipeFeel.maxStepsPerTouch { break }
            let direction = currentDirection
            // The first step of a swipe moves inside the panel; the second, going
            // sideways, is the long swipe that switches panels.
            let isPanel = horizontal == true && steps == 1 && !adjusting
            let kind = isPanel ? classifyPanel(direction) : adjusting ? SwipeStepKind.move : classify(direction)
            let need = requiredTravel(direction)
            if travel < need {
                progress = max(0, travel) / need
                break
            }
            if kind == .bounce {
                blocked = true
                progress = 1
                break
            }
            steps += 1
            lastStepAt = t
            lastStepDirection = direction
            if isPanel {
                out.append(.panel(direction))
                panelTaken = true
                didPanel(direction)
            } else {
                out.append(.step(direction))
                didStep(direction)
            }
            anchor += sign * need / 50
            travel -= need
            peakTravel = travel
            peakCoord = coord
        }

        let leanPx = SwipeFeel.nudgePx * (1 - (1 - progress) * (1 - progress))
        let lean = horizontal == true ? (dx: sign * leanPx, dy: 0.0) : (dx: 0.0, dy: -sign * leanPx)
        if abs(lean.dx - lastLean.dx) >= 0.5 || abs(lean.dy - lastLean.dy) >= 0.5 {
            lastLean = lean
            out.append(.lean(dx: lean.dx, dy: lean.dy))
        }
        return out
    }

    mutating func end(at t: TimeInterval) -> [SwipeOutput] {
        guard active else { return [] }
        active = false
        var out: [SwipeOutput] = []
        if horizontal != nil, !adjusting, !blocked,
           let first = samples.first, let last = samples.last, last.t - first.t >= 0.01 {
            let speed = (last.c - first.c) * sign / 2 / (last.t - first.t)
            let direction = currentDirection
            if speed >= SwipeFeel.flickSpeed {
                let travel = (last.c - anchor) * sign * 50
                // A flick takes one step.
                if steps == 0, travel >= profile.flickMinTravelPct, classify(direction) == .move {
                    out.append(.step(direction))
                    steps = 1
                    lastStepAt = t
                    lastStepDirection = direction
                    didStep(direction)
                }
                // A flick coasts along a column or row, never on from a panel switch.
                if steps > 0, !panelTaken, classify(direction) == .move, canCoast(direction) {
                    let extra = min(SwipeFeel.coastMax, Self.coastGaps.count,
                                    Int((speed - SwipeFeel.flickSpeed) / SwipeFeel.coastSpeedPerItem))
                    if extra > 0 { out.append(.coast(direction, delays: Array(Self.coastGaps.prefix(extra)))) }
                }
            }
        }
        if horizontal != nil, !adjusting {
            out.append(.measured(reach: (maxCoord - minCoord) * 50))
        }
        out.append(.lean(dx: 0, dy: 0))
        lastLean = (0, 0)
        return out
    }

    private var currentDirection: RemoteDirection {
        if horizontal == true { return sign > 0 ? .right : .left }
        return sign > 0 ? .up : .down
    }

    private func requiredTravel(_ direction: RemoteDirection) -> Double {
        let base: Double
        if adjusting && horizontal == false {
            base = profile.adjustStepPct
        } else if steps == 0 {
            let flowing = lastStepDirection == direction && lastStepAt.map { beganAt - $0 < Self.flowWindow } == true
            base = flowing ? profile.flowFirstStepPct : profile.firstStepPct
        } else {
            base = profile.nextStepPct
        }
        return base
    }
}
