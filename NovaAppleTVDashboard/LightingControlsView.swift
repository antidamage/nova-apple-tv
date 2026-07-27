import SwiftUI

// Lighting surfaces: the Home → room ribbon, the per-zone preset + brightness
// control panel, and the vertical brightness slider. These render whenever the
// expanded zone is the Home zone (rooms) or any other lighting-capable zone.

/// Second-level ribbon for the Home zone: a vertical column of room buttons
/// (HOME = all lights, then each room) with the selected room's control panel
/// growing in to the right.
struct LightingRibbon: View {
    let home: DashboardZone
    let state: DashboardState
    var focus: FocusState<DashboardFocus?>.Binding
    @Binding var expandedChildZoneID: String?
    @Binding var editingFocus: DashboardFocus?
    let editMove: DashboardEditMove?
    let editCancel: DashboardEditCancel?

    var childZones: [DashboardZone] {
        [home] + state.homeChildZones
    }

    var selectedZone: DashboardZone? {
        state.zone(id: expandedChildZoneID)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            // Sub-zone (room) buttons as a vertical column one step right.
            PanelFrame {
                VStack(spacing: 10) {
                    ForEach(childZones) { child in
                        RibbonTitleButton(
                            title: child.isHomeZone ? "HOME" : child.name.uppercased(),
                            subtitle: child.isHomeZone ? "ALL LIGHTS" : "\(child.lightCount) LIGHTS",
                            focus: focus,
                            focusValue: .child(child.id),
                            isFocused: focus.wrappedValue == .child(child.id),
                            isExpanded: expandedChildZoneID == child.id,
                            compact: true
                        ) {
                            let willExpand = expandedChildZoneID != child.id
                            if willExpand {
                                expandedChildZoneID = child.id
                            } else {
                                expandedChildZoneID = nil
                            }
                            let nextFocus = willExpand ? firstFocusInsideChildZone(child) ?? .child(child.id) : .child(child.id)
                            focus.wrappedValue = .child(child.id)
                            DispatchQueue.main.async {
                                focus.wrappedValue = nextFocus
                            }
                            debugInteractionLog("\(expandedChildZoneID == child.id ? "expanded" : "collapsed") child \(child.id)")
                        }
                        .frame(maxHeight: .infinity)
                    }
                }
                .frame(width: 210).frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)

            if let selectedZone {
                LightingControlPanel(zone: selectedZone, state: state, focus: focus, editingFocus: $editingFocus, editMove: editMove, editCancel: editCancel)
                    .frame(maxHeight: .infinity)
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// Preset action column (ON / CANDLE-or-DAY / WHITE / OFF) plus the vertical
/// brightness slider for a single lighting zone. CANDLE/DAY and WHITE send a
/// spectrum cursor + preview colour so the host reproduces the web presets
/// exactly; the label and warmth adapt to whether the sun is down.
struct LightingControlPanel: View {
    @EnvironmentObject private var store: DashboardStore
    let zone: DashboardZone
    let state: DashboardState
    var focus: FocusState<DashboardFocus?>.Binding
    @Binding var editingFocus: DashboardFocus?
    let editMove: DashboardEditMove?
    let editCancel: DashboardEditCancel?

    var body: some View {
        PanelFrame {
            HStack(alignment: .top, spacing: 14) {
                if zone.canUseLightingControls {
                    // Preset menu as a vertical square stack (ON at the top,
                    // matching its old left-most position).
                    VStack(spacing: 10) {
                        ControlButton(title: "ON", symbol: "power", isFocused: focus.wrappedValue == .action(zone.id, "on"), isActive: zone.isOn) {
                            Task { await store.sendLightGroupAction(zone: zone, action: .on) }
                        }
                        .dashboardFocus(focus, equals: .action(zone.id, "on"))
                        .focusEffectDisabled()
                        .frame(maxHeight: .infinity)

                        ControlButton(title: state.sun?.state == "below_horizon" ? "CANDLE" : "DAY", symbol: "flame.fill", isFocused: focus.wrappedValue == .action(zone.id, "candle")) {
                            let spectrum = adaptiveCandlelightSpectrum(sun: state.sun)
                            Task {
                                await store.sendLightGroupAction(
                                    zone: zone,
                                    action: .candlelight,
                                    brightnessPct: adaptiveCandlelightBrightness(sun: state.sun),
                                    cursor: spectrum.cursor,
                                    rgb: spectrum.preview
                                )
                            }
                        }
                        .dashboardFocus(focus, equals: .action(zone.id, "candle"))
                        .focusEffectDisabled()
                        .frame(maxHeight: .infinity)

                        ControlButton(title: "WHITE", symbol: "sun.max.fill", isFocused: focus.wrappedValue == .action(zone.id, "white")) {
                            Task {
                                await store.sendLightGroupAction(
                                    zone: zone,
                                    action: .white,
                                    brightnessPct: 100,
                                    cursor: whiteSpectrum.cursor,
                                    rgb: whiteSpectrum.preview
                                )
                            }
                        }
                        .dashboardFocus(focus, equals: .action(zone.id, "white"))
                        .focusEffectDisabled()
                        .frame(maxHeight: .infinity)

                        ControlButton(title: "OFF", symbol: "power", isFocused: focus.wrappedValue == .action(zone.id, "off")) {
                            Task { await store.sendLightGroupAction(zone: zone, action: .off) }
                        }
                        .dashboardFocus(focus, equals: .action(zone.id, "off"))
                        .focusEffectDisabled()
                        .frame(maxHeight: .infinity)
                    }
                    .frame(width: 130).frame(maxHeight: .infinity)

                    // Vertical brightness slider to the right of the buttons:
                    // 100% at the top, 0% at the bottom.
                    VerticalBrightnessSlider(zone: zone, focus: focus, editingFocus: $editingFocus, editMove: editMove, editCancel: editCancel)
                        .frame(maxHeight: .infinity)
                } else {
                    EmptyStatePanel(title: "NO LIGHT CONTROLS", detail: "This zone has no light entities.")
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }
}

// Percent change per remote swipe while editing the brightness slider. Larger =
// more responsive to swiping.
private let brightnessSwipeStep: Double = 5

/// Vertical brightness slider: the fill (and a highlight-colour thumb) rise from
/// the bottom (0%) to the top (100%). Focus it and press Select to edit, then
/// swipe up/down to change and Select again to apply (Menu cancels).
///
/// The editing handshake is shared by all the edit-capable controls: a local
/// `draft` tracks the in-progress value, `editingFocus` marks which control owns
/// the remote, and the serialized `editMove`/`editCancel` events (sent by the
/// root view) step or discard the draft.
struct VerticalBrightnessSlider: View {
    @EnvironmentObject private var store: DashboardStore
    let zone: DashboardZone
    var focus: FocusState<DashboardFocus?>.Binding
    @Binding var editingFocus: DashboardFocus?
    let editMove: DashboardEditMove?
    let editCancel: DashboardEditCancel?
    @State private var draft = 0.0
    @State private var isEditing = false

    private var thisFocus: DashboardFocus { .brightness(zone.id) }

    var body: some View {
        VStack(spacing: 10) {
            Text(isEditing ? "SET LEVEL" : "BRIGHTNESS")
                .font(.novaMono(12))
                .foregroundStyle(store.theme.muted)

            GeometryReader { proxy in
                let h = proxy.size.height
                let frac = clamped(draft / 100)
                let thumbH: CGFloat = 18
                let thumbOffset = min(max(h * CGFloat(frac) - thumbH, 0), max(0, h - thumbH))
                ZStack(alignment: .bottom) {
                    Rectangle()
                        .fill(store.theme.panelSoft.color.opacity(0.54))
                    Rectangle()
                        .fill(store.theme.accent.color)
                        .frame(height: h * CGFloat(frac))
                    // Thumb: highlight-colour box inset within the track borders.
                    Rectangle()
                        .fill(store.theme.highlight.color)
                        .frame(height: thumbH)
                        .padding(.horizontal, 4)
                        .offset(y: -thumbOffset)
                }
            }
            .frame(width: 30)
            .overlay {
                Rectangle().stroke(isEditing ? store.theme.highlight.color : store.theme.borderColor, lineWidth: isEditing ? 2 : 1)
            }

            Text("\(Int(draft.rounded()))%")
                .font(.novaMono(18))
                .monospacedDigit()
        }
        .frame(width: 96).frame(maxHeight: .infinity)
        .dashboardTapTarget(focus, equals: thisFocus, perform: activate)
        .onAppear { draft = zone.brightnessPct }
        .onChange(of: zone.brightnessPct) { _, next in
            if !isEditing { draft = next }
        }
        .onChange(of: editingFocus) { _, next in
            if isEditing && next != thisFocus { isEditing = false }
        }
        .onDisappear {
            if editingFocus == thisFocus { editingFocus = nil }
        }
        .onChange(of: editMove) { _, move in
            guard isEditing, move?.focus == thisFocus, let direction = move?.direction else { return }
            switch direction {
            case .up: draft += brightnessSwipeStep
            case .down: draft -= brightnessSwipeStep
            case .left, .right: return
            }
            draft = clamped(draft, 0, 100)
        }
        .onChange(of: editCancel) { _, cancel in
            guard cancel?.focus == thisFocus else { return }
            draft = zone.brightnessPct
            isEditing = false
            debugInteractionLog("edit restore focus=\(thisFocus)")
        }
    }

    private func activate() {
        if isEditing {
            let confirmed = draft
            Task { await store.sendLightGroupAction(zone: zone, action: .brightness, brightnessPct: confirmed) }
            editingFocus = nil
            isEditing = false
            debugInteractionLog("edit confirm focus=\(thisFocus)")
        } else {
            draft = zone.brightnessPct
            focus.wrappedValue = thisFocus
            editingFocus = thisFocus
            isEditing = true
            debugInteractionLog("edit enter focus=\(thisFocus)")
        }
    }
}
