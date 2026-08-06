import Foundation

// The Phonoscope driver-lane evaluator.
//
// Port of `nova-visualiser/src/core/parameter_drivers.{h,cpp}`, which is itself
// a port of `nova-ha-dashboard/lib/phonoscope-drivers.ts` — the reference. All
// three must agree, and `tests/conformance/parameter-drivers` plus
// `ParitySelfTests.testParameterDriverParity()` are what prove it.
//
// Kept in its own file rather than inside PhonoscopeStore so the standalone
// parity script can compile just this and a harness, with no UIKit or MusicKit
// in the way.

/// Private picture-level effects. Household configuration, declared by no
/// module manifest, resolved through the same lanes as everything else.
enum PhonoscopeEffectID {
    static let glowBlur = "__glowBlur"
    static let glowOpacity = "__glowOpacity"
    static let glowOverdrive = "__glowOverdrive"
    static let glowClamp = "__glowClamp"
    static let glowBlend = "__glowBlend"
    static let messageScale = "__messageScale"
    /// The centre image's base height, as a percentage of the frame. A separate
    /// axis from the scale above: this is how big the image is, that is a
    /// multiplier on top of it.
    static let centreHeight = "__centreHeight"
    // Frame geometry, as fractions of the render view, plus the vignette that
    // frames it. These replaced a fixed one-third letterbox and five hardcoded
    // gradient numbers, so that they are driven is the whole point.
    static let backgroundHeight = "__bgHeight"
    static let backgroundWidth = "__bgWidth"
    static let vignetteOpacity = "__vignetteOpacity"
    static let vignetteSize = "__vignetteSize"
    // How the scene layer meets the backdrop: 0 linear, 1 screen, 2 overlay,
    // 3 multiply.
    static let sceneBlend = "__sceneBlend"
    // `__hueOffset` and `__themeChange` are resolved by the dashboard rather
    // than by an engine: one drives House Party lighting, the other advances
    // the rotation.
}

/// A combined value may exceed the effect's declared maximum — stacking lanes is
/// meant to be able to overshoot. This is only the guard that keeps the
/// simulation finite: at most four full ranges above the resting value.
let phonoscopeOvershootRanges: Double = 4
/// The most a lane's summed driver signal can reach before it is clamped.
let phonoscopeMaxLaneSignal: Double = 4

struct PhonoscopeEffectDeclaration: Equatable, Sendable {
    var id: String
    var min: Double
    var max: Double
    var step: Double
    var defaultValue: Double
}

struct PhonoscopeDriverSpec: Equatable, Sendable {
    /// "beat", "downbeat", "timer", "song", "energy", "bass", "mid", "treble",
    /// "random". A raw string rather than an enum because it arrives as JSON
    /// and an unrecognised value must degrade rather than fail to decode.
    var type: String
    var every: Int = 1
    var offset: Int = 0
    var intervalSeconds: Double = 4
    var cadence: String = "beat"
    var transitionSeconds: Double = 0.5

    var isPulse: Bool {
        type == "beat" || type == "downbeat" || type == "timer" || type == "song"
    }
}

/// Sparse on purpose: an unset optional inherits the effect's declaration, so a
/// binding stores only what the user actually chose to change.
struct PhonoscopeLaneBinding: Equatable, Sendable {
    var id: String
    var effect: String
    var min: Double?
    var max: Double?
    var attackSeconds: Double?
    var holdSeconds: Double?
    var releaseSeconds: Double?
    var params: [String: Double] = [:]

    var resolvedAttack: Double { Swift.max(0, attackSeconds ?? 0.05) }
    var resolvedHold: Double { Swift.max(0, holdSeconds ?? 0) }
    var resolvedRelease: Double { Swift.max(0, releaseSeconds ?? 0.6) }
}

struct PhonoscopeLane: Equatable, Sendable {
    var id: String
    var driver: PhonoscopeDriverSpec
    var modifiers: [PhonoscopeDriverSpec] = []
    var bindings: [PhonoscopeLaneBinding] = []
}

