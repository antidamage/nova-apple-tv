import SwiftUI

/// A domain supplied by a wrapper: face channels and outer rings share input,
/// preview, commit, accessibility and idle locking.
struct RotaryChannel {
    enum Kind { case slider, selector, toggle }
    let id: String
    let label: String
    var value: Double
    var minimum: Double = 0
    var maximum: Double = 100
    var step: Double = 1
    var wraps = false
    var kind: Kind = .slider
    var color: Color = .cyan
    var hidden = false
    var disabled = false
    var ring = false
    var text: (Double) -> String = { String(Int($0.rounded())) }

    var valueFraction: ((Double) -> Double)? = nil

    func stepped(_ value: Double, by direction: Double) -> Double {
        let next = value + step * direction
        if wraps {
            if next > maximum { return minimum }
            if next < minimum { return maximum }
        }
        return min(maximum, max(minimum, next))
    }
    func fraction(_ value: Double) -> Double {
        if let valueFraction { return min(1, max(0, valueFraction(value))) }
        return min(1, max(0, (value - minimum) / max(0.001, maximum - minimum)))
    }
}

/// The order a dial's left/right swipes walk, left to right: the ring sliders
/// first, outermost inward, then the face channels in the order they are drawn
/// — the mode lights, left to right. Swiping left off the left-most mode
/// therefore steps onto the rings and goes on moving outward, and both ends
/// hold: the outermost ring is the left terminus, the last mode the right one.
/// Adeline, 2026-09-20.
enum RotaryStepOrder {
    static func selectable(_ channels: [RotaryChannel]) -> [RotaryChannel] {
        let usable = channels.filter { !$0.hidden && !$0.disabled }
        return Array(usable.filter { $0.ring }.reversed()) + usable.filter { !$0.ring }
    }
}

struct RotaryEncoder: View {
    @EnvironmentObject private var store: DashboardStore
    @Environment(\.scenePhase) private var scenePhase
    let title: String
    var subtitle: String = ""
    var symbol: String? = nil
    let channels: [RotaryChannel]
    var initialChannel: String? = nil
    var size: CGFloat = 200
    var compact = false
    var bezelColors: [Color] = [Color(red: 0.58, green: 0.32, blue: 0.13), Color(red: 0.85, green: 0.61, blue: 0.37), Color(red: 0.58, green: 0.32, blue: 0.13)]
    var ledLabels: [String]? = nil
    var ledChannel: String? = nil
    var faceChannel: String? = nil
    var faceReadout: String? = nil
    var countdownFraction: Double? = nil
    /// Numbers on the face print as the web's temperature knob does: the
    /// decimal part half size along the top of the digits, at the web's sizes.
    var faceDecimals = false
    /// The phone sends a gesture's value on release, as the web does; a dial that
    /// only makes sense whole (the timer) sends on lock instead.
    var commitsOnRelease = true
    let focus: FocusState<DashboardFocus?>.Binding
    let focusValue: DashboardFocus
    @Binding var editingFocus: DashboardFocus?
    let editMove: DashboardEditMove?
    let editCancel: DashboardEditCancel?
    let onCommit: ([String: Double]) -> Void
    @State var draft: [String: Double] = [:]
    @State var original: [String: Double] = [:]
    @State var channelID = ""
    @State var touch = RotaryTouchState()
    /// True while a finger is on the unlocked dial; resets itself if the system
    /// cancels the gesture, which a plain flag would not.
    @GestureState var touchHeld = false
    /// Bumped on every accepted input while unlocked; the idle commit sleeps
    /// against it, so any move restarts the five-second lease.
    @State var activityBeat = 0

