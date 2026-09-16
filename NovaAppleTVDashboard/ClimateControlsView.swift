import SwiftUI

// Climate surfaces and their command logic. Mirrors the web dashboard's
// ClimateControls: an air conditioner panel (power Auto/Manual/Off, mode
// Heat/Fan/Cool, fresh-air switch, temperature stepper, fan speed) and a panel
// heater (power + temperature). Command semantics and the remembered-preference
// payloads are copied from the web client so both clients drive Home Assistant
// identically.

// MARK: - Layout constants

// Square climate button grid sizing (power / mode / heater on-off).
private let climateButtonSize: CGFloat = 110
private let climateButtonGap: CGFloat = 12

/// Ordered fan steps from quietest to strongest. "quiet"/"turbo" are the
/// dedicated switches; the middle values map to native fan modes.
let airconFanSteps = ["quiet", "low", "medium low", "medium", "medium high", "high", "turbo"]

// MARK: - Device resolution

/// Resolves the climate zone's entities into named roles by fuzzy-matching the
/// HA entity name/id (the zone bundles them as an undifferentiated list). The
/// heater is matched first so the air conditioner is "the other climate entity".
struct ClimateDevices {
    let aircon: DashboardEntity?
    let heater: DashboardEntity?
    let freshAirSwitch: DashboardEntity?
    let quietSwitch: DashboardEntity?
    let turboSwitch: DashboardEntity?

    init(zone: DashboardZone) {
        let climates = zone.climateEntities
        let switches = zone.switchEntities
        let matchedHeater = climates.first { entityMatches($0, words: ["panel", "heater"]) || $0.entityID.contains("panel_heater") }
        heater = matchedHeater
        aircon = climates.first { entityMatches($0, words: ["air conditioner", "air con", "c6780cad"]) } ?? climates.first { $0.entityID != matchedHeater?.entityID }
        freshAirSwitch = switches.first { entityMatches($0, words: ["fresh"]) }
        quietSwitch = switches.first { entityMatches($0, words: ["quiet"]) }
        turboSwitch = switches.first { entityMatches($0, words: ["xtra", "turbo"]) }
    }
}

// MARK: - Top-level climate layout

/// The expanded Climate zone: the air conditioner panel beside the panel heater.
struct ClimateExpandedControls: View {
    let zone: DashboardZone
    let state: DashboardState
    var focus: FocusState<DashboardFocus?>.Binding
    @Binding var editingFocus: DashboardFocus?
    let editMove: DashboardEditMove?
    let editCancel: DashboardEditCancel?

    var devices: ClimateDevices {
        ClimateDevices(zone: zone)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            AirConditionerPanel(
                zoneID: zone.id,
                aircon: devices.aircon,
                freshAirSwitch: devices.freshAirSwitch,
                quietSwitch: devices.quietSwitch,
                turboSwitch: devices.turboSwitch,
                preferences: state.preferences?.aircon,
                controlState: state.climateControl?.lounge,
                focus: focus,
                editingFocus: $editingFocus,
                editMove: editMove,
                editCancel: editCancel
            )
            PanelHeaterPanel(zoneID: zone.id, heater: devices.heater, focus: focus)
        }
        .frame(maxHeight: .infinity)
    }
}

/// Shared header for a climate device panel: device title plus its raw HA state
/// (highlighted when the state is a problem state).
struct ClimateHeader: View {
    @EnvironmentObject private var store: DashboardStore
    let title: String
    let entity: DashboardEntity?

    var body: some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.novaDisplay(26))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Spacer()
            Text(entity?.state.uppercased() ?? "MISSING")
                .font(.novaMono(12))
                .foregroundStyle(entity?.isProblemState == true ? store.theme.highlight.color : store.theme.accent.color)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .overlay {
                    Rectangle().stroke(store.theme.borderColor, lineWidth: 1)
                }
        }
    }
}

// MARK: - Air conditioner

/// The air conditioner control surface. Sub-control groups flow left→right
/// inside one bordered panel: a 2×2 power/mode button grid, the fresh-air
/// toggle, the temperature stepper, and the fan-speed dot column. Everything but
/// the readouts is disabled (dimmed) when the unit is off and not in Auto.
struct AirConditionerPanel: View {
    let zoneID: String
    let aircon: DashboardEntity?
    let freshAirSwitch: DashboardEntity?
    let quietSwitch: DashboardEntity?
    let turboSwitch: DashboardEntity?
    let preferences: AirconPreferences?
    let controlState: ClimateControlRoomState?
    var focus: FocusState<DashboardFocus?>.Binding
    @Binding var editingFocus: DashboardFocus?
    let editMove: DashboardEditMove?
    let editCancel: DashboardEditCancel?

