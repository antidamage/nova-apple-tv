#if DEBUG
import Foundation

/// Lightweight native contract tests that run once at Debug app startup. The
/// project deliberately has one application target; keeping these beside the
/// thin client validates the exact tvOS decoders/formatters used on device
/// without introducing a second signed target.
enum ParitySelfTests {
    static func run() {
        testClockFormatting()
        testThemeDecoding()
        testOrbContract()
        testOrbInfoFormatConformance()
        testSpeechEnvelope()
        testPhonoscopeQualityPolicy()
        testFluidBackgroundPolicy()
        testPhonoscopeSettingInterpolation()
        testCompositeParity()
        testEffectScaleParity()
        testGlowOverlayParity()
        testParameterDriverParity()
        testBackgroundBandParity()
        testSceneBlendParity()
        testCentreImageParity()
        testRootBackExitGate()
        testExitCommandShield()
    }

    /// Mirrors `runParameterDriversCase()` in the conformance runner, scenario
    /// for scenario. The driver-lane evaluator decides how every driven
    /// parameter moves, so a drift here is a drift in every module at once.
    private static func testParameterDriverParity() {
        var hash: UInt64 = 1_469_598_103_934_665_603
        var samples = 0
        func mix(_ value: Double) {
            let quantised = Int64((value * 10_000).rounded())
            for byte in 0 ..< 8 {
                hash = (hash ^ UInt64(UInt8(truncatingIfNeeded: quantised >> (byte * 8))))
                    &* 1_099_511_628_211
            }
            samples += 1
        }

        let glow = PhonoscopeEffectDeclaration(
            id: "glow", min: 0, max: 10, step: 0.1, defaultValue: 0)
        let declarations = ["glow": glow]

        func driver(
            _ type: String, every: Int = 1, offset: Int = 0, interval: Double = 4,
            cadence: String = "beat", divide: Int = 1
        ) -> PhonoscopeDriverSpec {
            PhonoscopeDriverSpec(
                type: type, every: every, offset: offset, divide: divide,
                intervalSeconds: interval, cadence: cadence)
        }
        func binding(
            _ id: String, _ minimum: Double, _ maximum: Double, _ attack: Double,
            _ hold: Double, _ release: Double
        ) -> PhonoscopeLaneBinding {
            PhonoscopeLaneBinding(
                id: id, effect: "glow", min: minimum, max: maximum, attackSeconds: attack,
                holdSeconds: hold, releaseSeconds: release)
        }
        func laneOf(
            _ id: String, _ primary: PhonoscopeDriverSpec, _ bindings: [PhonoscopeLaneBinding],
            _ modifiers: [PhonoscopeDriverSpec] = []
        ) -> PhonoscopeLane {
            PhonoscopeLane(id: id, driver: primary, modifiers: modifiers, bindings: bindings)
        }
        func frameAt(
            _ time: Double, _ delta: Double, _ beatIndex: Int, _ barIndex: Int,
            _ trackSeed: UInt64
        ) -> PhonoscopeSignalFrame {
            var frame = PhonoscopeSignalFrame.idle
            frame.time = time
            frame.delta = delta
            frame.beatIndex = beatIndex
            frame.barIndex = barIndex
            frame.bpm = 120
            frame.timeSignature = 4
            frame.energy = 0
            frame.trackSeed = trackSeed
            frame.spectrum = [Float](repeating: 0, count: 32)
            return frame
        }
        func sweep(
            _ lanes: [PhonoscopeScopedLane],
            _ combine: [String: PhonoscopeCombineMode],
            _ ticks: Int,
            _ advance: (Int) -> PhonoscopeSignalFrame
        ) {
            var states: [String: PhonoscopeDriverSlotState] = [:]
            for tick in 0 ..< ticks {
                let evaluation = evaluatePhonoscopeDriverLanes(
                    lanes: lanes, combine: combine, declarations: declarations,
                    frame: advance(tick), states: &states)
                mix(evaluation.values["glow"] ?? -1)
            }
        }

        // 1. The triggered attack/hold/release envelope.
        sweep(
            [PhonoscopeScopedLane(
                groupId: "g", lane: laneOf("l", driver("beat"), [binding("b1", 0, 10, 0.1, 0.1, 0.2)]))],
            [:], 12, { frameAt(Double($0) * 0.05, 0.05, 0, 0, 1) })

        // 2. Retrigger part way through a release.
        sweep(
            [PhonoscopeScopedLane(
                groupId: "g", lane: laneOf("l", driver("beat"), [binding("b1", 0, 10, 0.1, 0, 1.0)]))],
            [:], 8, { frameAt(Double($0) * 0.05, 0.05, $0 >= 3 ? 1 : 0, 0, 1) })

        // 3. `every` and `offset` gating on both beat and downbeat.
        for (type, every, offset) in [
            ("beat", 2, 0), ("beat", 3, 1), ("downbeat", 4, 0), ("downbeat", 4, 2),
            ("downbeat", 16, 0),
        ] {
            sweep(
                [PhonoscopeScopedLane(
                    groupId: "g",
                    lane: laneOf(
                        "l", driver(type, every: every, offset: offset),
                        [binding("b1", 0, 10, 0, 0, 0)]))],
                [:], 17, { frameAt(Double($0), 0.05, $0, $0, 1) })
        }

        // 4. Modifier summation, including the deliberate overshoot.
        sweep(
            [PhonoscopeScopedLane(
                groupId: "g",
                lane: laneOf(
                    "l", driver("downbeat"), [binding("b1", 0, 10, 0, 1, 0)],
                    [driver("bass"), driver("treble")]))],
            [:], 4,
            { tick in
                var frame = frameAt(Double(tick) * 0.05, 0.05, 0, 0, 1)
                frame.spectrum[0] = 0.5
                frame.spectrum[25] = 0.25
                return frame
            })

        // 5. Add versus strongest across a frequent, a rare and a song lane.
        let stacked = [
            PhonoscopeScopedLane(
                groupId: "g", lane: laneOf("beat", driver("beat"), [binding("b-beat", 0, 4, 0, 1, 0)])),
            PhonoscopeScopedLane(
                groupId: "g",
                lane: laneOf("down", driver("downbeat", every: 4), [binding("b-down", 0, 10, 0, 1, 0)])),
            PhonoscopeScopedLane(
                groupId: "g", lane: laneOf("song", driver("song"), [binding("b-song", 0, 6, 0, 1, 0)])),
        ]
        for mode in [PhonoscopeCombineMode.add, .strongest] {
            sweep(stacked, ["glow": mode], 10, { frameAt(Double($0), 0.05, $0, $0, $0 < 5 ? 1 : 2) })
        }

        // 6. The overshoot guard.
        var many: [PhonoscopeScopedLane] = []
        for index in 0 ..< 8 {
            many.append(PhonoscopeScopedLane(
                groupId: "g",
                lane: laneOf("l\(index)", driver("beat"), [binding("b\(index)", 0, 10, 0, 1, 0)])))
        }
        sweep(many, ["glow": .add], 3, { frameAt(Double($0) * 0.05, 0.05, 0, 0, 1) })

        // 7. Timer and song pulses, including `every` on counted song events.
        sweep(
            [PhonoscopeScopedLane(
                groupId: "g",
                lane: laneOf("l", driver("timer", interval: 1.0), [binding("b1", 0, 10, 0, 0, 0)]))],
            [:], 8, { frameAt(Double($0) * 0.5, 0.5, 0, 0, 1) })
        sweep(
            [PhonoscopeScopedLane(
                groupId: "g", lane: laneOf("l", driver("song"), [binding("b1", 0, 10, 0, 0, 0)]))],
            [:], 6, { frameAt(Double($0) * 0.5, 0.5, 0, 0, UInt64(11 + ($0 / 2) * 11)) })
        sweep(
            [PhonoscopeScopedLane(
                groupId: "g",
                lane: laneOf("l", driver("song", every: 2), [binding("b1", 0, 10, 0, 0, 0)]))],
            [:], 6, { frameAt(Double($0) * 0.5, 0.5, 0, 0, UInt64(11 + $0 * 11)) })

        // 8. Continuous followers, each reading its own bands.
        for type in ["bass", "mid", "treble", "energy"] {
            sweep(
                [PhonoscopeScopedLane(
                    groupId: "g",
                    lane: laneOf("l", driver(type), [binding("b1", 0, 10, 0.1, 0.05, 0.1)]))],
                [:], 8,
                { tick in
                    var frame = frameAt(Double(tick) * 0.05, 0.05, 0, 0, 1)
                    let level: Float = tick < 4 ? 1 : 0
                    frame.spectrum[0] = level
                    frame.spectrum[12] = level
                    frame.spectrum[25] = level
                    frame.energy = Double(level)
                    return frame
                })
        }

        // 9. Jittered random timing: one fire per window at a seeded point
        //    inside it, running the binding envelope.
        //
        //    Sixteen ticks across four beats, so each window is sampled either
        //    side of wherever its own threshold falls.
        func jitteredFrame(_ tick: Int) -> PhonoscopeSignalFrame {
            var frame = frameAt(Double(tick) * 0.125, 0.125, tick / 4, tick / 4, 1)
            let phase = Double(tick % 4) / 4
            frame.beatPhase = phase
            frame.barPhase = phase
            return frame
        }
        func jittered(_ cadence: String, _ every: Int, _ divide: Int) {
            sweep(
                [PhonoscopeScopedLane(
                    groupId: "g",
                    lane: laneOf(
                        "l", driver("random", every: every, cadence: cadence, divide: divide),
                        [binding("b1", 0, 10, 0, 0, 0)]))],
                [:], 16, jitteredFrame)
        }
        jittered("beat", 1, 1)
        jittered("downbeat", 1, 1)
        // `every` widens the window rather than skipping windows: one fire per
        // four bars, at a moving point, not a jittered hit inside the fourth bar.
        jittered("downbeat", 4, 1)
        jittered("beat", 1, 4)
        jittered("timer", 1, 1)
        // A song has no interior, so this one still fires on the track change.
        sweep(
            [PhonoscopeScopedLane(
                groupId: "g",
                lane: laneOf(
                    "l", driver("random", cadence: "song"), [binding("b1", 0, 10, 0, 0, 0)]))],
            [:], 6, { frameAt(Double($0) * 0.5, 0.5, $0, $0, UInt64(1 + $0 / 2)) })
        // The envelope is the shape now, so a long release must decay across the
        // ticks after the fire rather than being ignored as the old glide was.
        sweep(
            [PhonoscopeScopedLane(
                groupId: "g",
                lane: laneOf(
                    "l", driver("random", cadence: "beat"), [binding("b1", 0, 10, 0, 0, 1.0)]))],
            [:], 12, jitteredFrame)

        // 9b. Randomised targets: a new draw on each lane event, held between
        //     them, and stackable with jittered timing.
        func randomised(_ value: PhonoscopeDriverSpec, _ ticks: Int) {
            var bound = binding("b1", 0, 10, 0, 0, 0)
            bound.randomValue = true
            sweep(
                [PhonoscopeScopedLane(groupId: "g", lane: laneOf("l", value, [bound]))],
                [:], ticks, jitteredFrame)
        }
        randomised(driver("beat"), 16)
        randomised(driver("downbeat", every: 2), 16)
        // Both halves at once: a random peak at a random moment.
        randomised(driver("random", cadence: "beat"), 16)
        // A level driver fires nothing, so the draw happens once and holds.
        randomised(driver("bass"), 8)

        // 10. Several settings groups on one entry: lanes stack, scalars layer.
        var base = PhonoscopeSettingsGroupSpec(id: "base")
        base.lanes = [laneOf("a", driver("beat"), [binding("b-a", 0, 4, 0, 1, 0)])]
        base.combine["glow"] = .add
        base.staticSettings["complexity"] = 0.4
        var hard = PhonoscopeSettingsGroupSpec(id: "hard")
        hard.lanes = [laneOf("b", driver("downbeat", every: 4), [binding("b-b", 0, 10, 0, 1, 0)])]
        hard.combine["glow"] = .strongest
        hard.staticSettings["complexity"] = 0.9

        let merged = mergePhonoscopeSettingsGroups([base, hard])
        mix(Double(merged.lanes.count))
        mix(merged.combine["glow"] == .strongest ? 1 : 0)
        mix(merged.staticSettings["complexity"] ?? 0)
        sweep(merged.lanes, merged.combine, 8, { frameAt(Double($0), 0.05, $0, $0, 1) })

        let reversed = mergePhonoscopeSettingsGroups([hard, base])
        mix(reversed.combine["glow"] == .strongest ? 1 : 0)
        mix(reversed.staticSettings["complexity"] ?? 0)

        // 11. Rarity ordering, which is what `strongest` resolves ties by.
        let rarityFrame = frameAt(0, 0.05, 0, 0, 1)
        for value in [
            driver("beat"), driver("beat", every: 2), driver("downbeat"),
            driver("downbeat", every: 4), driver("timer", interval: 30), driver("bass"),
            // Random fires exactly once per window, so it ranks as its cadence
            // does — where the old sample-and-hold random ranked at 0 and was
            // excluded from `strongest` and `common` alike.
            driver("random"), driver("random", cadence: "downbeat"),
            driver("random", every: 4, cadence: "downbeat"),
        ] {
            let period = phonoscopeDriverPeriodSeconds(value, frame: rarityFrame)
            mix(period.isInfinite ? -2 : period)
        }
        mix(phonoscopeDriverPeriodSeconds(
            driver("random", cadence: "song"), frame: rarityFrame).isInfinite ? 1 : 0)
        mix(phonoscopeDriverPeriodSeconds(driver("song"), frame: rarityFrame).isInfinite ? 1 : 0)

        // 12. Subdivided pulses: the beat cut into quarters and the bar into
        //     halves, sampled eight times across each whole pulse so both the
        //     firing ticks and the silent ones between them are covered.
        func subdivided(_ type: String, _ divide: Int) {
            sweep(
                [PhonoscopeScopedLane(
                    groupId: "g",
                    lane: laneOf(
                        "l", driver(type, divide: divide), [binding("b1", 0, 10, 0, 0, 0)]))],
                [:], 16,
                { tick in
                    var frame = frameAt(Double(tick) * 0.05, 0.05, tick / 8, tick / 8, 1)
                    let phase = Double(tick % 8) / 8
                    frame.beatPhase = phase
                    frame.barPhase = phase
                    return frame
                })
        }
        subdivided("beat", 4)
        subdivided("beat", 8)
        subdivided("downbeat", 2)
        // An unsupported subdivision reads as the whole pulse, which is what
        // keeps an older engine and a newer configuration agreeing.
        subdivided("beat", 3)

        // Subdividing makes a lane commoner, and that is what `strongest` ranks by.
        for value in [
            driver("beat", divide: 8), driver("beat", divide: 2), driver("beat"),
            driver("downbeat", divide: 4), driver("downbeat"),
        ] {
            mix(phonoscopeDriverPeriodSeconds(value, frame: rarityFrame))
        }

        // 13. The four combine modes over one pair of lanes: a busy beat and a
        //     rare every-fourth-downbeat, with deliberately different resting
        //     values so `override` can be told apart from the rest — it is the
        //     only mode that replaces the shared floor rather than building on
        //     it.
        let layered = [
            PhonoscopeScopedLane(
                groupId: "defaults",
                lane: laneOf("a", driver("beat"), [binding("b-a", 3, 5, 0, 1, 0)])),
            PhonoscopeScopedLane(
                groupId: "override",
                lane: laneOf("b", driver("downbeat", every: 4), [binding("b-b", 1, 2, 0, 1, 0)])),
        ]
        for mode: PhonoscopeCombineMode in [.add, .strongest, .common, .override] {
            sweep(layered, ["glow": mode], 8, { tick in
                frameAt(Double(tick), 0.05, tick, tick, 1)
            })
        }

        // A level lane against a pulse. `common` must not let the continuous one
        // win — it has no period, so "most frequent" would silence every pulse.
        let levelled = [
            PhonoscopeScopedLane(
                groupId: "g",
                lane: laneOf("level", driver("energy"), [binding("b-level", 0, 2, 0, 0, 0)])),
            PhonoscopeScopedLane(
                groupId: "g",
                lane: laneOf("pulse", driver("downbeat", every: 4), [binding("b-pulse", 0, 10, 0, 1, 0)])),
        ]
        for mode: PhonoscopeCombineMode in [.strongest, .common] {
            sweep(levelled, ["glow": mode], 8, { tick in
                var frame = frameAt(Double(tick), 0.05, tick, tick, 1)
                frame.energy = 1
                return frame
            })
        }

        // The transition axes ignore what the group stored: forced to override,
        // so an authored `add` cannot sum two modes into a third that means
        // nothing.
        for effect in [
            PhonoscopeEffectID.centreTransition, PhonoscopeEffectID.centreTransitionAxis,
            PhonoscopeEffectID.centreTransitionDivisions,
            PhonoscopeEffectID.centreTransitionReturn,
            "glow", PhonoscopeEffectID.glowBlend,
        ] {
            mix(phonoscopeIsOverrideOnlyEffect(effect) ? 1 : 0)
        }

        let produced = String(format: "parameter-drivers:%d:%016llx", samples, hash)
        assert(
            produced == "parameter-drivers:485:ced1796f8332b5c1",
            "parameter-driver parity drifted from nova-visualiser: \(produced)"
        )
    }