    var editing: Bool { editingFocus == focusValue }
    #if os(tvOS)
    private static let editingHint = "◀ ▶ CHANNEL   ▲ ▼ ADJUST   CLICK SAVE"
    private static let idleHint = "CLICK TO ADJUST"
    #else
    private static let editingHint = "TURN THE KNOB · TAP TO CYCLE · DRAG A RING"
    private static let idleHint = "TAP TO UNLOCK"
    private static let accessibilityHint = "Tap to unlock. Turn the knob to adjust, tap it to cycle, drag a ring's thumb. Tap elsewhere or wait five seconds to lock."
    #endif
    #if os(tvOS)
    private static let accessibilityHint = "Click to edit and click again to save. Left and right choose a channel or ring and stop at both ends. Up and down adjust. Back cancels; five seconds without input saves."
    #endif
    /// The ring drawn around the dial: the theme's unlock ring while the dial is
    /// unlocked, the focus highlight while it is merely focused.
    private var ringColor: Color { editing ? store.theme.unlockRing : store.theme.highlight.color }
    var available: [RotaryChannel] { channels.filter { !$0.hidden && !$0.disabled } }
    /// The order a left/right swipe walks the channels in; see RotaryStepOrder.
    var steps: [RotaryChannel] { RotaryStepOrder.selectable(channels) }
    var selected: RotaryChannel? {
        available.first { $0.id == channelID } ?? available.first { $0.id == initialChannel } ?? steps.first
    }
    func value(_ channel: RotaryChannel) -> Double {
        editing ? draft[channel.id] ?? channel.value : channel.value
    }

