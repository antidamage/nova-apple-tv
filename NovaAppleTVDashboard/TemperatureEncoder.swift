import SwiftUI

struct TemperatureEncoder: View {
    @EnvironmentObject private var store: DashboardStore
    let zone: DashboardZone
    let state: DashboardState
    let bedroom: Bool
    var compact = false
    let focus: FocusState<DashboardFocus?>.Binding
    @Binding var editingFocus: DashboardFocus?
    let editMove: DashboardEditMove?
    let editCancel: DashboardEditCancel?

    private var devices: ClimateDevices { ClimateDevices(zone: zone) }
    private var entity: DashboardEntity? {
        bedroom ? state.entities.first {
            $0.domain == "switch" && $0.name.lowercased().contains("heater") && $0.areaID.lowercased().contains("bedroom")
        } : devices.aircon
    }
    private var roomTemperature: Double? {
        if !bedroom { return entity?.currentTemperature }
        let room = state.zones.first { $0.id == entity?.areaID }
        if let id = room?.environment?.temperatureEntityID {
            return state.entities.first { $0.entityID == id }.flatMap { Double($0.state) }
        }
        return room?.entities.first { $0.attributes["device_class"]?.stringValue == "temperature" }.flatMap { Double($0.state) }
    }
    private var mode: String {
        if bedroom { return state.preferences?.bedroomHeater?.mode ?? state.climateControl?.bedroom.mode ?? "off" }
        return state.climateControl?.lounge.mode ?? (state.preferences?.aircon?.autoMode == true ? "auto" : entity?.isOn == true ? "manual" : "off")
    }
    private var modes: [String] {
        if bedroom { return ["auto", "off"] }
        let supported = entity?.hvacModes ?? []
        return supported.isEmpty || (supported.contains("heat") && supported.contains("cool")) ? ["auto", "manual", "off"] : ["manual", "off"]
    }
    private var target: Double {
        if bedroom { return state.preferences?.bedroomHeater?.temperature ?? 20 }
        if let saved = state.preferences?.aircon?.temperature { return saved }
        return entity?.targetTemperature ?? 20
    }
    /// The device's own limits: the aircon entity's, else 16–30; the heater's
    /// 5–30 (the web's BEDROOM_HEATER_MIN/MAX_TARGET_C).
    private var hardRange: ClosedRange<Double> {
        if bedroom { return 5...30 }
        let low = entity?.minimumTemperature ?? 16, high = entity?.maximumTemperature ?? 30
        return low < high ? low...high : 16...30
    }
    /// The household's knob range (`preferences.climateTargetRange`, set on the
    /// web's climate config) inside the device's own; the device's if they do
    /// not overlap. nova-ha-dashboard `effectiveTargetRange`.
    private var range: ClosedRange<Double> {
        let hard = hardRange
        guard let preferred = state.preferences?.climateTargetRange else { return hard }
        let low = max(hard.lowerBound, preferred.min), high = min(hard.upperBound, preferred.max)
        return low < high ? low...high : hard
    }
    /// The face's number: `22.5`, `22`, or `--`, no degree sign and no label,
    /// as the web knob prints it (formatTemperature).
    static func faceText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
    private var directions: [String] {
        let supported = entity?.hvacModes ?? []
        return ["cool", "dry", "fan_only", "heat"].filter { supported.isEmpty || supported.contains($0) }
    }
    private var timerMinutes: Double {
        TimerEncoderScale.remainingMinutes(bedroom ? state.preferences?.bedroomHeater?.offTimerEndsAt : state.preferences?.aircon?.offTimerEndsAt)
    }
    private var channels: [RotaryChannel] {
        let disabled = entity == nil || entity?.isProblemState == true
        let temperatureColor = Color(hue: (1 - min(1, max(0, (target - 16) / 14))) * 0.65, saturation: 0.8, brightness: 1)
        var result = [
            // Shown clamped into the range, never written back: only a turn sends.
            RotaryChannel(id: "target", label: "TARGET", value: min(range.upperBound, max(range.lowerBound, target)),
                minimum: range.lowerBound, maximum: range.upperBound, step: 0.5,
                color: temperatureColor, disabled: disabled, text: { Self.faceText($0) }),
            RotaryChannel(id: "power", label: "POWER", value: Double(modes.firstIndex(of: mode) ?? modes.count - 1),
                maximum: Double(modes.count - 1), kind: .selector, color: store.theme.accent.color,
                disabled: disabled, text: { modes[Int($0)].uppercased() })
        ]
        if !bedroom {
            result.append(RotaryChannel(id: "mode", label: "MODE", value: Double(directions.firstIndex(of: entity?.state ?? "") ?? 0),
                maximum: Double(max(0, directions.count - 1)), kind: .selector, color: temperatureColor,
                hidden: mode != "manual", disabled: disabled, ring: true,
                text: { directions.isEmpty ? "—" : directions[Int($0)].replacingOccurrences(of: "_only", with: "").uppercased() }))
            result.append(RotaryChannel(id: "fan", label: "FAN",
                value: Double(airconFanSteps.firstIndex(of: devices.turboSwitch?.isOn == true ? "turbo" :
                    devices.quietSwitch?.isOn == true ? "quiet" : entity?.fanMode ?? "medium") ?? 3),
                maximum: Double(airconFanSteps.count - 1), kind: .selector, color: .cyan,
                hidden: mode != "manual", disabled: disabled, ring: true,
                text: { airconFanSteps[Int($0)].uppercased() }))
            if let fresh = devices.freshAirSwitch {
                result.append(RotaryChannel(id: "fresh", label: "AIR", value: fresh.isOn ? 1 : 0, maximum: 1,
                    kind: .toggle, color: .green, hidden: mode != "manual", disabled: fresh.isProblemState,
                    ring: true, text: { $0 == 1 ? "FRESH" : "RECIRCULATE" }))
            }
        }
        result.append(RotaryChannel(id: "timer", label: "SLEEP TIMER", value: timerMinutes, maximum: 480, step: 15,
            color: store.theme.accent.color, hidden: mode == "off", disabled: disabled, ring: true,
            text: TimerEncoderScale.text))
        return result
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(bedroom ? "BEDROOM HEATER" : "AIR CONDITIONER").font(.novaDisplay(compact ? 17 : 26))
            RotaryEncoder(title: bedroom ? "HEATER" : "AIRCON",
                subtitle: Self.faceText(roomTemperature),
                channels: channels, initialChannel: "target", size: compact ? 110 : 200, compact: compact,
                bezelColors: [.orange, .red, .blue.opacity(0.5), .orange],
                ledLabels: modes, ledChannel: "power", faceChannel: "target", faceDecimals: true, focus: focus,
                focusValue: .action(compact ? "__quick" : zone.id, bedroom ? "heater-dial" : "aircon-dial"),
                editingFocus: $editingFocus, editMove: editMove, editCancel: editCancel, onCommit: commit)
            Text(entity?.isProblemState == true ? "DEVICE UNAVAILABLE" : mode.uppercased())
                .font(.novaMono(14)).foregroundStyle(store.theme.muted)
        }.padding(compact ? 6 : 20).frame(width: compact ? 220 : 410)
    }

    private func commit(_ changes: [String: Double]) {
        Task {
            var intent: [String: Any] = ["room": bedroom ? "bedroom" : "lounge"]
            if let power = changes["power"] {
                let next = modes[Int(power)]
                intent["mode"] = next
                if next == "off" { intent["offTimerEndsAt"] = NSNull() }
            }
            if let target = changes["target"] { intent["temperature"] = target }
            if let direction = changes["mode"], directions.indices.contains(Int(direction)) {
                intent["direction"] = directions[Int(direction)]
            }
            if let timer = changes["timer"], intent["mode"] as? String != "off" {
                intent["offTimerEndsAt"] = TimerEncoderScale.deadline(timer)
            }
            if intent.count > 1 { await store.sendEncoderCommand(path: "api/climate-control", body: intent) }
            if let fresh = changes["fresh"], let device = devices.freshAirSwitch {
                await store.sendEntityAction(entityID: device.entityID, domain: "switch",
                    service: fresh == 1 ? "turn_on" : "turn_off", toast: "Air circulation", selectedZoneID: zone.id)
            }
            if let fan = changes["fan"], let entity {
                let step = airconFanSteps[Int(fan)]
                let fanMode = step == "quiet" ? "low" : step == "turbo" ? "high" : step
                var actions: [EntityCommand] = []
                for (device, enabled) in [(devices.quietSwitch, step == "quiet"), (devices.turboSwitch, step == "turbo")] {
                    if let device { actions.append(EntityCommand(entityID: device.entityID, domain: "switch", service: enabled ? "turn_on" : "turn_off")) }
                }
                actions.append(EntityCommand(entityID: entity.entityID, domain: "climate", service: "set_fan_mode",
                    data: ["fan_mode": fanMode], remember: ["aircon": ["fanMode": fanMode, "quietMode": step == "quiet", "turboMode": step == "turbo"]]))
                await store.sendEntityActions(actions, toast: "Fan " + step, selectedZoneID: zone.id)
            }
        }
    }
}