/// A lane paired with the settings group it came from, because the state key
/// and the layering order both depend on it.
struct PhonoscopeScopedLane: Equatable, Sendable {
    var groupId: String
    var lane: PhonoscopeLane
}

enum PhonoscopeCombineMode: String, Equatable, Sendable {
    case add
    case strongest
}

struct PhonoscopeSettingsGroupSpec: Equatable, Sendable {
    var id: String
    var name: String = ""
    var moduleId: String = ""
    var lanes: [PhonoscopeLane] = []
    var combine: [String: PhonoscopeCombineMode] = [:]
    var staticSettings: [String: Double] = [:]
    var isDefault: Bool = false
}

struct PhonoscopeMergedSettingsGroups {
    var lanes: [PhonoscopeScopedLane] = []
    var combine: [String: PhonoscopeCombineMode] = [:]
    var staticSettings: [String: Double] = [:]
}

/// Per driver-slot runtime state. A slot is one driver of one binding, so the
/// primary driver and each modifier keep independent envelope phases.
struct PhonoscopeDriverSlotState {
    enum Phase { case idle, attack, hold, release }
    var level: Double = 0
    var phase: Phase = .idle
    var holdRemaining: Double = 0
    var eventKey: String = ""
    var current: Double = 0
    var target: Double = 0
    /// `song` has no natural index, so the slot counts track changes itself.
    var eventCount: Int = 0
    var lastTrackSeed: UInt64 = 0
    var seenTrack: Bool = false
}

struct PhonoscopeLaneEvaluation {
    var values: [String: Double] = [:]
    var driven: Set<String> = []
}

