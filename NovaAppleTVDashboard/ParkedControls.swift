import SwiftUI

// Parked controls — currently unused, retained on purpose.
//
// The hue grid (colour) and the horizontal brightness slider were pulled from
// the lighting surface because they never worked reliably with the remote; the
// lighting panel now ships only the preset row and the vertical brightness
// slider. These implementations are kept verbatim as the starting point for a
// future rework, NOT dead code to delete — `lightingFocusRows` deliberately no
// longer emits `.hue`/`.brightness(grid)` rows, so nothing references them yet.
//
// When the colour/brightness feature is reworked, restore the focus rows in
// DashboardFocus.swift and wire these (or their replacements) back into
// LightingControlPanel. `ProgressBar` lives here because it is currently used
// only by these parked controls.

/// A thin horizontal progress fill in the theme accent over a soft track.
struct ProgressBar: View {
    @EnvironmentObject private var store: DashboardStore
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(store.theme.panelSoft.color.opacity(0.54))
                Rectangle()
                    .fill(store.theme.accent.color)
                    .frame(width: proxy.size.width * CGFloat(clamped(value)))
            }
        }
        .frame(height: 8)
    }
}

/// PARKED: 2-D hue/saturation picker. Focus + Select to edit, swipe to move the
/// cursor across the spectrum, Select to apply the colour to the zone.
struct RemoteHueGrid: View {
    @EnvironmentObject private var store: DashboardStore
    let zoneID: String
    let zone: DashboardZone
    let value: SpectrumValue
    var focus: FocusState<DashboardFocus?>.Binding
    let isFocused: Bool
    @Binding var editingFocus: DashboardFocus?
    let editMove: DashboardEditMove?
    let editCancel: DashboardEditCancel?
    @State private var draft: SpectrumValue = candlelightSpectrum
    @State private var isEditing = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { proxy in
                HueGridCanvas()
                    .clipShape(Rectangle())

                Circle()
                    .stroke(store.theme.background.color, lineWidth: 5)
                    .background(Circle().fill(draft.preview.color))
                    .overlay(Circle().stroke(store.theme.accent.color, lineWidth: 2))
                    .frame(width: 32, height: 32)
                    .position(
                        x: CGFloat(draft.cursor.x) * proxy.size.width,
                        y: CGFloat(draft.cursor.y) * proxy.size.height
                    )
            }

            HStack {
                Text(isEditing ? "HUE EDIT" : "HUE GRID")
                    .font(.novaMono(14))
                Spacer()
                Circle()
                    .fill(draft.preview.color)
                    .frame(width: 18, height: 18)
            }
            .foregroundStyle(store.theme.text)
            .padding(12)
        }
        .frame(height: 116)
        .overlay {
            Rectangle()
                .stroke(isEditing ? store.theme.accent.color : isFocused ? store.theme.highlight.color : store.theme.borderColor, lineWidth: isEditing || isFocused ? 2 : 1)
        }
        .contentShape(Rectangle())
        .focusable(true)
        .dashboardFocus(focus, equals: .hue(zoneID))
        .focusEffectDisabled()
        .onTapGesture(perform: activate)
        .accessibilityAddTraits(.isButton)
        .onAppear { draft = value }
        .onChange(of: value) { _, next in
            if !isEditing {
                draft = next
            }
        }
        .onChange(of: editingFocus) { _, next in
            if isEditing && next != .hue(zoneID) {
                isEditing = false
            }
        }
        .onDisappear {
            if editingFocus == .hue(zoneID) {
                editingFocus = nil
            }
        }
        .onChange(of: editMove) { _, move in
            guard isEditing,
                  move?.focus == .hue(zoneID),
                  let direction = move?.direction
            else { return }
            var cursor = draft.cursor
            let step = 0.025
            switch direction {
            case .left: cursor.x -= step
            case .right: cursor.x += step
            case .up: cursor.y -= step
            case .down: cursor.y += step
            }
            cursor.x = clamped(cursor.x)
            cursor.y = clamped(cursor.y)
            draft = SpectrumValue(cursor: cursor, preview: spectrumRGBAtPosition(x: cursor.x, y: cursor.y))
        }
        .onChange(of: editCancel) { _, cancel in
            guard cancel?.focus == .hue(zoneID) else { return }
            draft = value
            isEditing = false
            debugInteractionLog("edit restore focus=\(DashboardFocus.hue(zoneID))")
        }
    }

    private func focusHue(_ thisFocus: DashboardFocus) {
        focus.wrappedValue = thisFocus
        editingFocus = thisFocus
    }

    private func activate() {
        let thisFocus = DashboardFocus.hue(zoneID)
        if isEditing {
            let confirmed = draft
            Task {
                await store.sendLightGroupAction(
                    zone: zone,
                    action: .color,
                    brightnessPct: store.selectedZone?.brightnessPct ?? zone.brightnessPct,
                    cursor: confirmed.cursor,
                    rgb: confirmed.preview
                )
            }
            editingFocus = nil
            isEditing = false
            debugInteractionLog("edit confirm focus=\(thisFocus)")
        } else {
            draft = value
            focusHue(thisFocus)
            isEditing = true
            debugInteractionLog("edit enter focus=\(thisFocus)")
        }
    }
}