    private var isAutoActive: Bool {
        preferences?.autoMode == true
    }

    var body: some View {
        PanelFrame(title: "AIR CONTROL") {
            ClimateHeader(title: "AIR CONDITIONER", entity: aircon)

            if let aircon {
                if controlState?.owner == "external" {
                    Text("MANUAL — DEVICE OVERRIDE. NOVA AUTOMATION PAUSED.")
                        .font(.novaMono(12))
                        .foregroundStyle(Color.yellow)
                } else if controlState?.phase == "grace" {
                    Text("WAITING FOR TEMPERATURE — AUTO STOPS AFTER TWO MINUTES")
                        .font(.novaMono(12))
                        .foregroundStyle(Color.cyan)
                }
                let isControlOn = aircon.isOn || isAutoActive
                // Sub-control groups flow left->right inside the one bounding
                // rect; each icon menu is a vertical square stack (top = old
                // left-most), sliders are rotated vertical.
                HStack(alignment: .top, spacing: 16) {
                    // Power (Auto/Manual/Off) + mode (Heat/Fan/Cool) as a square
                    // 2-column button grid with equal vertical & horizontal gaps.
                    HStack(alignment: .top, spacing: climateButtonGap) {
                        VStack(spacing: climateButtonGap) {
                            AirconPowerButton(zoneID: zoneID, entity: aircon, state: .auto, preferences: preferences, controlState: controlState, focus: focus)
                                .frame(width: climateButtonSize, height: climateButtonSize)
                            AirconPowerButton(zoneID: zoneID, entity: aircon, state: .manual, preferences: preferences, controlState: controlState, focus: focus)
                                .frame(width: climateButtonSize, height: climateButtonSize)
                            AirconPowerButton(zoneID: zoneID, entity: aircon, state: .off, preferences: preferences, controlState: controlState, focus: focus)
                                .frame(width: climateButtonSize, height: climateButtonSize)
                        }
                        VStack(spacing: climateButtonGap) {
                            ClimateModeButton(zoneID: zoneID, entity: aircon, mode: "heat", label: "HEATING", symbol: "flame.fill", focus: focus, preferences: preferences)
                                .frame(width: climateButtonSize, height: climateButtonSize)
                            ClimateModeButton(zoneID: zoneID, entity: aircon, mode: "fan_only", label: "FAN", symbol: "fan.fill", focus: focus, preferences: preferences)
                                .frame(width: climateButtonSize, height: climateButtonSize)
                            // Dry only where the unit has it natively (web parity:
                            // specs/temperature-encoder.md round 2). Emulated Dry
                            // needs the server's dryEmulatable flag, not read here.
                            if aircon.hvacModes.contains("dry") {
                                ClimateModeButton(zoneID: zoneID, entity: aircon, mode: "dry", label: "DRY", symbol: "drop.fill", focus: focus, preferences: preferences)
                                    .frame(width: climateButtonSize, height: climateButtonSize)
                            }
                            ClimateModeButton(zoneID: zoneID, entity: aircon, mode: "cool", label: "COOLING", symbol: "snowflake", focus: focus, preferences: preferences)
                                .frame(width: climateButtonSize, height: climateButtonSize)
                        }
                    }

                    if let freshAirSwitch {
                        ClimateSwitchRow(
                            zoneID: zoneID,
                            entity: freshAirSwitch,
                            left: "RECIRCULATE",
                            right: "FRESH",
                            isEnabled: isControlOn,
                            focus: focus
                        )
                        .frame(width: 124).frame(maxHeight: .infinity)
                    }

                    ClimateTemperatureSection(
                        zoneID: zoneID,
                        entity: aircon,
                        label: "TEMPERATURE",
                        step: aircon.attributes["target_temp_step"]?.doubleValue ?? 1,
                        isEnabled: isControlOn,
                        rememberAirconPreference: true,
                        focus: focus
                    )
                    .frame(width: 172).frame(maxHeight: .infinity)

                    AirconFanSpeedControl(
                        zoneID: zoneID,
                        entity: aircon,
                        quietSwitch: quietSwitch,
                        turboSwitch: turboSwitch,
                        isEnabled: isControlOn,
                        focus: focus,
                        editingFocus: $editingFocus,
                        editMove: editMove,
                        editCancel: editCancel
                    )
                    .frame(width: 150).frame(maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            } else {
                EmptyStatePanel(title: "AIRCON MISSING", detail: "No air conditioner climate entity is present in this zone.")
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// The three mutually-exclusive air conditioner power states.
enum AirconPowerState: String, Equatable {
    case auto
    case manual
    case off

    var focusID: String { "aircon-\(rawValue)" }

    var title: String {
        switch self {
        case .auto: return "AUTO"
        case .manual: return "MANUAL"
        case .off: return "OFF"
        }
    }

    var symbol: String {
        switch self {
        case .auto: return "gauge.with.dots.needle.50percent"
        case .manual: return "power"
        case .off: return "power"
        }
    }
}

/// One air conditioner power-state button (Auto / Manual / Off). Auto is hidden-
/// disabled when the unit cannot heat AND cool. Each state sends the matching
/// service calls plus the remembered-preference payload the web client uses.
struct AirconPowerButton: View {
    @EnvironmentObject private var store: DashboardStore
    let zoneID: String
    let entity: DashboardEntity
    let state: AirconPowerState
    let preferences: AirconPreferences?
    let controlState: ClimateControlRoomState?
    var focus: FocusState<DashboardFocus?>.Binding

    private var active: Bool {
        if let mode = controlState?.mode { return mode == state.rawValue }
        switch state {
        case .auto:
            return preferences?.autoMode == true
        case .manual:
            return preferences?.autoMode != true && entity.isOn
        case .off:
            return preferences?.autoMode != true && !entity.isOn
        }
    }

    private var supported: Bool {
        if state != .auto { return true }
        return entity.hvacModes.isEmpty || (entity.hvacModes.contains("heat") && entity.hvacModes.contains("cool"))
    }

    var body: some View {
        ControlButton(title: state.title, symbol: state.symbol, isFocused: focus.wrappedValue == .action(zoneID, state.focusID), isActive: active) {
            guard supported else { return }
            Task { await sendPowerState() }
        }
        .dashboardFocus(focus, equals: .action(zoneID, state.focusID))
        .focusEffectDisabled()
        .opacity(supported ? 1 : 0.34)
    }

    private func sendPowerState() async {
        switch state {
        case .auto:
            let temperature = preferences?.temperature ?? entity.targetTemperature ?? entity.currentTemperature
            var airconRemember: [String: Any] = [
                "autoMode": true,
                "hvacMode": preferredManualMode(entity: entity, preferred: preferences?.hvacMode)
            ]
            if let temperature {
                airconRemember["temperature"] = temperature
            }
            var data: [String: Any] = [:]
            if let temperature {
                data["temperature"] = temperature
            }
            await store.sendEntityAction(
                entityID: entity.entityID,
                domain: "climate",
                service: temperature == nil ? "turn_on" : "set_temperature",
                data: data,
                remember: ["aircon": airconRemember],
                toast: "Air Conditioner Auto",
                selectedZoneID: zoneID
            )
        case .manual:
            let mode = preferredManualMode(entity: entity, preferred: preferences?.hvacMode)
            var actions = [
                EntityCommand(
                    entityID: entity.entityID,
                    domain: "climate",
                    service: "set_hvac_mode",
                    data: ["hvac_mode": mode],
                    remember: ["aircon": ["autoMode": false, "hvacMode": mode]]
                )
            ]
            if let temperature = preferences?.temperature ?? entity.targetTemperature {
                actions.append(
                    EntityCommand(
                        entityID: entity.entityID,
                        domain: "climate",
                        service: "set_temperature",
                        data: ["temperature": temperature],
                        remember: ["aircon": ["autoMode": false, "temperature": temperature]]
                    )
                )
            }
            await store.sendEntityActions(actions, toast: "Air Conditioner manual", selectedZoneID: zoneID)
        case .off:
            await store.sendEntityAction(
                entityID: entity.entityID,
                domain: "climate",
                service: "turn_off",
                remember: ["aircon": ["autoMode": false]],
                toast: "Air Conditioner off",
                selectedZoneID: zoneID
            )
        }
    }
}

/// One air conditioner HVAC-mode button (Heat / Fan / Cool). Hidden-disabled
/// when the unit does not advertise the mode; active only in manual mode.
struct ClimateModeButton: View {
    @EnvironmentObject private var store: DashboardStore
    let zoneID: String
    let entity: DashboardEntity
    let mode: String
    let label: String
    let symbol: String
    var focus: FocusState<DashboardFocus?>.Binding
    let preferences: AirconPreferences?

    var active: Bool {
        preferences?.autoMode != true && entity.state == mode
    }

    var supported: Bool {
        entity.hvacModes.isEmpty || entity.hvacModes.contains(mode)
    }

    var body: some View {
        ControlButton(title: label, symbol: symbol, isFocused: focus.wrappedValue == .action(zoneID, "mode-\(mode)"), isActive: active) {
            guard supported else { return }
            Task {
                await store.sendEntityAction(
                    entityID: entity.entityID,
                    domain: "climate",
                    service: "set_hvac_mode",
                    data: ["hvac_mode": mode],
                    remember: ["aircon": ["autoMode": false, "hvacMode": mode]],
                    toast: "Air Conditioner \(label)",
                    selectedZoneID: zoneID
                )
            }
        }
        .dashboardFocus(focus, equals: .action(zoneID, "mode-\(mode)"))
        .focusEffectDisabled()
        .opacity(supported ? 1 : 0.34)
    }
}

// MARK: - Temperature

/// Temperature direction for stepper focus ids — shared with the focus graph.
enum ClimateTemperatureDirection {
    case down
    case up
}

/// Stable focus id for a climate temperature stepper button. Defined once so the
/// focus graph and the control agree on the id.
func climateTemperatureActionID(entityID: String, direction: ClimateTemperatureDirection) -> String {
    switch direction {
    case .down:
        return "temperature-down-\(entityID)"
    case .up:
        return "temperature-up-\(entityID)"
    }
}

/// Target/current temperature readouts plus a vertical +/- stepper. Steps are
/// snapped to the device's `target_temp_step` and clamped to its min/max. The
/// air conditioner remembers its target as a preference; the heater does not.
struct ClimateTemperatureSection: View {
    @EnvironmentObject private var store: DashboardStore
    let zoneID: String
    let entity: DashboardEntity
    let label: String
    let step: Double
    let isEnabled: Bool
    let rememberAirconPreference: Bool
    var focus: FocusState<DashboardFocus?>.Binding
    @State private var draft = 20.0

    private var decreaseFocus: DashboardFocus {
        .action(zoneID, climateTemperatureActionID(entityID: entity.entityID, direction: .down))
    }

    private var increaseFocus: DashboardFocus {
        .action(zoneID, climateTemperatureActionID(entityID: entity.entityID, direction: .up))
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text(label)
                    .font(.novaMono(13))
                    .foregroundStyle(store.theme.muted)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(climateTemperatureDisplay(draft))
                        .font(.novaMono(58))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                    Text("\u{00B0}")
                        .font(.novaMono(34))
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("CURRENT")
                        .font(.novaMono(12))
                        .foregroundStyle(store.theme.muted)
                    Text(climateTemperatureDisplay(entity.currentTemperature))
                        .font(.novaMono(16))
                        .monospacedDigit()
                    Text("\u{00B0}")
                        .font(.novaMono(13))
                }
            }

            // Stepper rotated vertical: + on top, - on the bottom.
            VStack(spacing: 12) {
                IconControlButton(symbol: "plus", focus: focus, focusValue: increaseFocus, isFocused: focus.wrappedValue == increaseFocus, isActive: false) {
                    nudge(abs(step))
                }
                .frame(maxHeight: .infinity)

                IconControlButton(symbol: "minus", focus: focus, focusValue: decreaseFocus, isFocused: focus.wrappedValue == decreaseFocus, isActive: false) {
                    nudge(-abs(step))
                }
                .frame(maxHeight: .infinity)
            }
            .opacity(isEnabled ? 1 : 0.48)
            .frame(maxHeight: .infinity)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(store.theme.panelSoft.color.opacity(0.28))
        .overlay {
            Rectangle().stroke(store.theme.borderColor, lineWidth: 1)
        }
        .onAppear { draft = entity.targetTemperature ?? entity.currentTemperature ?? 20 }
        .onChange(of: entity.targetTemperature) { _, next in
            draft = next ?? entity.currentTemperature ?? 20
        }
        .onChange(of: entity.currentTemperature) { _, next in
            if entity.targetTemperature == nil {
                draft = next ?? 20
            }
        }
    }

    private func nudge(_ delta: Double) {
        guard isEnabled else { return }
        let next = temperatureDelta(entity: entity, delta: delta, step: step, base: draft)
        let remember: [String: Any]? = rememberAirconPreference ? ["aircon": ["temperature": next]] : nil
        draft = next
        Task {
            await store.sendEntityAction(
                entityID: entity.entityID,
                domain: "climate",
                service: "set_temperature",
                data: ["temperature": next],
                remember: remember,
                toast: "\(entity.name) \(climateTemperatureDisplay(next)) degrees",
                selectedZoneID: zoneID
            )
        }
    }
}

// MARK: - Fresh-air switch

/// The aircon recirculate/fresh-air toggle — a thin wrapper over the shared
/// `VerticalToggleSwitch` that supplies the entity-toggle command. The indicator
/// rests at the bottom (FRESH) when on.
struct ClimateSwitchRow: View {
    @EnvironmentObject private var store: DashboardStore
    let zoneID: String
    let entity: DashboardEntity
    let left: String
    let right: String
    let isEnabled: Bool
    var focus: FocusState<DashboardFocus?>.Binding

    private var isOn: Bool {
        entity.state == "on"
    }

    var body: some View {
        VerticalToggleSwitch(
            topLabel: left,
            bottomLabel: right,
            isOn: isOn,
            indicatorAtTopWhenOn: false,
            isFocused: focus.wrappedValue == .action(zoneID, entity.entityID),
            isEnabled: isEnabled,
            focus: focus,
            focusValue: .action(zoneID, entity.entityID)
        ) {
            Task {
                await store.sendEntityAction(
                    entityID: entity.entityID,
                    domain: "switch",
                    service: isOn ? "turn_off" : "turn_on",
                    toast: "\(entity.name) \(isOn ? "off" : "on")",
                    selectedZoneID: zoneID
                )
            }
        }
    }
}

// MARK: - Fan speed

/// Fan-speed selector: a vertical dot column (TURBO at top, QUIET at bottom).
/// Select enters edit mode; up/down step the draft; Select commits, which
/// reconciles the quiet/turbo switches and sets the native fan mode in one
/// batch, with the remembered-preference payload.
struct AirconFanSpeedControl: View {
    @EnvironmentObject private var store: DashboardStore
    let zoneID: String
    let entity: DashboardEntity
    let quietSwitch: DashboardEntity?
    let turboSwitch: DashboardEntity?
    let isEnabled: Bool
    var focus: FocusState<DashboardFocus?>.Binding
    @Binding var editingFocus: DashboardFocus?
    let editMove: DashboardEditMove?
    let editCancel: DashboardEditCancel?
    @State private var draftIndex = 0
    @State private var isEditing = false

    private var thisFocus: DashboardFocus {
        .fanSpeed(zoneID, entity.entityID)
    }

    private var currentIndex: Int {
        airconFanSteps.firstIndex(of: airconFanStep(entity: entity, quietSwitch: quietSwitch, turboSwitch: turboSwitch)) ?? 0
    }

    private var draftLabel: String {
        airconFanSteps[min(max(draftIndex, 0), airconFanSteps.count - 1)].uppercased()
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("FAN SPEED")
                    .font(.novaMono(13))
                    .foregroundStyle(store.theme.muted)
                Text(draftLabel)
                    .font(.novaMono(15))
            }

            Text("TURBO")
                .font(.novaMono(13))
                .foregroundStyle(store.theme.muted)

            FanSpeedDots(index: draftIndex, count: airconFanSteps.count, isEditing: isEditing)
                .frame(maxHeight: .infinity)

            Text("QUIET")
                .font(.novaMono(13))
                .foregroundStyle(store.theme.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .controlChrome(isFocused: focus.wrappedValue == thisFocus, isActive: isEditing)
        .opacity(isEnabled ? 1 : 0.48)
        .dashboardTapTarget(focus, equals: thisFocus, perform: activate)
        .onAppear { draftIndex = currentIndex }
        .onChange(of: currentIndex) { _, next in
            if !isEditing {
                draftIndex = next
            }
        }
        .onChange(of: editingFocus) { _, next in
            if isEditing && next != thisFocus {
                isEditing = false
            }
        }
        .onDisappear {
            if editingFocus == thisFocus {
                editingFocus = nil
            }
        }
        .onChange(of: editMove) { _, move in
            guard isEditing,
                  move?.focus == thisFocus,
                  let direction = move?.direction
            else { return }
            // Vertical dot column: TURBO at top, QUIET at bottom, so up steps
            // toward TURBO, down toward QUIET. Cross-axis input is ignored.
            switch direction {
            case .up:
                draftIndex = min(airconFanSteps.count - 1, draftIndex + 1)
            case .down:
                draftIndex = max(0, draftIndex - 1)
            case .left, .right:
                return
            }
        }
        .onChange(of: editCancel) { _, cancel in
            guard cancel?.focus == thisFocus else { return }
            draftIndex = currentIndex
            isEditing = false
            debugInteractionLog("edit restore focus=\(thisFocus)")
        }
    }

    private func activate() {
        guard isEnabled else { return }
        if isEditing {
            commit()
        } else {
            draftIndex = currentIndex
            focus.wrappedValue = thisFocus
            editingFocus = thisFocus
            isEditing = true
            debugInteractionLog("edit enter focus=\(thisFocus)")
        }
    }

    private func commit() {
        let step = airconFanSteps[min(max(draftIndex, 0), airconFanSteps.count - 1)]
        let fanMode = airconFanServiceValue(step)
        var actions: [EntityCommand] = []
        let remember: [String: Any] = [
            "aircon": [
                "autoMode": false,
                "fanMode": fanMode,
                "quietMode": step == "quiet",
                "turboMode": step == "turbo"
            ]
        ]

        if let quietSwitch, (quietSwitch.state == "on") != (step == "quiet") {
            actions.append(EntityCommand(entityID: quietSwitch.entityID, domain: "switch", service: step == "quiet" ? "turn_on" : "turn_off"))
        }
        if let turboSwitch, (turboSwitch.state == "on") != (step == "turbo") {
            actions.append(EntityCommand(entityID: turboSwitch.entityID, domain: "switch", service: step == "turbo" ? "turn_on" : "turn_off"))
        }
        actions.append(EntityCommand(entityID: entity.entityID, domain: "climate", service: "set_fan_mode", data: ["fan_mode": fanMode], remember: remember))

        Task {
            await store.sendEntityActions(actions, toast: "Air Conditioner fan \(step)", selectedZoneID: zoneID)
        }

        editingFocus = nil
        isEditing = false
        debugInteractionLog("edit confirm focus=\(thisFocus)")
    }
}

/// The vertical dot column for `AirconFanSpeedControl`. Rendered top→bottom from
/// the strongest step (TURBO) to the weakest (QUIET); the selected dot is larger
/// and accent-filled.
struct FanSpeedDots: View {
    @EnvironmentObject private var store: DashboardStore
    let index: Int
    let count: Int
    let isEditing: Bool

    var body: some View {
        VStack(spacing: 13) {
            // Rendered top-to-bottom from highest (TURBO) to lowest (QUIET).
            ForEach(Array((0..<count).reversed()), id: \.self) { dot in
                Circle()
                    .fill(dot == index ? store.theme.accent.color : store.theme.text.opacity(0.72))
                    .overlay {
                        Circle().stroke(store.theme.borderColor, lineWidth: dot == index && isEditing ? 2 : 1)
                    }
                    .frame(width: dot == index ? 13 : 7, height: dot == index ? 13 : 7)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: .infinity, alignment: .center)
    }
}

// MARK: - Panel heater

/// The panel heater control surface: ON/OFF buttons stacked beside a temperature
/// stepper (which does not remember a preference).
struct PanelHeaterPanel: View {
    @EnvironmentObject private var store: DashboardStore
    let zoneID: String
    let heater: DashboardEntity?
    var focus: FocusState<DashboardFocus?>.Binding

    var body: some View {
        PanelFrame(title: "HEATING UNIT") {
            ClimateHeader(title: "PANEL HEATER", entity: heater)

            if let heater {
                let isOn = heater.isOn
                HStack(alignment: .top, spacing: 16) {
                    // ON (top) / OFF (bottom) as two stacked square buttons.
                    VStack(spacing: climateButtonGap) {
                        ControlButton(title: "ON", symbol: "power", isFocused: focus.wrappedValue == .action(zoneID, "heater-on"), isActive: isOn) {
                            Task {
                                await store.sendEntityAction(
                                    entityID: heater.entityID,
                                    domain: "climate",
                                    service: "turn_on",
                                    toast: "Panel Heater on",
                                    selectedZoneID: zoneID
                                )
                            }
                        }
                        .dashboardFocus(focus, equals: .action(zoneID, "heater-on"))
                        .focusEffectDisabled()
                        .frame(width: climateButtonSize, height: climateButtonSize)

                        ControlButton(title: "OFF", symbol: "power", isFocused: focus.wrappedValue == .action(zoneID, "heater-off"), isActive: !isOn) {
                            Task {
                                await store.sendEntityAction(
                                    entityID: heater.entityID,
                                    domain: "climate",
                                    service: "turn_off",
                                    toast: "Panel Heater off",
                                    selectedZoneID: zoneID
                                )
                            }
                        }
                        .dashboardFocus(focus, equals: .action(zoneID, "heater-off"))
                        .focusEffectDisabled()
                        .frame(width: climateButtonSize, height: climateButtonSize)
                    }

                    ClimateTemperatureSection(
                        zoneID: zoneID,
                        entity: heater,
                        label: "TEMPERATURE",
                        step: heater.attributes["target_temp_step"]?.doubleValue ?? 1,
                        isEnabled: isOn,
                        rememberAirconPreference: false,
                        focus: focus
                    )
                    .frame(width: 172).frame(maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            } else {
                EmptyStatePanel(title: "PANEL HEATER MISSING", detail: "The second climate device is not present in the current API state.")
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Climate logic helpers

/// The current fan step inferred from the dedicated quiet/turbo switches and the
/// native fan mode (defaulting to medium).
private func airconFanStep(entity: DashboardEntity, quietSwitch: DashboardEntity?, turboSwitch: DashboardEntity?) -> String {
    if quietSwitch?.state == "on" {
        return "quiet"
    }
    if turboSwitch?.state == "on" {
        return "turbo"
    }

    let mode = (entity.fanMode ?? "").lowercased()
    if airconFanSteps.contains(mode), mode != "quiet", mode != "turbo" {
        return mode
    }
    return "medium"
}

/// The native `set_fan_mode` value for a step ("quiet"/"turbo" ride their
/// switches, so the climate entity itself takes low/high respectively).
private func airconFanServiceValue(_ step: String) -> String {
    if step == "quiet" { return "low" }
    if step == "turbo" { return "high" }
    return step
}

/// The HVAC mode to use when switching to Manual/Auto: the remembered preference
/// if the unit supports it, else the current mode, else the first real mode.
private func preferredManualMode(entity: DashboardEntity, preferred: String? = nil) -> String {
    if let preferred,
       ["heat", "cool", "dry", "fan_only"].contains(preferred),
       entity.hvacModes.isEmpty || entity.hvacModes.contains(preferred) {
        return preferred
    }
    if ["heat", "cool", "dry", "fan_only"].contains(entity.state) {
        return entity.state
    }
    return entity.hvacModes.first { !["off", "unavailable", "unknown", "auto"].contains($0) } ?? "heat"
}

/// Whether any of `words` appears in the entity's name or id (case-insensitive),
/// used by `ClimateDevices` to assign roles.
private func entityMatches(_ entity: DashboardEntity, words: [String]) -> Bool {
    let text = "\(entity.name) \(entity.entityID)".lowercased()
    return words.contains { text.contains($0.lowercased()) }
}

/// Round to the nearest multiple of `step` (with a 3-dp guard against binary
/// drift); never rounds to 0 step.
private func roundToStep(_ value: Double, step: Double) -> Double {
    let safeStep = max(0.1, abs(step))
    return ((value / safeStep).rounded() * safeStep * 1000).rounded() / 1000
}

/// Apply a temperature nudge: when already aligned to the step grid just add the
/// delta, otherwise snap to the next grid line in the nudge direction. Result is
/// clamped to the entity's min/max.
private func temperatureDelta(entity: DashboardEntity, delta: Double, step: Double, base: Double?) -> Double {
    let current = base ?? entity.targetTemperature ?? 20
    let increment = max(0.1, abs(step))
    let ratio = current / increment
    let aligned = abs(ratio - ratio.rounded()) < 0.0001
    let stepped: Double
    if aligned {
        stepped = current + delta
    } else if delta > 0 {
        stepped = ceil(ratio) * increment
    } else {
        stepped = floor(ratio) * increment
    }
    return min(entity.maximumTemperature, max(entity.minimumTemperature, roundToStep(stepped, step: increment)))
}