    /// Mirrors nova::resolveEffectDimensions and the effect-scale corpus case.
    /// Dot cores, wires, and normalized backdrop geometry are invariant;
    /// pixel-sized halos, trails, and bloom grow with denser output.
    ///
    /// A module's `render.dotSizePixels` is the one quantity that moves the
    /// other way — real device pixels, divided by the output height rather than
    /// multiplied by the 1080p ratio — so it is digested here alongside them.
    /// See `nova-visualiser-modules/specs/particle-grid-dot-size.md`.
    private static func testEffectScaleParity() {
        var hash: UInt64 = 1_469_598_103_934_665_603
        func mix(_ value: Float) {
            let quantised = Int64((value * 10_000).rounded())
            for byte in 0 ..< 8 {
                hash = (hash ^ UInt64(UInt8(truncatingIfNeeded: quantised >> (byte * 8))))
                    &* 1_099_511_628_211
            }
        }

        let heights: [Float] = [720, 1_080, 2_160]
        for height in heights {
            let scale = max(1, height / 1_080)
            let dimensions: [Float] = [
                scale,
                0.012,             // dot core: unchanged
                0.002,             // wire width: unchanged
                0.03 * scale,      // halo
                25.5 * scale,      // trail length
                0.012 * scale,     // trail width
                1 * scale,         // bloom radius
                0.48,              // normalized background feature radius
            ]
            dimensions.forEach(mix)
            for pixels in [Float(0), 3.8, 12, 50, 200, 500] {
                mix(phonoscopeDotSizeClip(pixels, outputHeight: height))
            }
        }

        let produced = String(format: "effect-scale:%d:%016llx", heights.count, hash)
        assert(
            produced == "effect-scale:3:a95f7475609c569b",
            "effect-scale parity drifted from nova-visualiser: \(produced)"
        )

        // The identity IS the "true device pixels" decision: twice the height,
        // half the clip radius, for the same authored number of pixels. If dot
        // size is ever routed through `effectScale`, this is the line that fails.
        assert(
            phonoscopeDotSizeClip(50, outputHeight: 2_160)
                == phonoscopeDotSizeClip(50, outputHeight: 1_080) / 2,
            "dot size stopped being measured in true device pixels"
        )
        // Zero means no dots. There is no visible floor to fall back to, on
        // either engine.
        assert(
            phonoscopeDotSizeClip(0, outputHeight: 1_080) == 0,
            "a zero dot size must publish zero, not a floor"
        )
        // 3.8px at the 1080-line authoring reference is the module's original
        // baked 0.0035 clip units, to within a fiftieth of a pixel.
        assert(
            abs(phonoscopeDotSizeClip(3.8, outputHeight: 1_080) - 0.0035) < 0.00002,
            "the authored dot size drifted away from 0.0035 clip at 1080p"
        )
    }

