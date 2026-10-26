import SwiftUI

struct ColorEncoder: View {
    @EnvironmentObject private var store: DashboardStore
    let zone: DashboardZone
    let state: DashboardState
    var compact = false
    let focus: FocusState<DashboardFocus?>.Binding
    @Binding var editingFocus: DashboardFocus?
    let editMove: DashboardEditMove?
    let editCancel: DashboardEditCancel?
    /// What the last send asked for. The phone sends each turn on release, so a
    /// hue turned just after saturation must not refill saturation from a zone
    /// state that has not caught up yet (it would revert it).
    @State private var sent: (hue: Double, saturation: Double, brightness: Double, at: Date)?

    private var hue: Double { zone.lightEntities.first?.attributes["hs_color"]?.doubleArray?.first ?? 0 }
    private var saturation: Double {
        let hs = zone.lightEntities.first?.attributes["hs_color"]?.doubleArray ?? []
        return hs.count > 1 ? hs[1] : 100
    }
    var body: some View {
        VStack(spacing: 14) {
            Text(zone.name.uppercased()).font(.novaDisplay(compact ? 18 : 28))
            RotaryEncoder(title: compact ? "ALL LIGHTS" : "LIGHTS", subtitle: "BRIGHT",
                channels: [
                    RotaryChannel(id: "hue", label: "HUE", value: hue, maximum: 359, step: 5, wraps: true,
                                  color: .red, disabled: !zone.isOn || !zone.hasHueControls, text: { "\(Int($0))°" }),
                    RotaryChannel(id: "brightness", label: "BRIGHT", value: zone.brightnessPct, step: 2,
                                  color: store.theme.accent.color, text: { "\(Int($0))%" }),
                    RotaryChannel(id: "saturation", label: "SAT", value: saturation, step: 2,
                                  color: .blue, disabled: !zone.isOn || !zone.hasHueControls, text: { "\(Int($0))%" })
                ], initialChannel: "brightness", size: compact ? 110 : 200, compact: compact, focus: focus,
                focusValue: compact ? .action("__quick", "lights") : .brightness(zone.id),
                editingFocus: $editingFocus, editMove: editMove, editCancel: editCancel) { changes in
                    let recent = sent.flatMap { Date().timeIntervalSince($0.at) < 10 ? $0 : nil }
                    let nextHue = changes["hue"] ?? recent?.hue ?? hue
                    let nextSaturation = changes["saturation"] ?? recent?.saturation ?? saturation
                    let nextBrightness = changes["brightness"] ?? recent?.brightness ?? zone.brightnessPct
                    sent = (nextHue, nextSaturation, nextBrightness, Date())
                    Task {
                        if changes["hue"] != nil || changes["saturation"] != nil {
                            let hue = nextHue
                            let saturation = nextSaturation / 100
                            let rgb = hslToRGB(hue: hue, saturation: saturation / max(0.001, 2 - saturation),
                                               lightness: 1 - saturation / 2)
                            await store.sendLightGroupAction(zone: zone, action: .color,
                                brightnessPct: nextBrightness,
                                cursor: SpectrumCursor(x: hue / 359, y: 1 - saturation), rgb: rgb)
                        } else if let brightness = changes["brightness"] {
                            await store.sendLightGroupAction(zone: zone, action: .brightness, brightnessPct: brightness)
                        }
                    }
                }
            HStack(spacing: 8) {
                preset("ON", "power", "on") { await store.sendLightGroupAction(zone: zone, action: .on) }
                preset(state.sun?.state == "below_horizon" ? "CANDLE" : "DAY", "flame.fill", "candle") {
                    let spectrum = adaptiveCandlelightSpectrum(sun: state.sun)
                    await store.sendLightGroupAction(zone: zone, action: .candlelight,
                        brightnessPct: adaptiveCandlelightBrightness(sun: state.sun), cursor: spectrum.cursor, rgb: spectrum.preview)
                }
                preset("WHITE", "sun.max.fill", "white") {
                    await store.sendLightGroupAction(zone: zone, action: .white,
                        brightnessPct: 100, cursor: whiteSpectrum.cursor, rgb: whiteSpectrum.preview)
                }
                preset("OFF", "power", "off") { await store.sendLightGroupAction(zone: zone, action: .off) }
            }.frame(height: 66)
        }.padding(compact ? 8 : 20).frame(width: compact ? 460 : 410)
    }
    private func preset(_ label: String, _ symbol: String, _ id: String,
                        action: @escaping () async -> Void) -> some View {
        ControlButton(title: label, symbol: symbol, isFocused: focus.wrappedValue == .action(compact ? "__quick" : zone.id, id)) {
            Task { await action() }
        }.dashboardFocus(focus, equals: .action(compact ? "__quick" : zone.id, id))
    }
}
