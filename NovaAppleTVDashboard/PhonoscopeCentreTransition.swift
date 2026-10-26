import Foundation

// How the centre image CHANGES: the three modes and the geometry each takes.
//
// Port of `nova-visualiser/src/core/centre_image_transition.h`. The renderer's
// `centre_image.frag` and this app's `centre_image_fragment` in
// PhonoscopeShader.metal both implement the same arithmetic; the
// `centre-image` conformance case and `ParitySelfTests.testCentreImageParity()`
// are what prove the two agree.
//
// Kept out of PhonoscopeStore, like PhonoscopeDrivers.swift, so the standalone
// parity script can compile just this and a harness with no UIKit in the way.

/// The three transition modes. APPEND-ONLY: a stored binding keeps a numeric
/// range on the `__centreTransition` axis, so renumbering silently repoints
/// configurations authored against the old numbers.
enum PhonoscopeCentreTransition: Int, Equatable, Sendable {
    case crossFade = 0
    case flip = 1
    case slide = 2
}

func phonoscopeCentreTransition(for value: Double) -> PhonoscopeCentreTransition {
    if value >= 1.5 { return .slide }
    if value >= 0.5 { return .flip }
    return .crossFade
}

/// The most a sliding image can be cut into. Ten cuts is eleven sections, by
/// which point the picture reads as a shutter rather than as an object leaving.
let phonoscopeCentreTransitionMaxDivisions = 10

/// Everything a transition was told at the moment it started.
///
/// LATCHED, not sampled. The event that initiates a change owns the whole of
/// it: these come from the settings groups that were in effect when the pulse
/// fired, which is the entry being LEFT, and they are held for the run. Reading
/// them live would mean the outgoing half of a change played under one rule and
/// the incoming half under another, because advancing the rotation also swaps
/// which settings groups apply.
struct PhonoscopeCentreTransitionParams: Equatable, Sendable {
    var mode: PhonoscopeCentreTransition = .crossFade
    /// Radians, converted from the authored whole degrees exactly once.
    var axisRadians: Double = 0
    /// Cuts, not sections: 0 is a solid image, 1 splits it in half.
    var divisions: Int = 0
    /// A slid section returns from the edge it left by rather than the far one.
    var returnFromOrigin: Bool = false

    /// Sections a slid image is drawn in. Always at least one.
    var segments: Int {
        max(1, min(phonoscopeCentreTransitionMaxDivisions, divisions) + 1)
    }
}

/// How far a segment must travel to be completely off frame.
///
/// The frame's half-extent projected onto the travel direction, plus the
/// image's own, both in the aspect-corrected space the transform works in. The
/// smallest offset that always clears, at any angle — a fixed distance would
/// either leave a corner showing on the diagonal or waste most of the leg
/// covering ground the image had already left.
func phonoscopeCentreSlideClearDistance(
    axisRadians: Double,
    frameAspect: Double,
    halfWidth: Double,
    halfHeight: Double
) -> Double {
    let along = abs(cos(axisRadians))
    let across = abs(sin(axisRadians))
    let frameSpan = 0.5 * (along * max(0, frameAspect) + across)
    let imageSpan = along * abs(halfWidth) * max(0, frameAspect) + across * abs(halfHeight)
    return frameSpan + imageSpan
}

/// Which segment a point falls in, indexed along the axis's perpendicular.
///
/// The perpendicular coordinate is the one displacement never changes, which is
/// what makes this a direct lookup rather than a search: a fragment can be asked
/// which segment it belongs to before knowing where that segment has moved to.
func phonoscopeCentreSlideSegment(across: Double, halfAcross: Double, divisions: Int) -> Int {
    let segments = max(1, min(phonoscopeCentreTransitionMaxDivisions, divisions) + 1)
    guard halfAcross > 0 else { return 0 }
    let position = (across / halfAcross) * 0.5 + 0.5
    let index = Int(floor(position * Double(segments)))
    return max(0, min(segments - 1, index))
}

/// Which way a segment travels. Alternating by parity, so 0 divisions is a
/// solid image, 1 pushes the two halves apart, and 2 sends the outer sections
/// one way and the middle the other.
func phonoscopeCentreSlideDirection(segment: Int) -> Double {
    segment % 2 == 0 ? 1 : -1
}

/// How far along the axis a segment has been displaced, in aspect-corrected
/// units, for the plane named by `incoming`.
///
/// Two legs of one movement, each linear in `progress`: the outgoing image
/// leaves over the first half and the incoming one arrives over the second. All
/// the acceleration comes from the ramp, which is what makes an ease-in read as
/// the image accelerating away and an ease-out as it settling into place.
func phonoscopeCentreSlideOffset(
    progress: Double,
    incoming: Bool,
    direction: Double,
    clearDistance: Double,
    returnFromOrigin: Bool
) -> Double {
    let clamped = min(max(progress, 0), 1)
    if !incoming { return direction * clearDistance * (clamped * 2) }
    let arriving = clamped * 2 - 1
    // Returning from the OPPOSITE edge carries on in the direction it left, so
    // it enters from the far side and the movement reads as one continuous
    // sweep. Returning from the ORIGIN edge reverses and comes back the way it
    // went.
    let travel = returnFromOrigin ? -direction : direction
    return travel * clearDistance * (arriving - 1)
}

/// Below this the flipping plane is edge-on: there is no image left to sample,
/// and dividing by it would smear one column of texels across the frame.
let phonoscopeCentreFlipEpsilon: Double = 1e-4

/// The flip's collapse factor along the axis: 1 at each end, 0 at the midpoint.
func phonoscopeCentreFlipScale(progress: Double) -> Double {
    abs(cos(Double.pi * min(max(progress, 0), 1)))
}

/// Which plane a flip draws this frame. Exactly one, and the swap is the exact
/// midpoint — that instant is what makes the flip read as one object turning
/// over rather than as two images blending through each other.
func phonoscopeCentreFlipShowsIncoming(progress: Double) -> Bool {
    progress >= 0.5
}