    /// Cross-engine composite parity.
    ///
    /// Two independent engines implement `PHONOSCOPE_MODULE_SPEC.md`: this one
    /// and the C++/GLSL renderer in `nova-visualiser`. The conformance corpus
    /// digests simulation particle state only — it links against the core
    /// library with no GL and no CUDA — so every shared *shader* formula was
    /// untested, which is how the two sides came to disagree about whether
    /// bloom alpha means coverage.
    ///
    /// This evaluates the same grid as `runCompositeCase()` in
    /// `nova-visualiser/src/tools/conformance.cpp` and must produce the same
    /// digest as `tests/conformance/composite/expected.json`. Changing the
    /// composite means changing `phonoscope_composite` in
    /// `PhonoscopeShader.metal`, `src/shaders/composite.frag`,
    /// `src/core/composite_reference.h`, this test, and that baseline —
    /// together, in one change.
    /// Cross-engine parity for the backdrop band and the frame vignette.
    ///
    /// The band used to be a hardcoded `1.0 / 3.0` in the streamed renderer and
    /// a SwiftUI `.frame(height: geometry.size.height / 3)` here, with the
    /// vignette as five magic numbers in each. Two unrelated expressions of the
    /// same constant is exactly the shape that drifts, and height, width,
    /// vignette opacity and vignette size are all driven parameters now — so
    /// the layout is locked rather than left to agree by coincidence.
    ///
    /// Evaluates the same grid as `runBackgroundBandCase()` in
    /// `nova-visualiser/src/tools/conformance.cpp` and must produce the same
    /// digest as `tests/conformance/background-band/expected.json`. Changing
    /// the band means changing `fluidBackgroundFragment` in
    /// `FluidBackgroundShader.metal`, `src/shaders/fluid_background.frag`,
    /// `src/core/background_band_reference.h`, this test, and that baseline —
    /// together, in one change.
    private static func testBackgroundBandParity() {
        // Mirrors nova::backgroundBandReference. Float32 throughout, because
        // the digest quantises to 4 decimal places and Double would drift at
        // the boundaries.
        func bandEdge(_ t: Float, _ extent: Float, _ opacity: Float, _ size: Float) -> Float {
            let span = max(0.0001, extent * size)
            return opacity * min(max(1 - t / span, 0), 1)
        }

        func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
            let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
            return t * t * (3 - 2 * t)
        }