    var body: some View {
        // The face only needs to look current, not smooth: the tick re-reads the
        // value the server last sent (UITestHarness.fineTick).
        TimelineView(.periodic(from: .now, by: UITestHarness.fineTick)) { _ in
            VStack(spacing: 12) {
                knob
                .frame(width: size, height: size)
                #if os(iOS)
                .overlay { if editing { touchSurface } }
                #endif
                // Unlocked, the ring around the dial is the theme's unlock ring;
                // focused but locked it is the focus highlight. The unlock ring
                // used to be the highlight colour, so a theme that paints it
                // separately (white, in the household's) never reached the TV.
                .focusOutline(focus.wrappedValue == focusValue, Circle(), color: ringColor)
                .padding(compact ? 12 : 60)
                if !compact {
                Text(editing ? Self.editingHint : Self.idleHint)
                    .font(.novaMono(11)).foregroundStyle(store.theme.muted)
                }
            }
            .contentShape(Rectangle())
            .dashboardTapTarget(focus, equals: focusValue, perform: activate)
            .accessibilityLabel(title)
            .accessibilityValue(selected.map { $0.label + " " + $0.text(value($0)) } ?? subtitle)
            .accessibilityHint(Self.accessibilityHint)
        }
        .onChange(of: editMove) { _, move in
            guard editing, move?.focus == focusValue, let direction = move?.direction,
                  let selected else { return }
            activityBeat &+= 1
            if direction == .left || direction == .right {
                // Both ends hold: a swipe past the outermost ring or past the
                // last mode steps nowhere rather than wrapping or leaving.
                let index = steps.firstIndex { $0.id == selected.id } ?? 0
                channelID = steps[min(steps.count - 1, max(0, index + (direction == .right ? 1 : -1)))].id
                publishDial()
            } else {
                draft[selected.id] = selected.stepped(value(selected), by: direction == .up ? 1 : -1)
                // Publishing here is what makes "up and down turn the latched
                // dial" observable: without it a test can only see that the
                // press arrived somewhere inside the dial.
                publishDial()
            }
        }
        #if os(iOS)
        // A tap straight onto another dial hands it the unlock before this one
        // hears its focus go, so `finish` would find it already not editing.
        .onChange(of: editingFocus) { old, new in
            if old == focusValue, let new, new != focusValue { flushPending() }
        }
        #endif
        .onChange(of: editCancel) { _, cancel in
            guard let cancel, cancel.focus == focusValue else { return }
            finish(commit: cancel.commit, via: cancel.commit ? "touch-tap+commit" : "back+cancel")
        }
        .onChange(of: focus.wrappedValue) { _, next in
            #if os(iOS)
            // A finger on another control leaves the dial, as a tap outside it
            // does on the web: it locks, keeping what it shows.
            if editing && next != focusValue { finish(commit: true, via: "focus-left+commit") }
            #else
            if editing && next != focusValue {
                // The focus engine moves focus on a direction press even when
                // onMoveCommand handles it, so an unlocked dial takes its focus
                // straight back. It holds that target until a second click
                // releases it, so the theft is never allowed to stand.
                focus.wrappedValue = focusValue
            }
            #endif
        }
        // Only real suspension throws a draft away. tvOS marks the app
        // .inactive whenever it is not the focused app -- a system overlay, a
        // snapshot, the screen saver waking -- and discarding a dial the
        // household is mid-adjust on for that is not what "suspension
        // discards drafts" means.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { finish(commit: false, via: "scene-background+cancel") }
        }
        // The unlock is a lease, not a mode: with no input for the household's
        // five seconds the dial applies what it is showing and locks itself
        // again, exactly as a second click would. The beat restarts the clock on
        // every accepted input, so a dial being turned never times out mid-turn.
        .task(id: editing ? activityBeat : nil) {
            guard editing else { return }
            try? await Task.sleep(for: .seconds(UITestHarness.dialIdleCommit))
            guard !Task.isCancelled, editing else { return }
            #if os(iOS)
            // Never while a finger is down, as on the web: look again later.
            if touchHeld { activityBeat &+= 1; return }
            #endif
            finish(commit: true, via: "idle+commit")
        }
        .onDisappear { finish(commit: false, via: "disappear+cancel") }
        .animation(.easeOut(duration: 0.22), value: editing)
    }

    private var knob: some View {
        ZStack {
                    RotaryKnobFace(colors: bezelColors, skin: store.theme.knobSkinMode)
                    RotaryTitleArc(title: title, diameter: size).foregroundStyle(faceInk)
                    if let channel = selected, editing {
                        RotaryIndicator(fraction: channel.fraction(value(channel)), color: channel.color)
                            .padding(4)
                    }
                    faceReadoutView
                    if let countdownFraction, !editing, countdownFraction > 0 {
                        Circle().trim(from: 0, to: min(1, countdownFraction))
                            .stroke(store.theme.avatar.gradientAlert.color, lineWidth: 3)
                            .rotationEffect(.degrees(-90)).padding(size * 0.16)
                    }
                    ForEach(Array(channels.filter(\.ring).enumerated()), id: \.element.id) { index, channel in
                        RotaryArc(channel: channel, value: value(channel),
                                  selected: editing && (selected?.id == channel.id || touch.grabbedRing == channel.id))
                            .padding(-CGFloat(index + 1) * 15)
                            .opacity(editing && !channel.hidden ? (channel.disabled ? 0.25 : 1) : 0)
                    }
                }

    }

    private var resolvedLEDLabels: [String] {
        ledLabels ?? channels.filter { !$0.ring && !$0.hidden }.map(\.label)
    }
    private var litLED: Int {
        if let ledChannel, let channel = channels.first(where: { $0.id == ledChannel }) {
            return Int(value(channel))
        }
        return channels.filter { !$0.ring && !$0.hidden }.firstIndex(where: { $0.id == selected?.id }) ?? 0
    }
    private var faceInk: Color {
        store.theme.knobSkinMode.isLight ? Color(white: 0.22) : Color(red: 0.85, green: 0.77, blue: 0.65)
    }
    /// A ring being worked on (the remote's selected ring, or the thumb under a
    /// finger): the line under the lights names it and its value.
    private var shownRing: RotaryChannel? {
        guard editing else { return nil }
        if let id = touch.grabbedRing { return channels.first { $0.id == id } }
        return selected.flatMap { $0.ring ? $0 : nil }
    }
    /// The line under the lights. A dial whose face already shows the value being
    /// turned carries its subtitle alone there (the room temperature), never that
    /// value a second time.
    @ViewBuilder private var underLights: some View {
        if faceChannel != nil, shownRing == nil, faceDecimals {
            RotaryFaceText(text: subtitle, size: size * 0.15, decimals: true)
        } else {
            Text(underLightsText).font(.novaMono(max(9, size * 0.06))).lineLimit(1).minimumScaleFactor(0.5)
        }
    }
    private var underLightsText: String {
        func named(_ channel: RotaryChannel) -> String { channel.label + " " + channel.text(value(channel)) }
        if let ring = shownRing { return named(ring) }
        if faceChannel != nil { return subtitle }
        if editing { return selected.map(named) ?? "" }
        return symbol == nil ? selected?.label ?? subtitle : subtitle
    }
    private var faceReadoutView: some View {
                    VStack(spacing: size * 0.035) {
                        if let symbol { Image(systemName: symbol).font(.system(size: size * 0.17)) }
                        if let channelID = faceChannel, let channel = channels.first(where: { $0.id == channelID }) {
                            RotaryFaceText(text: channel.text(value(channel)), size: size * (faceDecimals ? 0.22 : 0.16),
                                           decimals: faceDecimals)
                        } else if let faceReadout, !editing {
                            Text(faceReadout).font(.novaDisplay(size * 0.14))
                        }
                        if symbol == nil {
                            RotaryLEDs(labels: resolvedLEDLabels, selected: litLED, size: size,
                                       color: store.theme.led, onLightSkin: store.theme.knobSkinMode.isLight)
                        }
                        underLights
                    }
                    .foregroundStyle(faceInk)
                    .padding(size * 0.15)

    }

    private func activate() {
        #if os(iOS)
        // Unlocked, the knob's own gestures own its taps; one outside it locks.
        if editing { return }
        #else
        if editing { finish(commit: true, via: "select-tap+commit"); return }
        #endif
        guard !available.isEmpty else { return }
        original = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0.value) })
        draft = original
        #if os(iOS)
        touch = RotaryTouchState()
        channelID = unlockChannel
        #else
        channelID = initialChannel ?? steps.first?.id ?? available[0].id
        #endif
        activityBeat &+= 1
        publishDial()
        debugInteractionLog("dial \(title) unlocked on \(focusValue.accessibilityID)")
        editingFocus = focusValue
    }
    func finish(commit: Bool, via: String) {
        guard editing else { return }
        debugInteractionLog("dial \(title) \(commit ? "committed" : "discarded") \(via)")
        if UITestHarness.isActive {
            UITestDraftLog.last = via
            UITestDialLog.channel = ""
            UITestDialLog.steps = ""
            UITestDialLog.value = ""
        }
        let changes = draft.filter { original[$0.key] != $0.value }
        // Recorded as handled, so a late flushPending cannot send them again.
        original.merge(changes) { $1 }
        editingFocus = nil
        if commit && !changes.isEmpty { onCommit(changes) }
    }

    /// UI-test only: publishes the step order and the channel a swipe landed on,
    /// so a test can assert the mode/ring order and both ends holding rather
    /// than only that a press arrived somewhere inside the dial.
    func publishDial() {
        guard UITestHarness.isActive else { return }
        UITestDialLog.channel = channelID
        UITestDialLog.steps = steps.map(\.id).joined(separator: ",")
        // One probe field per space: the text form can carry a unit, so any
        // space in it would split the pair the test reads.
        UITestDialLog.value = (selected.map { $0.text(draft[$0.id] ?? value($0)) } ?? "")
            .replacingOccurrences(of: " ", with: "_")
        UITestDialLog.beat &+= 1
    }
}

struct RotaryIndicator: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Circle().stroke(.black.opacity(0.65), lineWidth: 5)
                Capsule().fill(color).frame(width: 3, height: 16)
                    .offset(y: -geometry.size.height / 2 + 13)
                    .rotationEffect(.degrees(-135 + 270 * fraction))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct RotaryArc: View {
    let channel: RotaryChannel
    let value: Double
    let selected: Bool
    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: 0.75).stroke(.black.opacity(0.65), lineWidth: 9)
            Circle().trim(from: 0, to: 0.75 * (channel.kind == .selector ? 1 : channel.fraction(value)))
                .stroke(channel.color.opacity(selected ? 1 : 0.6), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            Circle().trim(from: max(0, channel.fraction(value) * 0.75 - 0.012),
                           to: min(0.75, channel.fraction(value) * 0.75 + 0.012))
                .stroke(.white, style: StrokeStyle(lineWidth: selected ? 9 : 6, lineCap: .round))
        }.rotationEffect(.degrees(135))
    }
}
