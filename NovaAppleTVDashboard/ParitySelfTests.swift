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
        testSpeechEnvelope()
        testPhonoscopeQualityPolicy()
        testFluidBackgroundPolicy()
        testPhonoscopeSettingInterpolation()
        testCompositeParity()
        testEffectScaleParity()
        testGlowOverlayParity()
        testRootBackExitGate()
        testExitCommandShield()
    }

    /// Mirrors nova::resolveEffectDimensions and the effect-scale corpus case.
    /// Dot cores, wires, and normalized backdrop geometry are invariant;
    /// pixel-sized halos, trails, and bloom grow with denser output.
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
        }

        let produced = String(format: "effect-scale:%d:%016llx", heights.count, hash)
        assert(
            produced == "effect-scale:3:0f7739d88e90c404",
            "effect-scale parity drifted from nova-visualiser: \(produced)"
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
            mode: PhonoscopeGlowBlendMode
        ) -> SIMD4<Float> {
            let amount = min(max(opacity, 0), 1)
            // Blend modes are defined on display-referred colour, so the glow
            // is clamped: an unclamped HDR highlight saturates `screen` to
            // white and stops `multiply` darkening anything.
            func blend(_ base: Float, _ glow: Float) -> Float {
                let g = min(max(glow, 0), 1)
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
        // Ordered as `runGlowOverlayCase()` orders them: the two original modes
        // first, overlay appended.
        for mode in [PhonoscopeGlowBlendMode.multiply, .screen, .overlay] {
            for base in bases {
                for glow in glows {
                    for opacity in opacities {
                        let out = glowOverlayReference(
                            base: SIMD4<Float>(base, base * 0.6, base * 0.25, 0.75),
                            glow: SIMD4<Float>(glow, glow * 0.5, glow * 0.9, 0.4),
                            opacity: opacity,
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

        // Which mode each driven value snaps to. Both engines are handed a
        // continuous number by the driver, so every cut point — including the
        // values either side of it — has to agree.
        for blend in [0.0, 0.25, 0.4999, 0.5, 0.75, 1.0, 1.4999, 1.5, 2.0] {
            mix(Float(PhonoscopeGlowBlendMode(driven: blend).rawValue))
            samples += 1
        }

        let produced = String(format: "glow-overlay:%d:%016llx", samples, hash)
        assert(
            produced == "glow-overlay:172:8d76e7af06c50a11",
            "glow-overlay parity drifted from nova-visualiser: \(produced)"
        )
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
