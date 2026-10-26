#if DEBUG
import Foundation

enum LandscapeSelfTests {
    static func run() {
        SwipeEngineSelfTests.run()
        BandMapSelfTests.run()
        PressArbiterSelfTests.run()
        themeVariantTests()

        let airconChannels = [
            RotaryChannel(id: "target", label: "TARGET", value: 20),
            RotaryChannel(id: "power", label: "POWER", value: 0, kind: .selector),
            RotaryChannel(id: "mode", label: "MODE", value: 0, kind: .selector, ring: true),
            RotaryChannel(id: "fan", label: "FAN", value: 3, kind: .selector, ring: true),
            RotaryChannel(id: "timer", label: "SLEEP TIMER", value: 0, ring: true)
        ]
        assert(RotaryStepOrder.selectable(airconChannels).map(\.id) == ["timer", "fan", "mode", "target", "power"],
               "Left/right walks the rings outermost inward, then the mode lights left to right")
        assert(RotaryStepOrder.selectable([
            RotaryChannel(id: "icon", label: "TYPE", value: 0, kind: .selector),
            RotaryChannel(id: "duration", label: "DURATION", value: 0, ring: true)
        ]).map(\.id) == ["duration", "icon"], "A ring is stepped onto before the modes it sits with")
        assert(RotaryStepOrder.selectable([
            RotaryChannel(id: "hue", label: "HUE", value: 0, disabled: true),
            RotaryChannel(id: "brightness", label: "BRIGHT", value: 50),
            RotaryChannel(id: "air", label: "AIR", value: 0, hidden: true, ring: true)
        ]).map(\.id) == ["brightness"], "A hidden or disabled channel is no step at all")

        let hue = RotaryChannel(id: "hue", label: "HUE", value: 359, maximum: 359, wraps: true)
        assert(hue.stepped(359, by: 1) == 0 && hue.stepped(0, by: -1) == 359)
        let level = RotaryChannel(id: "level", label: "LEVEL", value: 100)
        assert(level.stepped(100, by: 1) == 100 && level.stepped(0, by: -1) == 0)
        assert(TimerEncoderScale.minutes.first == 0 && TimerEncoderScale.minutes.last == 480)
        assert(TimerEncoderScale.minutes.contains(10) && TimerEncoderScale.minutes.contains(15))
        assert(TimerEncoderScale.minutes.contains(11))
        assert(TimerEncoderScale.minutes[1] == 5.0 / 60)
        assert(TimerEncoderScale.fraction(480) == 1)
        assert(TimerEncoderScale.minutes[TimerEncoderScale.nearestIndex(60)] == 60)
        assert(AppConfig.urls(path: "api/tasks?command=list").first?.query == "command=list",
               "Task API queries must not become percent-encoded path characters")
        let task = TaskSummary(id: "due", start: "2026-09-19T00:00:00Z", dismissedAt: nil)
        let now = ISO8601DateFormatter().date(from: "2026-09-20T00:00:00Z")!
        assert(orbReminderEvent(moduleID: "next-reminder", tasks: [task], now: now)?.dismiss?.id == "due")
        var acknowledged = task
        acknowledged.alertDismissedFor = task.start + ":reminder"
        assert(orbReminderEvent(moduleID: "next-reminder", tasks: [acknowledged], now: now)?.alert == false)
        print("[NovaTV][tests] encoder bounds and timer detents passed")
    }
    /// The status orb, the knob face, the LEDs and the unlock ring all read the
    /// selected variant's own treatment. A gate that is not honoured draws both
    /// halves of a paired treatment, the light one last, which is what made a
    /// dark-mode orb render as the light knob.
    private static func themeVariantTests() {
        // The Tech module's own shape: a three-stop choice whose middle stop is
        // `auto`, so the resolved id the gates name carries the light/dark flag
        // and not the slider index.
        let pairJSON = ##"{"formatVersion": 1, "id": "pair", "name": "Pair", "alertPulsePeriod": 1, "settings": [{"id": "knobTheme", "label": "Knob Theme", "description": "", "min": 0, "max": 2, "step": 1, "default": 1, "options": ["light", "auto", "dark"]}], "settingMigrations": [{"to": "knobTheme", "from": ["light"], "bands": [{"min": 0, "name": "dark"}, {"min": 1, "name": "light"}]}], "layers": [{"id": "dark", "type": "disc", "radius": 1, "enabledWhen": {"setting": "knobThemeResolved", "max": 0.5}, "stops": [{"at": 0, "color": {"hex": "#000000"}}]}, {"id": "light", "type": "disc", "radius": 1, "enabledWhen": {"setting": "knobThemeResolved", "min": 0.5}, "stops": [{"at": 0, "color": {"hex": "#ffffff"}}]}, {"id": "always", "type": "disc", "radius": 0.5, "stops": [{"at": 0, "color": {"hex": "#ff0000"}}]}]}"##
        guard let module = try? JSONDecoder().decode(OrbModule.self, from: Data(pairJSON.utf8)) else {
            assertionFailure("The paired-treatment module must decode")
            return
        }
        assert(module.layers.count == 3)
        assert(module.settings.first?.options == ["light", "auto", "dark"],
               "A choice setting's stops decode in slider order")
        let dark = module.resolvedSettings(saved: ["knobTheme": 2], treatment: .dark)
        let light = module.resolvedSettings(saved: ["knobTheme": 0], treatment: .light)
        assert(dark["knobThemeResolved"] == 0 && light["knobThemeResolved"] == 1,
               "A pinned stop resolves to its own treatment, not its slider index")
        // `auto` is the device's answer, whichever way the device resolves.
        let autoAsLight = module.resolvedSettings(saved: ["knobTheme": 1], treatment: .light)
        let autoAsDark = module.resolvedSettings(saved: ["knobTheme": 1], treatment: .dark)
        assert(autoAsLight["knobThemeResolved"] == 1 && autoAsDark["knobThemeResolved"] == 0,
               "An auto stop resolves through the device's knob treatment")
        // A theme saved before the choice landed stores the old boolean id.
        let legacyLight = module.resolvedSettings(saved: ["light": 1], treatment: .dark)
        let legacyDark = module.resolvedSettings(saved: ["light": 0], treatment: .dark)
        assert(legacyLight["knobTheme"] == 0 && legacyLight["knobThemeResolved"] == 1,
               "A legacy light value lands on the light stop")
        assert(legacyDark["knobTheme"] == 2 && legacyDark["knobThemeResolved"] == 0,
               "A legacy dark value lands on the dark stop")
        assert(module.resolvedSettings(saved: ["knobTheme": 2, "light": 1], treatment: .dark)["knobTheme"] == 2,
               "Today's value wins over history")
        // An option index is not a value: a choice whose stops do not start at
        // 0 and step by 1 would otherwise resolve `auto` onto the wrong stop.
        let steppedJSON = ##"{"formatVersion": 1, "id": "stepped", "name": "Stepped", "alertPulsePeriod": 1, "settings": [{"id": "knobTheme", "label": "Knob Theme", "min": 10, "max": 30, "step": 10, "default": 20, "options": ["light", "auto", "dark"]}], "layers": [{"id": "lights", "type": "disc", "radius": 1, "stops": [{"at": 0, "color": {"hex": "#ffffff"}}]}]}"##
        if let stepped = try? JSONDecoder().decode(OrbModule.self, from: Data(steppedJSON.utf8)) {
            let lightAuto = stepped.resolvedSettings(saved: ["knobTheme": 20], treatment: .light)
            let darkAuto = stepped.resolvedSettings(saved: ["knobTheme": 20], treatment: .dark)
            assert(lightAuto["knobThemeResolved"] == 1 && darkAuto["knobThemeResolved"] == 0,
                   "A stepped choice resolves auto through the device treatment")
            assert(darkAuto["knobTheme"] == 20, "The resolved pair keeps the stored stop")
        } else {
            assertionFailure("A stepped choice module must decode")
        }
        // A choice offering no light/dark stop cannot be answered by the device
        // at all, so `auto` falls back to a concrete stop rather than to `auto`
        // itself, which no gate can interpret. The declared default here is the
        // auto stop, which is exactly the case a value-vs-index comparison got
        // wrong.
        let noStopJSON = ##"{"formatVersion": 1, "id": "nostop", "name": "NoStop", "alertPulsePeriod": 1, "settings": [{"id": "knobTheme", "label": "Knob Theme", "min": 10, "max": 30, "step": 10, "default": 20, "options": ["Low", "Auto", "High"]}], "layers": [{"id": "only", "type": "disc", "radius": 1, "stops": [{"at": 0, "color": {"hex": "#ffffff"}}]}]}"##
        if let noStop = try? JSONDecoder().decode(OrbModule.self, from: Data(noStopJSON.utf8)) {
            let fallback = noStop.resolvedSettings(saved: ["knobTheme": 20], treatment: .light)
            assert(fallback["knobThemeResolved"] == 10,
                   "auto falls back to a concrete stop, never to the auto stop")
        } else {
            assertionFailure("A choice naming no treatment must decode")
        }
        let drawn = { (settings: [String: Double]) in
            module.layers.filter { isOrbLayerGateOpen($0.base.enabledWhen, settings: settings) }.count
        }
        assert(drawn(dark) == 2 && drawn(light) == 2 && drawn(autoAsLight) == 2 && drawn(autoAsDark) == 2,
               "Exactly one half of a paired treatment draws, plus the ungated layer")
        assert(isOrbLayerGateOpen(OrbLayerGate(setting: "knobThemeResolved", min: 0.5), settings: [:]) == false,
               "A gate naming a setting the frame does not carry evaluates against 0")
        assert(isOrbLayerGateOpen(OrbLayerGate(setting: "missing", max: 0.5), settings: [:]) == true,
               "…which opens the dark side of a pair")
        assert(isOrbLayerGateOpen(nil, settings: [:]) == true, "An ungated layer always draws")
        // A gate naming no usable setting is dropped rather than honoured, so the
        // layer draws — the web's `normalizeGate` returns undefined there and
        // `orbLayerGateOpen` then answers true. The two engines must agree on this
        // too, or a malformed document draws one pair on the TV and not in the
        // browser.
        for malformed in [##"{"min": 0.5}"##, ##"{"setting": "knob.light", "min": 0.5}"##, ##"{"setting": "", "max": 0.5}"##] {
            let moduleJSON = ##"{"formatVersion": 1, "id": "m", "name": "M", "layers": [{"id": "only", "type": "disc", "radius": 1, "enabledWhen": \##(malformed), "stops": [{"at": 0, "color": {"hex": "#ffffff"}}]}]}"##
            guard let malformedModule = try? JSONDecoder().decode(OrbModule.self, from: Data(moduleJSON.utf8)),
                  let layer = malformedModule.layers.first else {
                assertionFailure("A module with a malformed gate must still decode: \(malformed)")
                return
            }
            assert(layer.base.enabledWhen == nil, "A malformed gate is dropped: \(malformed)")
            assert(isOrbLayerGateOpen(layer.base.enabledWhen, settings: [:]) == true,
                   "…so the layer draws, as it does in the browser")
        }

        let themeJSON = ##"{"theme": {"selection": "dark", "themes": {"dark": {"background": {"rgb": [255, 255, 255], "intensity": 7}, "knobSkin": "light", "ledColor": {"rgb": [255, 131, 64], "intensity": 100}, "unlockRingColor": {"rgb": [255, 255, 255], "intensity": 100}}, "light": {"background": {"rgb": [255, 255, 255], "intensity": 91}, "knobSkin": "dark", "ledColor": {"rgb": [255, 125, 94], "intensity": 100}, "unlockRingColor": {"rgb": [255, 255, 255], "intensity": 100}}}}}"##
        guard let response = try? JSONDecoder().decode(SharedThemeResponse.self, from: Data(themeJSON.utf8)),
              let device = response.theme?.resolved(sun: nil) else {
            assertionFailure("A dark-selected theme payload must resolve")
            return
        }
        let theme = DashboardTheme(sharedTheme: device)
        assert(theme.background.luminance < 0.5, "The dark variant is the one resolved for a dark selection")
        assert(theme.knobSkin == "light" && theme.knobSkinMode.isLight,
               "Dark mode asks for the pale knob, and the pale knob is what is drawn")
        assert(theme.ledColor == ThemeRGB(red: 255, green: 131, blue: 64),
               "The mode lights take the variant's ledColor, not a hard-coded colour")
        assert(theme.unlockRingColor == ThemeRGB(red: 255, green: 255, blue: 255))
        let unpinned = DashboardTheme(sharedTheme: SharedDeviceTheme())
        assert(unpinned.knobSkin == "auto" && unpinned.knobSkinMode == .dark,
               "An unpinned skin follows the theme's own surface")
        let lightTheme = DashboardTheme(sharedTheme: response.theme?.resolved(variant: "light"))
        assert(lightTheme.knobSkinMode == .dark && lightTheme.background.luminance > 0.5,
               "The light variant keeps its own skin, which is deliberately the dark knob")
    }
}
#endif