        /// Returns (inBand, vignetteShade, colour).
        func reference(
            u: Float, v: Float,
            heightFraction: Float, widthFraction: Float,
            bandPixelWidth: Float, bandPixelHeight: Float,
            vignetteColor: SIMD3<Float>, vignetteOpacity: Float, vignetteSize: Float,
            fieldColor: SIMD3<Float>
        ) -> (Float, Float, SIMD4<Float>) {
            let height = min(max(heightFraction, 0), 1)
            let width = min(max(widthFraction, 0), 1)
            let opacity = min(max(vignetteOpacity, 0), 1)
            let size = max(vignetteSize, 0)

            // The band is centred on both axes.
            let bandTop = 0.5 - height * 0.5
            let bandLeft = 0.5 - width * 0.5
            let bandLocalY = (v - bandTop) / max(0.0001, height)
            let bandLocalX = (u - bandLeft) / max(0.0001, width)

            let softX = 1 / max(1, bandPixelWidth)
            let softY = 1 / max(1, bandPixelHeight)
            let inBand = smoothstep(-softY, softY, bandLocalY)
                * smoothstep(-softY, softY, 1 - bandLocalY)
                * smoothstep(-softX, softX, bandLocalX)
                * smoothstep(-softX, softX, 1 - bandLocalX)

            if inBand <= 0 {
                // Outside the band is the vignette colour at full coverage, not
                // a hole: the bars and the gradient inside are one surface.
                return (inBand, 1, SIMD4<Float>(vignetteColor.x, vignetteColor.y, vignetteColor.z, 1))
            }

            let bandU = min(max(bandLocalX, 0), 1)
            let bandV = min(max(bandLocalY, 0), 1)

            // Four gradients in BAND-local space, composited source-over — so
            // they combine as 1 - prod(1 - a), not as a sum.
            let left = bandEdge(bandU, 0.18, opacity, size)
            let right = bandEdge(1 - bandU, 0.18, opacity, size)
            let top = bandEdge(bandV, 0.28, opacity, size)
            let bottom = bandEdge(1 - bandV, 0.28, opacity, size)
            let shade = 1 - (1 - left) * (1 - right) * (1 - top) * (1 - bottom)

            func channel(_ field: Float, _ vignette: Float) -> Float {
                let shaded = field + (vignette - field) * shade
                return vignette + (shaded - vignette) * inBand
            }
            let colour = SIMD4<Float>(
                channel(fieldColor.x, vignetteColor.x),
                channel(fieldColor.y, vignetteColor.y),
                channel(fieldColor.z, vignetteColor.z),
                1
            )
            return (inBand, shade, colour)
        }

        var hash: UInt64 = 1_469_598_103_934_665_603
        func mix(_ value: Float) {
            let quantised = Int64((value * 10_000).rounded())
            for byte in 0 ..< 8 {
                hash = (hash ^ UInt64(UInt8(truncatingIfNeeded: quantised >> (byte * 8))))
                    &* 1_099_511_628_211
            }
        }

        let heights: [Float] = [0, 1.0 / 3.0, 0.5, 1]
        let widths: [Float] = [0.25, 0.6, 1]
        let opacities: [Float] = [0, 0.5, 0.96, 1]
        let sizes: [Float] = [0, 1, 2.5]
        // Straddles the band edge at the default 1/3 height, both corners, and
        // the centre.
        let us: [Float] = [0, 0.09, 0.2, 0.5, 0.91, 1]
        let vs: [Float] = [0, 0.3333, 0.4, 0.5, 0.6667, 1]

        var samples = 0
        for height in heights {
            for width in widths {
                for opacity in opacities {
                    for size in sizes {
                        for u in us {
                            for v in vs {
                                let (inBand, shade, colour) = reference(
                                    u: u, v: v,
                                    heightFraction: height, widthFraction: width,
                                    bandPixelWidth: 3840 * width,
                                    bandPixelHeight: 2160 * height,
                                    // Not black, so a mistake that collapses the
                                    // vignette to a plain darken is
                                    // distinguishable from one that tints.
                                    vignetteColor: SIMD3<Float>(0.06, 0.02, 0.14),
                                    vignetteOpacity: opacity,
                                    vignetteSize: size,
                                    fieldColor: SIMD3<Float>(0.62, 0.48, 0.71)
                                )
                                mix(inBand)
                                mix(shade)
                                mix(colour.x)
                                mix(colour.y)
                                mix(colour.z)
                                mix(colour.w)
                                samples += 1
                            }
                        }
                    }
                }
            }
        }