/// PARKED: renders the spectrum into a `Canvas` grid behind `RemoteHueGrid`'s
/// cursor.
struct HueGridCanvas: View {
    var body: some View {
        Canvas { context, size in
            let columns = 46
            let rows = 14
            let cellWidth = size.width / CGFloat(columns)
            let cellHeight = size.height / CGFloat(rows)

            for column in 0..<columns {
                for row in 0..<rows {
                    let x = Double(column) / Double(columns - 1)
                    let y = Double(row) / Double(rows - 1)
                    let color = spectrumRGBAtPosition(x: x, y: y).color
                    context.fill(
                        Path(CGRect(x: CGFloat(column) * cellWidth, y: CGFloat(row) * cellHeight, width: cellWidth + 1, height: cellHeight + 1)),
                        with: .color(color)
                    )
                }
            }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.22)))
        }
    }
}

/// PARKED: horizontal brightness slider (the live UI uses the vertical
/// `VerticalBrightnessSlider` instead). Focus + Select to edit, swipe left/right
/// to change, Select to apply.
struct RemoteLinearSlider: View {
    @EnvironmentObject private var store: DashboardStore
    let zone: DashboardZone
    let value: Double
    var focus: FocusState<DashboardFocus?>.Binding
    let isFocused: Bool
    @Binding var editingFocus: DashboardFocus?
    let editMove: DashboardEditMove?
    let editCancel: DashboardEditCancel?
    @State private var draft = 0.0
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(isEditing ? "BRIGHTNESS EDIT" : "BRIGHTNESS")
                    .font(.novaMono(14))
                Spacer()
                Text("\(Int(draft.rounded()))%")
                    .font(.novaMono(18))
                    .monospacedDigit()
            }

            ProgressBar(value: draft / 100)
        }
        .padding(14)
        .controlChrome(isFocused: isFocused, isActive: isEditing)
        .contentShape(Rectangle())
        .focusable(true)
        .dashboardFocus(focus, equals: .brightness(zone.id))
        .focusEffectDisabled()
        .onTapGesture(perform: activate)
        .accessibilityAddTraits(.isButton)
        .onAppear { draft = value }
        .onChange(of: value) { _, next in
            if !isEditing {
                draft = next
            }
        }
        .onChange(of: editingFocus) { _, next in
            if isEditing && next != .brightness(zone.id) {
                isEditing = false
            }
        }
        .onDisappear {
            if editingFocus == .brightness(zone.id) {
                editingFocus = nil
            }
        }
        .onChange(of: editMove) { _, move in
            guard isEditing,
                  move?.focus == .brightness(zone.id),
                  let direction = move?.direction
            else { return }
            switch direction {
            case .left: draft -= 2
            case .right: draft += 2
            case .up, .down: return
            }
            draft = clamped(draft, 0, 100)
        }
        .onChange(of: editCancel) { _, cancel in
            guard cancel?.focus == .brightness(zone.id) else { return }
            draft = value
            isEditing = false
            debugInteractionLog("edit restore focus=\(DashboardFocus.brightness(zone.id))")
        }
    }

    private func activate() {
        let thisFocus = DashboardFocus.brightness(zone.id)
        if isEditing {
            let confirmed = draft
            Task {
                await store.sendLightGroupAction(zone: zone, action: .brightness, brightnessPct: confirmed)
            }
            editingFocus = nil
            isEditing = false
            debugInteractionLog("edit confirm focus=\(thisFocus)")
        } else {
            draft = value
            focus.wrappedValue = thisFocus
            editingFocus = thisFocus
            isEditing = true
            debugInteractionLog("edit enter focus=\(thisFocus)")
        }
    }
}
