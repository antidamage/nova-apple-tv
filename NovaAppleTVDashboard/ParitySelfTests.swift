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
}
#endif