        let produced = String(format: "background-band:%d:%016llx", samples, hash)
        assert(
            produced == "background-band:5184:e5070cd8a984720d",
            "background band parity drifted from nova-visualiser: \(produced)"
        )
    }

    /// Cross-engine parity for how the scene layer meets the backdrop.
    ///
    /// Note this locks the *formula* both engines intend, not what this engine
    /// runs: the streamed renderer has the backdrop as a texture inside its
    /// composite pass and blends there, while this one draws the backdrop as a
    /// separate view behind the Metal view and applies the blend as a SwiftUI
    /// `BlendMode` (see `PhonoscopeSceneBlendMode.swiftUI`). The two agree on
    /// which mode a driven value resolves to and on what each mode means; they
    /// differ in colour space, because SwiftUI blends the display-referred
    /// result and the streamed engine blends in linear HDR before the tonemap.
    ///
    /// Evaluates the same grid as `runSceneBlendCase()` in
    /// `nova-visualiser/src/tools/conformance.cpp` and must produce the same
    /// digest as `tests/conformance/scene-blend/expected.json`.
    private static func testSceneBlendParity() {
        func reference(
            scene: SIMD4<Float>,
            bloom: SIMD4<Float>,
            background: SIMD4<Float>,
            intensity: Float,
            mode: PhonoscopeSceneBlendMode
        ) -> SIMD4<Float> {
            let glow = SIMD3<Float>(bloom.x, bloom.y, bloom.z) * intensity
            let foreground = SIMD3<Float>(scene.x, scene.y, scene.z) + glow
            let foregroundAlpha = min(max(scene.w, 0), 1)
            let backgroundAlpha = min(max(background.w, 0), 1)
            let reveal = backgroundAlpha * (1 - foregroundAlpha)
            let backdrop = SIMD3<Float>(background.x, background.y, background.z)
            let sourceOver = foreground + backdrop * reveal
            let outAlpha = min(max(foregroundAlpha + reveal, 0), 1)

            if mode == .linear {
                return SIMD4<Float>(
                    max(0, sourceOver.x), max(0, sourceOver.y), max(0, sourceOver.z), outAlpha)
            }

            // Display-referred blends, so both sides come into 0-1 first.
            //
            // BOTH sides enter NOT premultiplied by their own coverage:
            // multiplying by a partly-covered layer would otherwise read as
            // multiplying by black. The backdrop always had this treatment; the
            // scene did not, which is why a lattice covering a fraction of the
            // frame behaved like an opaque black plate under multiply and
            // overlay. Bloom is excluded from the blended base -- it carries no
            // coverage and so has no un-premultiplied form -- and is added back
            // after the blend as the additive light it is.
            let inverseCoverage: Float = foregroundAlpha > 0 ? 1 / foregroundAlpha : 0

            func blend(_ scene: Float, _ backdrop: Float, _ glow: Float, _ sourceOver: Float)
                -> Float
            {
                let s = min(max(scene * inverseCoverage, 0), 1)
                let b = min(max(backdrop, 0), 1)
                var blended = s
                switch mode {
                case .screen: blended = s + b - s * b
                case .multiply: blended = s * b
                case .overlay:
                    // Photoshop overlay with the BACKDROP choosing the branch:
                    // the backdrop is the base layer, the scene is laid over it.
                    blended = b < 0.5 ? 2 * s * b : 1 - 2 * (1 - s) * (1 - b)
                case .linear: break
                }
                // The scene's own alpha is the mask: where it does not cover the
                // backdrop passes through untouched, where it covers fully the
                // mode applies at full strength.
                let overBackdrop = (blended * foregroundAlpha + b * (1 - foregroundAlpha)) * outAlpha
                // Where the backdrop does not cover there is nothing to blend
                // with, so the result falls back to plain source-over.
                return overBackdrop * backgroundAlpha + sourceOver * (1 - backgroundAlpha) + glow
            }

            let straight = backgroundAlpha > 0 ? backdrop : SIMD3<Float>.zero
            // The source-over fallback without the glow term, so adding the glow
            // once inside `blend` cannot double it.
            let base = SIMD3<Float>(scene.x, scene.y, scene.z) + backdrop * reveal
            return SIMD4<Float>(
                max(0, blend(scene.x, straight.x, glow.x, base.x)),
                max(0, blend(scene.y, straight.y, glow.y, base.y)),
                max(0, blend(scene.z, straight.z, glow.z, base.z)),
                outAlpha
            )
        }

        var hash: UInt64 = 1_469_598_103_934_665_603
        func mix(_ value: Float) {
            let quantised = Int64((value * 10_000).rounded())
            for byte in 0 ..< 8 {
                hash = (hash ^ UInt64(UInt8(truncatingIfNeeded: quantised >> (byte * 8))))
                    &* 1_099_511_628_211
            }
        }

        let intensity: Float = 1.45
        // Every mode, and every boundary either side of the snap.
        let blendValues: [Double] = [0, 0.4999, 0.5, 1, 1.4999, 1.5, 2, 2.4999, 2.5, 3, 4]
        let coverages: [Float] = [0, 0.25, 0.5, 1]
        let glows: [Float] = [0, 0.4, 1.6, 6]
        let backgroundAlphas: [Float] = [0, 0.5, 1]

        var samples = 0
        for blendValue in blendValues {
            let mode = PhonoscopeSceneBlendMode(driven: blendValue)
            // The resolved mode is digested too, so a change to where the axis
            // snaps fails here rather than silently shifting which look a stored
            // range picks.
            mix(Float(mode.rawValue))
            for coverage in coverages {
                for glow in glows {
                    for backgroundAlpha in backgroundAlphas {
                        let out = reference(
                            scene: SIMD4<Float>(
                                0.9 * coverage, 0.35 * coverage, 0.15 * coverage, coverage),
                            bloom: SIMD4<Float>(glow, glow * 0.6, glow * 0.25, glow),
                            background: SIMD4<Float>(0.16, 0.11, 0.28, backgroundAlpha),
                            intensity: intensity,
                            mode: mode
                        )
                        mix(out.x)
                        mix(out.y)
                        mix(out.z)
                        mix(out.w)
                        samples += 1
                    }
                }
            }
        }

        let produced = String(format: "scene-blend:%d:%016llx", samples, hash)
        assert(
            produced == "scene-blend:528:b295f7c3d19f9e61",
            "scene blend parity drifted from nova-visualiser: \(produced)"
        )
    }

    /// Cross-engine parity for the centre slot's image half: the contain-fit,
    /// the ramp that times a change, and the geometry of the three transitions.
    ///
    /// Both engines now run this identically — the streamed renderer through
    /// `centre_image.frag` and this one through `phonoscope_centre_image` in
    /// PhonoscopeShader.metal, off the same uniforms. A flip or a slide is a
    /// per-fragment transform, so the SwiftUI approximation this used to lock
    /// against is gone; what is left to lock is the arithmetic itself, which is
    /// the thing that can silently drift.
    ///
    /// Evaluates the same grid as `runCentreImageCase()` in
    /// `nova-visualiser/src/tools/conformance.cpp` and must produce the same
    /// digest as `tests/conformance/centre-image/expected.json`.
    private static func testCentreImageParity() {
        // Mirrors nova::imageHalfExtent, which sizes BOTH slots: the centre
        // image and the background image share one control set, and the scale
        // clamp is shared with the message because the slot is scaled, not
        // whatever is in it.
        //
        // `fit` decides where the base size comes from — manual reads the width
        // and height, fit and fill derive both from the image and ignore them —
        // and `proportional` makes the height follow the width under a manual
        // fit. The scale multiplies in every mode.
        //
        // Float32 throughout, like every other mirror in this file: the digest
        // quantises to four decimal places and Double would drift at the
        // boundaries. `phonoscopeImageHalfExtent` in PhonoscopeModels.swift is
        // the Double-typed production copy; this is the one that has to match
        // C++ bit for bit.
        func halfExtent(
            frameAspect: Float, imageAspect: Float, widthFraction: Float,
            heightFraction: Float, scale: Float, fit: Int, proportional: Bool
        ) -> (Float, Float) {
            guard frameAspect > 0, imageAspect > 0 else { return (0, 0) }
            let clampedScale = min(max(scale, 0.1), 5)
            let heightPerWidth = frameAspect / imageAspect
            if fit == 0 {
                let halfWidth = 0.5 * max(0, widthFraction) * clampedScale
                let halfHeight = proportional
                    ? halfWidth * heightPerWidth
                    : 0.5 * max(0, heightFraction) * clampedScale
                return (halfWidth, halfHeight)
            }
            let heightWhenWidthFills = 0.5 * heightPerWidth
            let halfHeight = fit == 1
                ? min(0.5, heightWhenWidthFills)
                : max(0.5, heightWhenWidthFills)
            let scaled = halfHeight * clampedScale
            return (scaled / heightPerWidth, scaled)
        }

        // Mirrors nova::imageFitFor. Where 0.5 and 1.5 fall is part of the
        // contract: a stored binding holds a number on this axis.
        func fitFor(_ value: Double) -> Int {
            if value >= 1.5 { return 2 }
            if value >= 0.5 { return 1 }
            return 0
        }

        // Mirrors nova::transitionRamp: the ramp control read as a motion
        // profile, where attack eases in, hold is the flat constant-velocity
        // middle and release eases out, so a transition lasts their sum. Peak
        // velocity is whatever makes the area exactly 1, which is what stops a
        // long ease-in from overshooting the end.
        //
        // Float32 throughout, like every other mirror in this file: the digest
        // quantises to four decimal places and Double would drift at the
        // boundaries. `PhonoscopeCentreTransition.swift` is the Double-typed
        // production copy; this is the one that has to match C++ bit for bit.
        func ramp(elapsed: Float, attack: Float, hold: Float, release: Float) -> Float {
            let attack = max(0, attack)
            let hold = max(0, hold)
            let release = max(0, release)
            let total = attack + hold + release
            let elapsed = max(0, elapsed)
            guard total > 0, elapsed < total else { return 1 }
            let peak = 1 / (attack * 0.5 + hold + release * 0.5)
            if elapsed < attack {
                return min(max(peak * elapsed * elapsed / (2 * attack), 0), 1)
            }
            if elapsed < attack + hold {
                return min(max(peak * (attack * 0.5 + (elapsed - attack)), 0), 1)
            }
            let decelerating = elapsed - attack - hold
            return min(max(peak * (attack * 0.5 + hold + decelerating
                                   - decelerating * decelerating / (2 * release)), 0), 1)
        }

        // Mirrors nova::centreImageFade: a caller with nothing but a total
        // duration spends all of it easing out, which is what a bare release
        // means and what every configuration written before the ramp meant this
        // already had.
        func fade(elapsed: Float, transition: Float) -> Float {
            ramp(elapsed: elapsed, attack: 0, hold: 0, release: transition)
        }

        // Mirrors nova::centreSlideClearDistance — the smallest offset that
        // fully clears the frame at a given angle.
        func clearDistance(
            axisRadians: Float, frameAspect: Float, halfWidth: Float, halfHeight: Float
        ) -> Float {
            let along = abs(cos(axisRadians))
            let across = abs(sin(axisRadians))
            let frameSpan = 0.5 * (along * max(0, frameAspect) + across)
            let imageSpan = along * abs(halfWidth) * max(0, frameAspect) + across * abs(halfHeight)
            return frameSpan + imageSpan
        }

        // Mirrors nova::centreSlideSegment. Indexed on the perpendicular
        // coordinate, which displacement never changes.
        func segment(across: Float, halfAcross: Float, divisions: Int) -> Int {
            let segments = max(1, min(10, divisions) + 1)
            guard halfAcross > 0 else { return 0 }
            let position = (across / halfAcross) * 0.5 + 0.5
            return max(0, min(segments - 1, Int(floor(position * Float(segments)))))
        }

        // Mirrors nova::centreSlideDirection: alternating by parity.
        func direction(segment: Int) -> Float { segment % 2 == 0 ? 1 : -1 }

        // Mirrors nova::centreSlideOffset. Two legs of one movement, each
        // linear in progress; the ramp supplies all the acceleration.
        func slideOffset(
            progress: Float, incoming: Bool, direction: Float,
            clearDistance: Float, returnFromOrigin: Bool
        ) -> Float {
            let clamped = min(max(progress, 0), 1)
            if !incoming { return direction * clearDistance * (clamped * 2) }
            let arriving = clamped * 2 - 1
            let travel = returnFromOrigin ? -direction : direction
            return travel * clearDistance * (arriving - 1)
        }

        // Mirrors nova::centreFlipScale and nova::centreFlipShowsIncoming: the
        // collapse along the axis, and the exact-midpoint swap that makes a flip
        // read as one object turning over.
        func flipScale(progress: Float) -> Float {
            abs(cos(Float.pi * min(max(progress, 0), 1)))
        }
        func flipShowsIncoming(progress: Float) -> Bool { progress >= 0.5 }

        // Mirrors nova::centreTransitionFor: 0 cross-fade, 1 flip, 2 slide.
        func transitionFor(_ value: Float) -> Int {
            if value >= 1.5 { return 2 }
            if value >= 0.5 { return 1 }
            return 0
        }

        var hash: UInt64 = 1_469_598_103_934_665_603
        func mix(_ value: Float) {
            let quantised = Int64((value * 10_000).rounded())
            for byte in 0 ..< 8 {
                hash = (hash ^ UInt64(UInt8(truncatingIfNeeded: quantised >> (byte * 8))))
                    &* 1_099_511_628_211
            }
        }

        let frameAspects: [Float] = [16.0 / 9.0, 21.0 / 9.0]
        let imageAspects: [Float] = [0.5, 1, 16.0 / 9.0, 2.5, 4]
        let scales: [Float] = [0, 0.1, 0.5, 1, 2.75, 5, 9]
        let heights: [Float] = [0, 0.33, 1, 1.5]
        let widths: [Float] = [0, 0.33, 1, 1.5]
        // Every mode against every flag, in exactly the C++ case's loop order —
        // the digest is order-sensitive, so the nesting IS part of the contract.
        let fits = [0, 1, 2]

        var samples = 0
        for frameAspect in frameAspects {
            for imageAspect in imageAspects {
                for width in widths {
                    for height in heights {
                        for scale in scales {
                            for fit in fits {
                                for proportional in [false, true] {
                                    let extent = halfExtent(
                                        frameAspect: frameAspect, imageAspect: imageAspect,
                                        widthFraction: width, heightFraction: height,
                                        scale: scale, fit: fit, proportional: proportional)
                                    mix(extent.0)
                                    mix(extent.1)
                                    samples += 1
                                }
                            }
                        }
                    }
                }
            }
        }

        for value in [-1.0, 0.0, 0.49, 0.5, 1.0, 1.49, 1.5, 2.0, 7.0] {
            mix(Float(fitFor(value)))
            samples += 1
        }

        let transitions: [Float] = [0, 0.6, 2.5]
        let elapsed: [Float] = [0, 0.15, 0.6, 1.2, 5]
        for transition in transitions {
            for seconds in elapsed {
                mix(fade(elapsed: seconds, transition: transition))
                samples += 1
            }
        }

        // The ramp as a motion profile, over every degenerate shape as well as
        // the balanced one: an instant cut, a bare release (pure ease-out), a
        // bare attack (everything deferred to the end), and symmetric profiles
        // whose midpoint must land on exactly 0.5.
        let ramps: [(Float, Float, Float)] = [
            (0, 0, 0), (0, 0, 0.6), (0.6, 0, 0), (0.05, 0, 0.6),
            (0.5, 1, 0.5), (1, 0, 1), (0.25, 0.5, 1.25),
        ]
        let rampElapsed: [Float] = [0, 0.05, 0.25, 0.5, 1, 1.5, 2, 3]
        for phases in ramps {
            for seconds in rampElapsed {
                mix(ramp(elapsed: seconds, attack: phases.0, hold: phases.1, release: phases.2))
                samples += 1
            }
        }

        // Transition geometry. The axis sweep covers both cardinals, both
        // diagonals and a value just short of the wrap, because the segment
        // parity and the clear distance both change character across them.
        let axes: [Float] = [0, 45, 90, 200, 359]
        let divisionCounts = [0, 1, 2, 7, 10]
        let progressPoints: [Float] = [0, 0.25, 0.49, 0.5, 0.51, 0.75, 1]
        for degrees in axes {
            let radians = degrees * Float.pi / 180
            for frameAspect in frameAspects {
                mix(clearDistance(
                    axisRadians: radians, frameAspect: frameAspect,
                    halfWidth: 0.3, halfHeight: 0.165))
                samples += 1
            }
            for cuts in divisionCounts {
                // Sampled across the perpendicular extent, so every segment
                // boundary — including both outer edges, where the clamp is
                // what stops an off-by-one from landing outside the list.
                for step in 0 ... 8 {
                    let across = -0.4 + 0.1 * Float(step)
                    let index = segment(across: across, halfAcross: 0.4, divisions: cuts)
                    mix(Float(index))
                    mix(direction(segment: index))
                    samples += 1
                }
                for fraction in progressPoints {
                    let travel = direction(segment: cuts % 2)
                    for incoming in [false, true] {
                        for origin in [false, true] {
                            mix(slideOffset(
                                progress: fraction, incoming: incoming, direction: travel,
                                clearDistance: 0.75, returnFromOrigin: origin))
                            samples += 1
                        }
                    }
                }
            }
        }
        for fraction in progressPoints {
            mix(flipScale(progress: fraction))
            mix(flipShowsIncoming(progress: fraction) ? 1 : 0)
            mix(Float(transitionFor(fraction * 2)))
            samples += 1
        }

        let produced = String(format: "centre-image:%d:%016llx", samples, hash)
        assert(
            produced == "centre-image:7742:4552642f8fcba8e1",
            "centre image parity drifted from nova-visualiser: \(produced)"
        )
    }

    private static func testCompositeParity() {
        // Mirrors nova::compositeReference. Float32 throughout, because the
        // digest quantises to 4 decimal places and Double would drift at the
        // boundaries.
        func compositeReference(
            scene: SIMD4<Float>,
            bloom: SIMD4<Float>,
            background: SIMD4<Float>,
            intensity: Float
        ) -> SIMD4<Float> {
            let glow = SIMD3<Float>(bloom.x, bloom.y, bloom.z) * intensity
            let foreground = SIMD3<Float>(scene.x, scene.y, scene.z) + glow
            // Coverage from the scene pass alone: a glow is additive light and
            // occludes nothing.
            let foregroundAlpha = min(max(scene.w, 0), 1)
            let backgroundAlpha = min(max(background.w, 0), 1)
            let reveal = backgroundAlpha * (1 - foregroundAlpha)
            let color = foreground + SIMD3<Float>(background.x, background.y, background.z) * reveal
            return SIMD4<Float>(
                max(0, color.x),
                max(0, color.y),
                max(0, color.z),
                min(max(foregroundAlpha + reveal, 0), 1)
            )
        }

        var hash: UInt64 = 1_469_598_103_934_665_603
        func mix(_ value: Float) {
            let quantised = Int64((value * 10_000).rounded())
            for byte in 0 ..< 8 {
                hash = (hash ^ UInt64(UInt8(truncatingIfNeeded: quantised >> (byte * 8))))
                    &* 1_099_511_628_211
            }
        }

        let intensity: Float = 1.45
        let coverages: [Float] = [0, 0.25, 0.5, 1]
        let glows: [Float] = [0, 0.4, 1.6, 6]
        let backgroundAlphas: [Float] = [0, 0.5, 1]

        var samples = 0
        for coverage in coverages {
            for glow in glows {
                for backgroundAlpha in backgroundAlphas {
                    let out = compositeReference(
                        // Premultiplied, as the particle pass emits it.
                        scene: SIMD4<Float>(0.9 * coverage, 0.35 * coverage, 0.15 * coverage, coverage),
                        bloom: SIMD4<Float>(glow, glow * 0.6, glow * 0.25, glow),
                        background: SIMD4<Float>(0.16, 0.11, 0.28, backgroundAlpha),
                        intensity: intensity
                    )
                    mix(out.x)
                    mix(out.y)
                    mix(out.z)
                    mix(out.w)
                    samples += 1
                }
            }
        }

        let produced = String(format: "composite:%d:%016llx", samples, hash)
        assert(
            produced == "composite:48:e3a70488b0fd859b",
            "composite parity drifted from nova-visualiser: \(produced)"
        )
    }

    /// Cross-engine parity for the final glow overlay.
    ///
    /// Two things in that pass can drift independently and neither is visible
    /// as a failure — a softness mismatch and a blend mismatch both just look
    /// like "the television is a bit different". So all of it is locked: the
    /// blur's sigma mapping and tap weights, the three blend modes, and the
    /// points at which the driven blend-mode parameter snaps between them
    /// (`nova::glowBlendModeFor` in `src/core/effect_scale.h`).
    ///
    /// Evaluates the same grid as `runGlowOverlayCase()` in
    /// `nova-visualiser/src/tools/conformance.cpp` and must produce the same
    /// digest as `tests/conformance/glow-overlay/expected.json`. Changing the
    /// overlay means changing `phonoscope_glow_blur`/`phonoscope_glow_overlay`
    /// in `PhonoscopeShader.metal`, `src/shaders/glow_blur.frag` and
    /// `glow_overlay.frag`, `src/core/glow_overlay_reference.h`, this test, and
    /// that baseline — together, in one change.
    private static func testGlowOverlayParity() {
        // Mirrors nova::glowOverlayReference. Float32 throughout, matching the
        // composite test's reasoning about quantisation.
        func glowOverlayReference(
            base: SIMD4<Float>,
            glow: SIMD4<Float>,
            opacity: Float,
            overdrive: Float,
            clamped: Bool,
            mode: PhonoscopeGlowBlendMode
        ) -> SIMD4<Float> {
            let amount = min(max(opacity, 0), 1)
            let drive = min(max(overdrive, 1), 10)
            // Blend modes are defined on display-referred colour, so the glow
            // is clamped: an unclamped HDR highlight saturates `screen` to
            // white and stops `multiply` darkening anything. Overdrive is
            // applied before that clamp, so it saturates rather than escaping
            // the range the blends are defined on.
            func blend(_ base: Float, _ glow: Float) -> Float {
                let driven = max(glow * drive, 0)
                let g = clamped ? min(driven, 1) : driven
                let b = max(base, 0)
                switch mode {
                case .multiply:
                    return b * (1 - amount + g * amount)
                case .overlay:
                    // Photoshop overlay: multiply where the base is dark and
                    // screen where it is light, with the base choosing which.
                    let overlaid = b < 0.5 ? 2 * b * g : 1 - 2 * (1 - b) * (1 - g)
                    return b + amount * (overlaid - b)
                case .screen:
                    return b + amount * (g - b * g)
                }
            }
            // Coverage is deliberately untouched.
            return SIMD4<Float>(
                blend(base.x, glow.x),
                blend(base.y, glow.y),
                blend(base.z, glow.z),
                base.w
            )
        }

        var hash: UInt64 = 1_469_598_103_934_665_603
        func mix(_ value: Float) {
            let quantised = Int64((value * 10_000).rounded())
            for byte in 0 ..< 8 {
                hash = (hash ^ UInt64(UInt8(truncatingIfNeeded: quantised >> (byte * 8))))
                    &* 1_099_511_628_211
            }
        }

        var samples = 0
        let heights: [Double] = [720, 1_080, 2_160]
        let blurAmounts: [Double] = [0, 1, 7.5, 20]
        for height in heights {
            for blur in blurAmounts {
                let settings = PhonoscopeGlowOverlaySettings(blurAmount: blur)
                mix(settings.blurSigmaTexels(outputHeight: height))
                samples += 1
            }
        }
        // Tap weights: exp(-i²/18) for i in 0...6. Constant because the tap
        // stride is proportional to sigma.
        for tap in 0 ... 6 {
            mix(exp(-Float(tap * tap) / 18))
            samples += 1
        }

        let bases: [Float] = [0, 0.35, 1, 3]
        let glows: [Float] = [0, 0.4, 1, 2.5]
        let opacities: [Float] = [0, 0.5, 1]
        // 1 is the identity, 2.5 saturates a mid glow, 10 is the top of the axis.
        let overdrives: [Float] = [1, 2.5, 10]
        // Clamped first, so the original ordering is preserved and the
        // unclamped run is appended.
        let clampings = [true, false]
        // Ordered as `runGlowOverlayCase()` orders them: the two original modes
        // first, overlay appended.
        for mode in [PhonoscopeGlowBlendMode.multiply, .screen, .overlay] {
            for base in bases {
                for glow in glows {
                    for opacity in opacities {
                        for overdrive in overdrives {
                            for clamped in clampings {
                                let out = glowOverlayReference(
                                    base: SIMD4<Float>(base, base * 0.6, base * 0.25, 0.75),
                                    glow: SIMD4<Float>(glow, glow * 0.5, glow * 0.9, 0.4),
                                    opacity: opacity,
                                    overdrive: overdrive,
                                    clamped: clamped,
                                    mode: mode
                                )
                                mix(out.x)
                                mix(out.y)
                                mix(out.z)
                                mix(out.w)
                                samples += 1
                            }
                        }
                    }
                }
            }
        }

        // Which mode each driven value snaps to. Both engines are handed a
        // continuous number by the driver, so every cut point — including the
        // values either side of it — has to agree.
        for blend in [0.0, 0.25, 0.4999, 0.5, 0.75, 1.0, 1.4999, 1.5, 2.0] {
            mix(Float(PhonoscopeGlowBlendMode(driven: blend).rawValue))
            samples += 1
        }

        let produced = String(format: "glow-overlay:%d:%016llx", samples, hash)
        assert(
            produced == "glow-overlay:892:946bad8d3da026b4",
            "glow-overlay parity drifted from nova-visualiser: \(produced)"
        )
    }

    /// Runs the SAME conformance table as the web dashboard's
    /// `lib/orb-info/format.test.ts`. A failure here means the status orb would
    /// read one way on the dashboard and another on the Apple TV.
    private static func testOrbInfoFormatConformance() {
        struct CaseFile: Decodable {
            struct Entry: Decodable {
                let name: String
                let output: OutputPayload
                let display: OrbInfoDisplayPayload
                let expectText: String
                let expectAlert: Bool
            }
            struct OutputPayload: Decodable {
                let value: Double?
                let text: String?
                let baseUnit: String?
                let status: String?
                let alert: Bool?
                let alertThreshold: Double?
            }
            let cases: [Entry]
        }

        guard let data = OrbInfoConformanceCases.json.data(using: .utf8),
              let file = try? JSONDecoder().decode(CaseFile.self, from: data) else {
            assertionFailure("orb info conformance table failed to decode")
            return
        }
        assert(!file.cases.isEmpty)

        for entry in file.cases {
            let output = OrbModuleOutput(
                value: entry.output.value,
                text: entry.output.text,
                baseUnit: entry.output.baseUnit.flatMap(OrbBaseUnit.init(rawValue:)) ?? .none,
                status: entry.output.status.flatMap(OrbModuleOutput.Status.init(rawValue:)) ?? .unavailable,
                alert: entry.output.alert ?? false,
                alertThreshold: entry.output.alertThreshold
            )
            let display = entry.display.resolved(onto: .default)
            let result = formatOrbValue(output, display, label: "Test")
            assert(
                result.text == entry.expectText,
                "orb info case '\(entry.name)': expected '\(entry.expectText)', got '\(result.text)'"
            )
            assert(
                result.alert == entry.expectAlert,
                "orb info case '\(entry.name)': expected alert \(entry.expectAlert), got \(result.alert)"
            )
        }
    }

    private static func testClockFormatting() {
        assert(ordinalDay(1) == "1st")
        assert(ordinalDay(2) == "2nd")
        assert(ordinalDay(3) == "3rd")
        assert(ordinalDay(11) == "11th")
        assert(ordinalDay(12) == "12th")
        assert(ordinalDay(13) == "13th")
        assert(ordinalDay(21) == "21st")
        assert(ordinalDay(22) == "22nd")
        assert(ordinalDay(23) == "23rd")

        let testTimeZone = TimeZone(secondsFromGMT: 12 * 60 * 60)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = testTimeZone
        let date = calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 27,
            hour: 13,
            minute: 5,
            second: 9
        ))!
        assert(timeText(date, timeZone: testTimeZone) == "1:05:09 PM")
        assert(dashboardDateText(date, timeZone: testTimeZone) == "27th July 2026")
        assert(dashboardWeekdayIndex(date, timeZone: testTimeZone) == 0)
        assert(dashboardLocationText(timeZone: TimeZone(identifier: "Etc/UTC")!) == "UTC")
    }

    private static func testThemeDecoding() {
        let json = """
        {
          "theme": {
            "selection": "dark",
            "themes": {
              "dark": {
                "background": { "rgb": [10, 20, 30], "intensity": 100 },
                "clockColor": { "rgb": [210, 190, 170], "intensity": 80 },
                "avatar": {
                  "voiceGlowColor": { "rgb": [1, 2, 3], "intensity": 100 },
                  "orbModule": "halo",
                  "orbModuleSettings": { "halo": { "chaos": 73 } },
                  "glass": {
                    "enabled": true,
                    "displace": 90,
                    "localStretch": 400,
                    "imageBlur": 12
                  }
                }
              }
            }
          }
        }
        """
        let payload = try! JSONDecoder().decode(
            SharedThemeResponse.self,
            from: Data(json.utf8)
        )
        let theme = DashboardTheme(sharedTheme: payload.theme?.resolved(sun: nil))
        assert(theme.clockColor.red == 168)
        assert(theme.clockColor.green == 152)
        assert(theme.avatar.voiceGlowColor.blue == 3)
        assert(theme.avatar.orbModule == "halo")
        assert(theme.avatar.orbModuleSettings["halo"]?["chaos"] == 73)
        assert(theme.avatar.glass.localStretch == 300)
        assert(theme.avatar.glass.imageBlur == 10)
    }

    private static func testOrbContract() {
        assert(OrbModuleCatalog.builtins.count == 4)
        assert(OrbModuleCatalog.classic != nil)
        let halo = OrbModuleCatalog.builtinMap["halo"]!
        assert(!halo.settings.isEmpty)
        let resolved = halo.resolvedSettings(saved: ["chaos": 1_000])
        if let chaos = halo.settings.first(where: { $0.id == "chaos" }) {
            assert(resolved["chaos"] == chaos.max)
        }
        let hasTurbulentRing = halo.layers.contains { layer in
            if case .ring(let ring) = layer {
                return ring.turbulence != nil
            }
            return false
        }
        assert(hasTurbulentRing)
    }

    private static func testSpeechEnvelope() {
        let consonants = VoiceSpeechSnapshot(
            turnID: "test",
            startedAt: 0,
            audibleAt: 0,
            timings: [100, 240],
            estimatedDuration: 1,
            fadeOutAt: nil,
            safetyDeadline: 10
        )
        assert(consonants.envelope(at: 0, alertPulsePeriod: 1.2) == 0)
        assert(consonants.envelope(at: 0.145, alertPulsePeriod: 1.2) > 0.2)

        var ending = consonants
        ending.fadeOutAt = 1
        assert(ending.envelope(at: 1.5, alertPulsePeriod: 1.2) == 0)

        let fallback = VoiceSpeechSnapshot(
            turnID: "fallback",
            startedAt: 0,
            audibleAt: 0,
            timings: nil,
            estimatedDuration: 1,
            fadeOutAt: nil,
            safetyDeadline: 10
        )
        assert(fallback.envelope(at: 0.3, alertPulsePeriod: 1.2) > 0)
    }

    private static func testPhonoscopeQualityPolicy() {
        // Quality is fixed at the highest the device supports; the only remaining
        // variable is whether 4x multisampling exists at all.
        assert(phonoscopeAASampleCount(supportsFourSamples: true) == 4)
        assert(phonoscopeAASampleCount(supportsFourSamples: false) == 1)
    }

    private static func testFluidBackgroundPolicy() {
        assert(fluidBackgroundFrameRate == 60)
        assert(fluidDrawableSize(
            bounds: CGSize(width: 1_920, height: 360),
            nativeScale: 1,
            renderScale: 0.25
        ) == CGSize(width: 480, height: 90))
    }

    private static func testPhonoscopeSettingInterpolation() {
        assert(phonoscopeSettingInterpolationAction(
            targetChanged: true,
            wasDriverInterpolated: false,
            isDriverInterpolated: true
        ) == .applyImmediately)
        assert(phonoscopeSettingInterpolationAction(
            targetChanged: true,
            wasDriverInterpolated: true,
            isDriverInterpolated: true
        ) == .applyImmediately)
        assert(phonoscopeSettingInterpolationAction(
            targetChanged: true,
            wasDriverInterpolated: false,
            isDriverInterpolated: false
        ) == .transition)
        assert(phonoscopeSettingInterpolationAction(
            targetChanged: false,
            wasDriverInterpolated: true,
            isDriverInterpolated: false
        ) == .transition)
        assert(phonoscopeSettingInterpolationAction(
            targetChanged: false,
            wasDriverInterpolated: false,
            isDriverInterpolated: false
        ) == .hold)

        assert(phonoscopeChaseAmount(delta: 1, settlingDuration: 0) == 1)
        let oneThird = phonoscopeChaseAmount(delta: 1, settlingDuration: 3)
        assert(abs(oneThird - (1 - exp(-1.0))) < 0.000_001)
        let settled = phonoscopeChaseAmount(delta: 3, settlingDuration: 3)
        assert(settled > 0.95 && settled < 1)
    }

    private static func testRootBackExitGate() {
        var gate = RootBackExitGate(interval: 1)
        assert(!gate.register(at: 10))
        assert(gate.register(at: 10.8))
        assert(!gate.register(at: 11))

        gate.reset()
        assert(!gate.register(at: 20))
        assert(!gate.register(at: 21.1))
        assert(gate.register(at: 21.9))
    }

    private static func testExitCommandShield() {
        var shield = ExitCommandShield()
        assert(!shield.contains(10))
        shield.begin(at: 10, duration: 1.25)
        assert(shield.contains(10))
        assert(shield.contains(11.24))
        assert(!shield.contains(11.25))
    }
}
#endif