/// FNV-1a over the UTF-8 bytes, mirroring `nova::stableSeed`.
///
/// The offset basis is 1469598103934665603, which is *not* the canonical
/// FNV-1a 64-bit basis. It is what the engines already ship and what the
/// conformance corpus is recorded against. Never substitute a Swift string
/// hash here — those are salted per process.
func stablePhonoscopeSeed(_ value: String) -> UInt64 {
    var hash: UInt64 = 1_469_598_103_934_665_603
    for byte in Array(value.utf8) {
        hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
    return hash
}

/// Whether event `index` is one the driver fires on. `every` is the cycle
/// length and `offset` picks which event within it.
func phonoscopeDriverFires(index: Int, every: Int, offset: Int) -> Bool {
    let cycle = max(1, every)
    if cycle == 1 { return true }
    let phase = max(0, min(cycle - 1, offset))
    return (((index - phase) % cycle) + cycle) % cycle == 0
}

/// How rarely a lane fires, in seconds, used to rank lanes when an effect
/// combines by `strongest`. Longer wins. Continuous drivers return 0 and never
/// win outright.
func phonoscopeDriverPeriodSeconds(
    _ driver: PhonoscopeDriverSpec,
    frame: PhonoscopeSignalFrame
) -> Double {
    let every = Double(max(1, driver.every))
    let secondsPerBeat = max(1e-6, 60.0 / max(1, frame.bpm.isFinite ? frame.bpm : 72))
    let beatsPerBar = Double(max(1, frame.timeSignature))
    // A song is the rarest thing that can happen, and its length is unknown
    // ahead of time, so it always outranks a counted pulse.
    switch driver.type {
    case "song": return .infinity
    case "timer": return every * max(0.25, driver.intervalSeconds.isFinite ? driver.intervalSeconds : 4)
    case "downbeat": return every * beatsPerBar * secondsPerBeat
    case "beat": return every * secondsPerBeat
    default: return 0
    }
}

/// The lanes and scalars of several settings groups, merged in the order the
/// colour group entry named them: lanes stack, scalars layer.
func mergePhonoscopeSettingsGroups(
    _ groups: [PhonoscopeSettingsGroupSpec]
) -> PhonoscopeMergedSettingsGroups {
    var merged = PhonoscopeMergedSettingsGroups()
    for group in groups {
        for lane in group.lanes {
            merged.lanes.append(PhonoscopeScopedLane(groupId: group.id, lane: lane))
        }
        // A later group in the entry's list wins any scalar the earlier ones
        // also set, so reading the list top to bottom reads as layering.
        for (effect, mode) in group.combine { merged.combine[effect] = mode }
        for (id, value) in group.staticSettings { merged.staticSettings[id] = value }
    }
    return merged
}

private func clamp01(_ value: Double) -> Double { min(max(value, 0), 1) }

private func finiteOr(_ value: Double, _ fallback: Double) -> Double {
    value.isFinite ? value : fallback
}

private func clampToDeclaration(_ declaration: PhonoscopeEffectDeclaration, _ value: Double) -> Double {
    let low = min(declaration.min, declaration.max)
    let high = max(declaration.min, declaration.max)
    let bounded = max(low, min(high, finiteOr(value, declaration.defaultValue)))
    guard declaration.step > 0 else { return bounded }
    let stepped = low + ((bounded - low) / declaration.step).rounded() * declaration.step
    return max(low, min(high, stepped))
}

/// The raw 0..1 level a continuous driver carries this tick.
private func levelSignal(_ driver: PhonoscopeDriverSpec, _ frame: PhonoscopeSignalFrame) -> Double {
    if driver.type == "energy" { return clamp01(finiteOr(frame.energy, 0)) }
    var first = 0
    var last = frame.spectrum.count
    switch driver.type {
    case "bass": last = min(last, 8)
    case "mid": first = min(8, last); last = min(last, 20)
    case "treble": first = min(20, last)
    default: break
    }
    var peak: Double = 0
    var index = first
    while index < last {
        peak = max(peak, Double(frame.spectrum[index]))
        index += 1
    }
    return clamp01(peak)
}

/// The event key a pulse driver is currently on, or an empty string when this
/// tick is not one it fires on. `song` counts its own events because a track
/// seed is an identity, not an ordinal.
private func pulseEventKey(
    _ driver: PhonoscopeDriverSpec,
    _ frame: PhonoscopeSignalFrame,
    _ state: inout PhonoscopeDriverSlotState
) -> String {
    if driver.type == "song" {
        if !state.seenTrack {
            state.seenTrack = true
            state.lastTrackSeed = frame.trackSeed
        } else if frame.trackSeed != state.lastTrackSeed {
            state.lastTrackSeed = frame.trackSeed
            state.eventCount += 1
        }
        return phonoscopeDriverFires(index: state.eventCount, every: driver.every, offset: driver.offset)
            ? "s:\(state.eventCount)"
            : ""
    }
    if driver.type == "timer" {
        let interval = max(0.25, finiteOr(driver.intervalSeconds, 4))
        let index = Int((finiteOr(frame.time, 0) / interval).rounded(.down))
        return phonoscopeDriverFires(index: index, every: driver.every, offset: driver.offset)
            ? "t:\(index)"
            : ""
    }
    if driver.type == "downbeat" {
        return phonoscopeDriverFires(index: frame.barIndex, every: driver.every, offset: driver.offset)
            ? "d:\(frame.barIndex)"
            : ""
    }
    return phonoscopeDriverFires(index: frame.beatIndex, every: driver.every, offset: driver.offset)
        ? "b:\(frame.beatIndex)"
        : ""
}

/// A pulse driver runs a triggered attack/hold/release envelope: the event
/// starts the attack, and the shape from there is entirely the authored
/// envelope. That is what lets "every 4th downbeat" mean something a decaying
/// beat pulse could not express, and why timer and song can be drivers at all —
/// they supply an instant, not a shape.
private func advancePulseEnvelope(
    _ state: inout PhonoscopeDriverSlotState,
    binding: PhonoscopeLaneBinding,
    delta: Double,
    eventKey: String
) -> Double {
    let triggered = !eventKey.isEmpty && eventKey != state.eventKey
    if triggered {
        state.eventKey = eventKey
        state.phase = .attack
        state.holdRemaining = binding.resolvedHold
    }
    // Phases are walked within the tick, each consuming the time it needs, so a
    // zero-length attack or hold does not cost a frame.
    var remaining = delta
    var step = 0
    while step < 4 && remaining > 0 && state.phase != .idle {
        step += 1
        switch state.phase {
        case .attack:
            if binding.resolvedAttack <= 0 {
                state.level = 1
                state.phase = .hold
                continue
            }
            let needed = (1 - state.level) * binding.resolvedAttack
            if remaining >= needed {
                state.level = 1
                remaining -= needed
                state.phase = .hold
            } else {
                state.level += remaining / binding.resolvedAttack
                remaining = 0
            }
        case .hold:
            // An envelope never starts releasing on the tick it was triggered,
            // so even an all-zero envelope reads as one frame at full strength
            // rather than vanishing between samples.
            if triggered { remaining = 0; continue }
            if state.holdRemaining <= 0 {
                state.phase = .release
                continue
            }
            let used = min(remaining, state.holdRemaining)
            state.holdRemaining -= used
            remaining -= used
            if state.holdRemaining <= 0 { state.phase = .release }
        case .release:
            if binding.resolvedRelease <= 0 {
                state.level = 0
                state.phase = .idle
                continue
            }
            let needed = state.level * binding.resolvedRelease
            if remaining >= needed {
                state.level = 0
                remaining = 0
                state.phase = .idle
            } else {
                state.level -= remaining / binding.resolvedRelease
                remaining = 0
            }
        case .idle:
            break
        }
    }
    if state.phase == .idle { state.level = 0 }
    return clamp01(state.level)
}

/// A continuous driver follows its level instead of being triggered by it, so
/// the envelope acts as a rate limit. This is the behaviour the pre-lane
/// parameter sources had, preserved exactly.
private func advanceFollower(
    _ state: inout PhonoscopeDriverSlotState,
    binding: PhonoscopeLaneBinding,
    delta: Double,
    signal: Double
) -> Double {
    state.target = signal
    let rising = state.target >= state.current
    if rising {
        state.holdRemaining = binding.resolvedHold
    } else if state.holdRemaining > 0 {
        state.holdRemaining -= delta
        return state.current
    }
    let duration = rising ? binding.resolvedAttack : binding.resolvedRelease
    if duration <= 0 {
        state.current = state.target
    } else {
        let step = delta / duration
        state.current = rising
            ? min(state.target, state.current + step)
            : max(state.target, state.current - step)
    }
    return clamp01(state.current)
}

/// `random` samples on its cadence and glides over `transitionSeconds`,
/// ignoring the binding envelope — the cadence and the glide are the shape. The
/// sample is seeded from the slot key and the event so every engine picks the
/// same value.
private func advanceRandom(
    _ state: inout PhonoscopeDriverSlotState,
    driver: PhonoscopeDriverSpec,
    frame: PhonoscopeSignalFrame,
    delta: Double,
    key: String
) -> Double {
    var cadence = driver
    cadence.type = ["beat", "downbeat", "timer", "song"].contains(driver.cadence)
        ? driver.cadence
        : "beat"
    let eventKey = pulseEventKey(cadence, frame, &state)
    if !eventKey.isEmpty && eventKey != state.eventKey {
        state.eventKey = eventKey
        let seed = stablePhonoscopeSeed("\(key):\(eventKey)")
        state.target = Double(seed % 1_000_003) / 1_000_002
    }
    let duration = max(0, finiteOr(driver.transitionSeconds, 0.5))
    let amount = duration == 0 ? 1 : min(1, delta / duration)
    state.current += (state.target - state.current) * amount
    return clamp01(state.current)
}

private func driverSignal(
    _ driver: PhonoscopeDriverSpec,
    binding: PhonoscopeLaneBinding,
    frame: PhonoscopeSignalFrame,
    states: inout [String: PhonoscopeDriverSlotState],
    key: String
) -> Double {
    var state = states[key] ?? PhonoscopeDriverSlotState()
    let delta = max(1.0 / 120.0, min(0.25, finiteOr(frame.delta, 1.0 / 60.0)))
    let result: Double
    if driver.type == "random" {
        result = advanceRandom(&state, driver: driver, frame: frame, delta: delta, key: key)
    } else if driver.isPulse {
        let eventKey = pulseEventKey(driver, frame, &state)
        result = advancePulseEnvelope(&state, binding: binding, delta: delta, eventKey: eventKey)
    } else {
        result = advanceFollower(
            &state, binding: binding, delta: delta, signal: levelSignal(driver, frame))
    }
    states[key] = state
    return result
}

private struct Contribution {
    var amount: Double
    var period: Double
    var restingValue: Double
}

/// Resolve every effect the given lanes drive.
///
/// A binding maps its lane's signal across `[min, max]`, so on its own it
/// behaves exactly as a single pre-lane parameter source did. Stacking is
/// expressed as contribution *above* a shared resting value — the highest `min`
/// among the effect's bindings — so two resting bindings never double their
/// floor, and `add` genuinely means "this much more on top".
func evaluatePhonoscopeDriverLanes(
    lanes: [PhonoscopeScopedLane],
    combine: [String: PhonoscopeCombineMode],
    declarations: [String: PhonoscopeEffectDeclaration],
    frame: PhonoscopeSignalFrame,
    states: inout [String: PhonoscopeDriverSlotState]
) -> PhonoscopeLaneEvaluation {
    var contributions: [String: [Contribution]] = [:]

    for scoped in lanes {
        let lanePeriod = phonoscopeDriverPeriodSeconds(scoped.lane.driver, frame: frame)
        for binding in scoped.lane.bindings {
            guard let declaration = declarations[binding.effect] else { continue }
            let low = clampToDeclaration(declaration, binding.min ?? declaration.min)
            let high = max(low, clampToDeclaration(declaration, binding.max ?? declaration.max))
            let slot = "\(scoped.groupId):\(scoped.lane.id):\(binding.id)"
            var signal = driverSignal(
                scoped.lane.driver, binding: binding, frame: frame, states: &states,
                key: "\(slot):0")
            // Modifiers add to the main driver rather than gating it, so
            // "downbeat plus bass" reads as the hit sitting on top of whatever
            // the bass is already doing.
            for (index, modifier) in scoped.lane.modifiers.enumerated() {
                signal += driverSignal(
                    modifier, binding: binding, frame: frame, states: &states,
                    key: "\(slot):\(index + 1)")
            }
            signal = max(0, min(phonoscopeMaxLaneSignal, signal))
            contributions[binding.effect, default: []].append(
                Contribution(amount: (high - low) * signal, period: lanePeriod, restingValue: low))
        }
    }

    var result = PhonoscopeLaneEvaluation()
    for (effect, list) in contributions {
        guard let declaration = declarations[effect], !list.isEmpty else { continue }
        let resting = list.reduce(-Double.infinity) { max($0, $1.restingValue) }
        var total: Double = 0
        if combine[effect] == .strongest {
            // The rarest lane that is actually firing takes the effect
            // outright. Equal periods fall back to lane order, last one
            // winning, matching the way colliding scalars layer.
            var best: Contribution?
            for entry in list where entry.amount != 0 {
                if best == nil || entry.period >= best!.period { best = entry }
            }
            total = best?.amount ?? 0
        } else {
            total = list.reduce(0) { $0 + $1.amount }
        }
        let range = max(0, declaration.max - declaration.min)
        let ceiling = resting + range * phonoscopeOvershootRanges
        let value = resting + total
        result.values[effect] = value.isFinite
            ? max(declaration.min, min(ceiling, value))
            : declaration.defaultValue
        result.driven.insert(effect)
    }
    return result
}
