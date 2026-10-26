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
    /// The centre image's base size, as percentages of the frame. A separate
    /// axis from the scale above: this is how big the image is, that is a
    /// multiplier on top of it.
    ///
    /// Width is the AUTHORED axis and height follows it while
    /// `centreProportional` is on, which is the default and is what the slot did
    /// before it had a width at all. See `PhonoscopeImageFit`.
    static let centreWidth = "__centreWidth"
    static let centreHeight = "__centreHeight"
    static let centreFit = "__centreFit"
    static let centreProportional = "__centreProportional"
    // Frame geometry, as fractions of the render view, plus the vignette that
    // frames it. These replaced a fixed one-third letterbox and five hardcoded
    // gradient numbers, so that they are driven is the whole point.
    //
    // Agnostic about what the backdrop is: with a background image on the live
    // theme these size that image, and with none they size the procedural band
    // exactly as they always have.
    static let backgroundHeight = "__bgHeight"
    static let backgroundWidth = "__bgWidth"
    static let backgroundScale = "__bgScale"
    static let backgroundFit = "__bgFit"
    static let backgroundProportional = "__bgProportional"
    static let vignetteOpacity = "__vignetteOpacity"
    static let vignetteSize = "__vignetteSize"
    // How the scene layer meets the backdrop: 0 linear, 1 screen, 2 overlay,
    // 3 multiply.
    static let sceneBlend = "__sceneBlend"
    // How the centre image changes when the rotation moves to an entry naming a
    // different one. Declared here so a binding on one of these axes resolves
    // like any other, but resolved for real by the dashboard: the initiator owns
    // the transition, and this side has no way to know which entry a change
    // started from.
    static let centreTransition = "__centreTransition"
    static let centreTransitionAxis = "__centreTransitionAxis"
    static let centreTransitionDivisions = "__centreTransitionDivisions"
    static let centreTransitionReturn = "__centreTransitionReturn"
    // The same four for the background image, on their own axes: the two slots
    // change at the same moment but are not the same picture, so the backdrop
    // can dissolve while the centrepiece slides.
    static let backgroundTransition = "__bgTransition"
    static let backgroundTransitionAxis = "__bgTransitionAxis"
    static let backgroundTransitionDivisions = "__bgTransitionDivisions"
    static let backgroundTransitionReturn = "__bgTransitionReturn"
    // `__hueOffset` and `__themeChange` are resolved by the dashboard rather
    // than by an engine: one drives House Party lighting, the other advances
    // the rotation.
}

/// The ramp control read as a MOTION PROFILE, for one-shot linear transitions.
///
/// A pulse envelope and a transition are two different things wearing the same
/// three-thumb control, and this is the second reading:
///
/// - attack is the EASE-IN, the stretch spent accelerating,
/// - hold is the FLAT middle, constant velocity,
/// - release is the EASE-OUT, the stretch spent decelerating,
///
/// so the transition lasts exactly attack + hold + release. Returns progress
/// from 0 to 1.
///
/// Concretely a trapezoidal velocity profile integrated once. Peak velocity is
/// whatever makes the area under it exactly 1, so the transition always
/// completes on time however the phases are proportioned: lengthening the
/// ease-in does not overshoot the end, it makes the middle faster.
///
/// Zero-length phases are skipped rather than divided by, so a bare release is
/// a pure ease-out and an all-zero ramp is an instant cut. Port of
/// `nova::transitionRamp`; the dashboard's `phonoscopeTransitionRamp` is the
/// reference.
func phonoscopeTransitionRamp(
    elapsed elapsedSeconds: Double,
    attack attackSeconds: Double,
    hold holdSeconds: Double,
    release releaseSeconds: Double
) -> Double {
    let attack = max(0, attackSeconds.isFinite ? attackSeconds : 0)
    let hold = max(0, holdSeconds.isFinite ? holdSeconds : 0)
    let release = max(0, releaseSeconds.isFinite ? releaseSeconds : 0)
    let total = attack + hold + release
    let elapsed = max(0, elapsedSeconds.isFinite ? elapsedSeconds : 0)
    if !(total > 0) || elapsed >= total { return 1 }
    // Half of each ramp's span carries half its velocity: the area of a triangle.
    let peak = 1 / (attack / 2 + hold + release / 2)
    if elapsed < attack { return min(max(peak * elapsed * elapsed / (2 * attack), 0), 1) }
    if elapsed < attack + hold {
        return min(max(peak * (attack / 2 + (elapsed - attack)), 0), 1)
    }
    let decelerating = elapsed - attack - hold
    return min(max(peak * (attack / 2 + hold + decelerating
                           - decelerating * decelerating / (2 * release)), 0), 1)
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
    /// Subdivisions per pulse, 1/2/4/8 — the other direction from `every`. Only
    /// `beat` and `downbeat` (and a `random` whose cadence is one of them)
    /// subdivide; a subdivided driver always has `every == 1`, `offset == 0`.
    var divide: Int = 1
    var intervalSeconds: Double = 4
    /// `random` only: the pulse whose interval is the window it fires somewhere
    /// inside. `every` and `divide` size that window rather than selecting
    /// which pulses count.
    var cadence: String = "beat"

    /// One of the four literal pulse types — not `random`, which borrows one.
    var isPulse: Bool {
        type == "beat" || type == "downbeat" || type == "timer" || type == "song"
    }

    /// Whether this driver fires discrete events at all. `random` does: it is a
    /// pulse whose timing is jittered.
    var firesEvents: Bool { isPulse || type == "random" }

    /// How many times per pulse this driver fires. Anything other than a
    /// supported subdivision reads as the whole pulse, so a configuration this
    /// build does not understand degrades to the behaviour it had before
    /// subdivisions existed rather than to silence.
    var resolvedDivide: Int {
        divide == 2 || divide == 4 || divide == 8 ? divide : 1
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
    /// Draw the target at random from inside `[min, max]` on each lane event
    /// instead of always driving to `max`. The envelope is untouched: it still
    /// shapes the approach from the bottom of the range up to whatever was
    /// drawn. Orthogonal to the `random` driver, so the two stack.
    var randomValue: Bool = false
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

/// How an effect resolves when more than one lane drives it at once.
///
/// - `add` sums every contribution above the shared resting floor.
/// - `strongest` gives it to the LEAST frequent firing lane outright.
/// - `common` gives it to the MOST frequent firing lane outright.
/// - `override` REPLACES the value with the last contributing lane's, resting
///   value included — the one mode that is not a contribution.
///
/// The first two raw values are unchanged because saved configurations already
/// hold them; the dashboard labels the four Sum, Least frequent lane wins, Most
/// frequent lane wins and Override.
enum PhonoscopeCombineMode: String, Equatable, Sendable {
    case add
    case strongest
    case common
    case override
}

/// Effects that always combine by `override`, whatever a settings group stored.
///
/// A transition is one indivisible instruction: half a flip summed with half a
/// slide is not a transition, it is a fault. Mirrors
/// `PHONOSCOPE_OVERRIDE_ONLY_EFFECTS` in the dashboard and
/// `nova::isOverrideOnlyEffect` in the renderer.
func phonoscopeIsOverrideOnlyEffect(_ effect: String) -> Bool {
    effect == PhonoscopeEffectID.centreTransition
        || effect == PhonoscopeEffectID.centreTransitionAxis
        || effect == PhonoscopeEffectID.centreTransitionDivisions
        || effect == PhonoscopeEffectID.centreTransitionReturn
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
    /// `random` timing: the window `target` holds a threshold for, and whether
    /// that window's one fire has already happened.
    var windowKey: String = ""
    var fired: Bool = false
    /// `randomValue` slots only: whether a value has ever been drawn. Without it
    /// a lane whose driver never writes an event key — every continuous driver —
    /// would sit on the zero `target` forever and hold the effect at its floor.
    var seeded: Bool = false
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
/// The event index a subdivided pulse is on: the whole-pulse index plus how far
/// through it the frame is, scaled by the subdivision. At `divide == 1` this is
/// exactly the whole-pulse index, so an undivided driver is untouched.
func phonoscopeSubdividedIndex(_ index: Int, phase: Double, divide: Int) -> Int {
    if divide <= 1 { return index }
    let position = Double(index) + max(0, min(1, finiteOr(phase, 0)))
    return Int((position * Double(divide)).rounded(.down))
}

func phonoscopeDriverFires(index: Int, every: Int, offset: Int) -> Bool {
    let cycle = max(1, every)
    if cycle == 1 { return true }
    let phase = max(0, min(cycle - 1, offset))
    return (((index - phase) % cycle) + cycle) % cycle == 0
}

/// The pulse a `random` driver's window is measured in. An unrecognised cadence
/// reads as `beat`, so a configuration from a newer dashboard degrades to the
/// commonest window rather than to silence.
func phonoscopeRandomCadence(_ driver: PhonoscopeDriverSpec) -> PhonoscopeDriverSpec {
    var cadence = driver
    cadence.type = ["beat", "downbeat", "timer", "song"].contains(driver.cadence)
        ? driver.cadence
        : "beat"
    return cadence
}

/// How rarely a lane fires, in seconds, used to rank lanes when an effect
/// combines by `strongest` or `common`. Longer wins under `strongest`.
/// Continuous drivers return 0 and never win outright either way; `random`
/// returns its cadence's period, because it fires exactly once per window.
func phonoscopeDriverPeriodSeconds(
    _ driver: PhonoscopeDriverSpec,
    frame: PhonoscopeSignalFrame
) -> Double {
    // A random driver fires exactly once per window, so its rarity IS its
    // window — the same period the cadence pulse would have had.
    if driver.type == "random" {
        return phonoscopeDriverPeriodSeconds(phonoscopeRandomCadence(driver), frame: frame)
    }
    let every = Double(max(1, driver.every))
    let secondsPerBeat = max(1e-6, 60.0 / max(1, frame.bpm.isFinite ? frame.bpm : 72))
    let beatsPerBar = Double(max(1, frame.timeSignature))
    // A song is the rarest thing that can happen, and its length is unknown
    // ahead of time, so it always outranks a counted pulse.
    switch driver.type {
    case "song": return .infinity
    case "timer": return every * max(0.25, driver.intervalSeconds.isFinite ? driver.intervalSeconds : 4)
    // Subdividing makes a lane commoner, which is exactly what `strongest`
    // ranks by, so a quarter-beat lane loses to a plain beat the same way a
    // beat loses to a downbeat.
    case "downbeat": return every * beatsPerBar * secondsPerBeat / Double(driver.resolvedDivide)
    case "beat": return every * secondsPerBeat / Double(driver.resolvedDivide)
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
    // A subdivided driver carries its subdivision in the key so that changing
    // the subdivision live always reads as a new event, and so the keys an
    // undivided driver produces are byte-for-byte the ones the conformance
    // corpus recorded.
    let divide = driver.resolvedDivide
    let suffix = divide > 1 ? "/\(divide)" : ""
    if driver.type == "downbeat" {
        let index = phonoscopeSubdividedIndex(frame.barIndex, phase: frame.barPhase, divide: divide)
        return phonoscopeDriverFires(index: index, every: driver.every, offset: driver.offset)
            ? "d\(suffix):\(index)"
            : ""
    }
    let index = phonoscopeSubdividedIndex(frame.beatIndex, phase: frame.beatPhase, divide: divide)
    return phonoscopeDriverFires(index: index, every: driver.every, offset: driver.offset)
        ? "b\(suffix):\(index)"
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

/// Where the frame sits inside the driver's firing window, as a whole window
/// index and a 0..1 fraction through it.
///
/// The window is the whole span between one firing opportunity and the next —
/// `every` windows of the pulse, or one `divide`th of it — which is exactly the
/// span `phonoscopeDriverPeriodSeconds` measures. That is what makes "every 4th
/// downbeat" mean one fire somewhere in four bars rather than a fire inside the
/// fourth.
///
/// `song` has no position: a track's length is not known until it ends, so
/// there is no "fraction through" it to place anything at. Returns nil there,
/// and the caller falls back to firing on the track change itself.
private func driverWindowPosition(
    _ driver: PhonoscopeDriverSpec,
    _ frame: PhonoscopeSignalFrame
) -> (index: Int, fraction: Double)? {
    if driver.type == "song" { return nil }
    var position: Double
    if driver.type == "timer" {
        position = finiteOr(frame.time, 0) / max(0.25, finiteOr(driver.intervalSeconds, 4))
    } else {
        let whole = driver.type == "downbeat" ? frame.barIndex : frame.beatIndex
        let phase = driver.type == "downbeat" ? frame.barPhase : frame.beatPhase
        // Same continuous position `phonoscopeSubdividedIndex` floors, kept
        // unfloored: the fractional part is the whole point here.
        position = (Double(whole) + max(0, min(1, finiteOr(phase, 0))))
            * Double(driver.resolvedDivide)
    }
    // `every` and `divide` are the two directions of one control and never both
    // apply, so this scales by whichever is in play.
    let every = max(1, driver.every)
    let offset = max(0, min(every - 1, driver.offset))
    let cycles = (position - Double(offset)) / Double(every)
    let index = cycles.rounded(.down)
    return (Int(index), cycles - index)
}

/// `random` is a pulse whose timing is jittered: it fires exactly once per
/// cadence window, at a point drawn at random from inside that window, and draws
/// a new point when the window rolls over. So a `downbeat` random driver fires
/// somewhere before the next downbeat, and the downbeat resets where it will
/// fire next time.
///
/// It runs the binding's envelope like every other pulse — the randomness is in
/// *when*, not in the shape. Randomising the value it drives to is a separate,
/// stackable thing: the binding's `randomValue`.
///
/// The threshold is seeded from the slot key and the window, so every engine
/// jitters identically for the same window of the same track.
private func advanceJitteredPulse(
    _ state: inout PhonoscopeDriverSlotState,
    driver: PhonoscopeDriverSpec,
    binding: PhonoscopeLaneBinding,
    frame: PhonoscopeSignalFrame,
    delta: Double,
    key: String
) -> Double {
    let cadence = phonoscopeRandomCadence(driver)
    // A song has no interior to place a fire inside, so a song-cadence random
    // driver is simply the song pulse. Better than pretending to jitter.
    guard let position = driverWindowPosition(cadence, frame) else {
        let eventKey = pulseEventKey(cadence, frame, &state)
        return advancePulseEnvelope(&state, binding: binding, delta: delta, eventKey: eventKey)
    }

    let divide = cadence.resolvedDivide
    let prefix = cadence.type == "downbeat" ? "d" : cadence.type == "timer" ? "t" : "b"
    let suffix = divide > 1 ? "/\(divide)" : ""
    let windowKey = "r\(prefix)\(suffix):\(position.index)"
    if windowKey != state.windowKey {
        state.windowKey = windowKey
        let seed = stablePhonoscopeSeed("\(key):\(windowKey)")
        state.target = Double(seed % 1_000_003) / 1_000_002
        state.fired = false
    }

    var eventKey = ""
    if !state.fired && position.fraction >= state.target {
        state.fired = true
        // The `!` keeps a fire distinct from the window it belongs to, so the
        // envelope's "is this a new event" test can never confuse the two.
        eventKey = "\(windowKey)!"
    }
    return advancePulseEnvelope(&state, binding: binding, delta: delta, eventKey: eventKey)
}

/// How far up its range a binding reaches this tick, 0..1.
///
/// Normally 1 — the lane sweeps the whole authored range. With `randomValue` the
/// top of the sweep is drawn at random on each lane event and held until the
/// next one, so the envelope still ramps from the bottom of the range but stops
/// somewhere new every time.
///
/// The draw is keyed off the primary driver's event key, which changes exactly
/// when the lane fires. Each binding draws from its own slot key, so two
/// randomised effects in one lane move independently rather than in lockstep.
///
/// A continuous driver never writes an event key, so a level-driven lane draws
/// once and holds it — there is no event to re-draw on. The dashboard says so.
private func randomValueScale(
    _ binding: PhonoscopeLaneBinding,
    states: inout [String: PhonoscopeDriverSlotState],
    slot: String
) -> Double {
    guard binding.randomValue else { return 1 }
    var roll = states["\(slot):rnd"] ?? PhonoscopeDriverSlotState()
    let eventKey = states["\(slot):0"]?.eventKey ?? ""
    if !roll.seeded || eventKey != roll.eventKey {
        roll.seeded = true
        roll.eventKey = eventKey
        let seed = stablePhonoscopeSeed("\(slot):rnd:\(eventKey)")
        roll.target = Double(seed % 1_000_003) / 1_000_002
    }
    states["\(slot):rnd"] = roll
    return roll.target
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
        result = advanceJitteredPulse(
            &state, driver: driver, binding: binding, frame: frame, delta: delta, key: key)
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
            let reach = randomValueScale(binding, states: &states, slot: slot)
            contributions[binding.effect, default: []].append(
                Contribution(
                    amount: (high - low) * signal * reach, period: lanePeriod, restingValue: low))
        }
    }

    var result = PhonoscopeLaneEvaluation()
    for (effect, list) in contributions {
        guard let declaration = declarations[effect], !list.isEmpty else { continue }
        var resting = list.reduce(-Double.infinity) { max($0, $1.restingValue) }
        var total: Double = 0
        let mode = phonoscopeIsOverrideOnlyEffect(effect) ? .override : (combine[effect] ?? .add)
        switch mode {
        case .override:
            // A replacement, not a contribution: the last lane in merge order
            // takes the effect outright and brings its OWN resting value with
            // it, rather than sitting on the shared floor every other mode
            // builds from. That is what makes an override settings group beat
            // the defaults instead of adding to them.
            resting = list[list.count - 1].restingValue
            total = list[list.count - 1].amount
        case .strongest, .common:
            // One firing lane takes the effect outright, chosen by how often it
            // fires: `strongest` wants the least frequent, `common` the most.
            // Equal periods fall back to lane order, last one winning, matching
            // the way colliding scalars layer.
            //
            // A continuous driver has no period at all (0), so under
            // `strongest` it never wins outright. `common` has to exclude it
            // explicitly for the same reason inverted — otherwise a level lane,
            // being the "most frequent" thing there is, would win every time
            // and no pulse could be heard.
            let rarest = mode == .strongest
            var best: Contribution?
            for entry in list where entry.amount != 0 {
                if !rarest && !(entry.period > 0) { continue }
                if best == nil || (rarest ? entry.period >= best!.period : entry.period <= best!.period) {
                    best = entry
                }
            }
            // Nothing but continuous lanes are contributing, so `common` falls
            // back to summing them rather than going silent.
            if best == nil && !rarest {
                total = list.reduce(0) { $0 + $1.amount }
            } else {
                total = best?.amount ?? 0
            }
        case .add:
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
