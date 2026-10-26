import SwiftUI
import UIKit
import Darwin

struct LandscapeDashboard: View {
    @EnvironmentObject private var store: DashboardStore
    @EnvironmentObject private var activity: NovaActivityStore
    @EnvironmentObject private var swipeInput: RemoteSwipeInput
    let onOpenPhonoscope: () -> Void
    /// Coming back from the visualiser: focus starts on the Phonoscope row it was
    /// opened from rather than on the orb (Adeline, 2026-10-16).
    var startOnPhonoscope = false
    var onStarted: () -> Void = {}
    @FocusState private var focus: DashboardFocus?
    @AppStorage("nova.tv.homeSelection") private var homeSelection = ""
    @AppStorage("nova.tv.systemSelection") private var systemSelection = ""
    @State private var editingFocus: DashboardFocus?
    @State private var editMove: DashboardEditMove?
    @State private var editCancel: DashboardEditCancel?
    /// The control the band's own navigation last put focus on. The TV's focus
    /// engine also moves focus on a direction press -- it picks a neighbour by
    /// geometry, the band by its own grid -- and its write can land after the
    /// band's (the theft `RotaryEncoder` answers for an unlocked dial). The grid
    /// is the model, so a move the band did not make is put back, and travel
    /// always starts from here rather than from a neighbour nobody chose.
    @State private var navigationFocus: DashboardFocus?
    /// Where focus was left in each block, so a swipe back lands on the same control.
    @State private var bandMemory = BandMemory()
    /// The panel the current touch began in, which a long swipe switches from.
    @State private var touchPanel: Int?
    @State private var serial = 0
    /// MoveCommand accounting for UI tests: received counts every press that
    /// reached the app, accepted every one the magnetic gate let through.
    @State private var movesReceived = 0
    @State private var movesAccepted = 0
    /// Scene transitions and the last reason a draft ended, for the same tests.
    @Environment(\.scenePhase) private var scenePhase
    @State private var phaseFlicks = 0
    /// Bumped whenever the published focus or edit state changes, so a UI test
    /// can tell a fresh accessibility value from the one XCUI served out of its
    /// snapshot cache before the press it just sent.
    @State private var stateBeat = 0
    @State private var backGate = RootBackExitGate()
    /// The HOST editor is up: the band's swipes stand down while it has the remote.
    @State private var editingHost = false
    private let orb = DashboardFocus.action("__orb", "dial")

    var body: some View {
        GeometryReader { geometry in
            let height = min(geometry.size.height - 110, max(540, geometry.size.height * store.layoutHeightFraction))
            HStack(spacing: 24) {
                sidebar.frame(width: 224)
                    #if os(tvOS)
                    .overlay(alignment: .leading) {
                        themeSelector
                            .offset(x: -Self.themeSelectorReveal)
                            .opacity(themeSelectorOpen ? 1 : 0)
                    }
                    #endif
                if let state = store.state {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 20) {
                                LandscapeClockColumn()
                                QuickAccessColumn(state: state, focus: $focus, editingFocus: $editingFocus,
                                    editMove: editMove, editCancel: editCancel)
                                    .id(Self.columnID(BandPanel.quickAccess, 0))
                                homeGroup(state)
                                systemsGroup(state)
                                Color.clear.frame(width: 40)
                            }.padding(10).id(Self.bandStartID)
                        }.scrollClipDisabled()
                        .onChange(of: focus) { _, next in
                            guard let next else { return }
                            withAnimation(.easeOut(duration: 0.24)) { scroll(proxy, to: next) }
                        }
                    }
                } else {
                    Text(store.errorMessage ?? "CONNECTING TO NOVA").font(.novaDisplay(26))
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 42)
            // The theme selector sits off screen left of the orb; while the remote
            // is on it the whole dashboard slides right to bring it on.
            .offset(x: themeSelectorOpen ? Self.themeSelectorReveal : 0)
            .animation(.easeOut(duration: 0.24), value: themeSelectorOpen)
            .overlay(alignment: .bottomLeading) {
                Text(store.errorMessage ?? (store.isSending ? "SAVING…" : ""))
                    .font(.novaMono(16)).foregroundStyle(store.errorMessage == nil ? store.theme.muted : .orange)
                    .padding(24)
            }
        }
        .overlay(alignment: .topTrailing) { if UITestHarness.isActive { focusStateProbe } }
        #if os(tvOS)
        .onExitCommand(perform: back)
        #else
        // Only the orb still drives its edit by a whole-screen pad; the dials take
        // the web's gestures on the knob itself (RotaryEncoderTouch.swift).
        .overlay { if editingFocus == NovaAvatarOrb.orbFocus { TouchEditPad(onStep: step, onTap: commitByTouch) } }
        #endif
        .onAppear { configureFeeds(); initialise(); connectRemote() }
        .onChange(of: store.fullScreenCameraID) { _, _ in connectRemote() }
        .onChange(of: editingHost) { _, _ in connectRemote() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { phaseFlicks &+= 1 } }
        .onChange(of: focus) { old, new in
            stateBeat &+= 1
            UITestFocusLog.note(describe(old), describe(new))
            connectRemote()
            // While a control is unlocked, the unlock owns focus: the swipe
            // target cannot be pulled off it, by the band or by the TV's focus
            // engine, until the control itself releases it (a second click, the
            // idle lease, or Back). Travel resumes only then.
            // On the phone a dial is left by touching anything else, as on the
            // web: the dial locks itself, so only the orb keeps its hold.
            #if os(iOS)
            let holdsFocus = editingFocus == NovaAvatarOrb.orbFocus
            #else
            let holdsFocus = true
            #endif
            if let editingFocus, new != editingFocus, holdsFocus {
                focus = editingFocus
                return
            }
            // The focus engine is not allowed to move focus on its own (see
            // RemoteInputHost), so every change is the band's: follow it.
            if let new { navigationFocus = new }
        }
        .onChange(of: editingFocus) { _, editing in
            stateBeat &+= 1
            swipeInput.adjusting = editing != nil
        }
        .onChange(of: store.state?.generatedAt) { _, _ in initialise() }
        .onChange(of: store.state?.preferences?.orbInfo?.entries?.map(\.id)) { _, _ in configureFeeds() }
    }

    /// UI test only: the dashboard publishes its own focus and edit state as one
    /// accessibility value, so a failing navigation test can tell "focus landed
    /// on the wrong control" apart from "edit mode never engaged". Invisible,
    /// never focusable, and absent from the household build because NOVA_UITEST
    /// is unset there (see UITestHarness).
    private var focusStateProbe: some View {
        Text(".")
            .font(.novaMono(8)).opacity(0.02)
            .frame(width: 30, height: 12)
            .accessibilityElement()
            .accessibilityIdentifier("__nova-focus-state")
            .accessibilityValue("focus=\(describe(focus)) editing=\(describe(editingFocus))"
                + " home=\(homeSelection) systems=\(systemSelection)"
                + " moves=\(movesReceived)/\(movesAccepted)" + " flicks=\(phaseFlicks)"
                + " last=\(UITestDraftLog.last)" + " beat=\(stateBeat)"
                + " swipe=\(Int(SwipeRangeStore.shared.profile.firstStepPct)),\(Int(SwipeRangeStore.shared.profile.secondStepPct)),\(SwipeRangeStore.shared.reaches.count)"
                + " knob=\(store.theme.knobSkinMode.isLight ? "light" : "dark")"
                + " theme=\(ThemeMode.mode(storeValue: store.themeOverride))"
                + " channel=\(UITestDialLog.channel) steps=\(UITestDialLog.steps) value=\(UITestDialLog.value) dialbeat=\(UITestDialLog.beat)"
                + " ready=\(store.state == nil ? "no" : "yes")"
                + " trail=\(UITestFocusLog.recent)")
    }

    private func describe(_ focus: DashboardFocus?) -> String {
        guard let focus else { return "nil" }
        switch focus {
        case .section(let id): return "section:" + id
        case .child(let id): return "child:" + id
        case .action(let zone, let action): return "action:" + zone + "/" + action
        case .hue(let id): return "hue:" + id
        case .brightness(let id): return "brightness:" + id
        case .temperature(let zone, let id): return "temperature:" + zone + "/" + id
        case .fanSpeed(let zone, let id): return "fanSpeed:" + zone + "/" + id
        }
    }

    private var sidebar: some View {
        VStack(spacing: 30) {
            Spacer()
            NovaAvatarOrb(load: activity.load?.load ?? 0, listening: activity.load?.listening == true,
                novaLoad: activity.load, power: activity.power, tasks: activity.tasks,
                watchface: store.state?.preferences?.watchface, focus: $focus,
                editingFocus: $editingFocus, editMove: editMove, editCancel: editCancel)
                .frame(width: 200, height: 200)
            Spacer()
            #if os(iOS)
            // No off-screen column to swipe to on the phone: the theme and HOST
            // buttons sit at the foot of the orb's sidebar instead.
            ThemeHostControls(focus: $focus, editingHost: $editingHost, buttonSize: 96, axis: .horizontal)
            #endif
        }
    }

    // MARK: Scrolling the band
    //
    // Adeline, 2026-10-23: "the currently focused stack should always try to
    // center itself ... if there's room to do so, try to centre on it, or go as far
    // as it can". The stack is the focused control's column (`BandMap`: a panel is
    // a row of columns, a column is a stack of blocks), so the band holds still
    // while the remote moves up and down a column. `scrollTo` clamps at the ends of
    // the band, which is the "as far as it can". Back on the orb (or the theme
    // selector left of it) the band goes all the way back to its start, or the
    // first panel is left drawn over the orb.

    private static let bandStartID = "band-start"
    private static func columnID(_ panel: Int, _ column: Int) -> String { "band-column-\(panel)-\(column)" }

    private func scroll(_ proxy: ScrollViewProxy, to focus: DashboardFocus) {
        guard let state = store.state else { return }
        let map = BandMap(bandSpec(state: state, homeSelection: homeSelection, systemSelection: systemSelection,
                                   themeOverride: store.themeOverride))
        guard let element = map.element(focus) else { proxy.scrollTo(focus, anchor: .center); return }
        if element.panel < BandPanel.quickAccess {
            proxy.scrollTo(Self.bandStartID, anchor: .leading)
        } else {
            proxy.scrollTo(Self.columnID(element.panel, element.column), anchor: .center)
        }
    }

    // MARK: Theme selector
    //
    // Adeline, 2026-10-23: "a theme mode selector (dark/light/auto) same as on the
    // web version. put it to the left of the status orb, offscreen. it'll only show
    // if the user swipes left from the status orb to get to it, and going back to
    // the status orb will hide it." Since made one cycling icon and a HOST button
    // (`ThemeHostControls`, specs/theme-mode-selector.md).

    /// How far the selector sits left of the orb's sidebar, and so how far the
    /// dashboard slides to show it: its own width plus enough to clear the
    /// screen's 42pt margin with nothing left peeking in.
    private static let themeSelectorWidth: CGFloat = 56 + 205
    private static let themeSelectorReveal: CGFloat = themeSelectorWidth + 66

    /// Never on the phone: its buttons sit in the sidebar, so the band never slides.
    private var themeSelectorOpen: Bool {
        #if os(iOS)
        return false
        #else
        guard case .action(let zone, _) = navigationFocus ?? focus else { return false }
        return zone == ThemeMode.zone
        #endif
    }

    private var themeSelector: some View {
        LandscapeGroup(title: "Theme") {
            VStack(spacing: 0) {
                ThemeHostControls(focus: $focus, editingHost: $editingHost)
                Spacer(minLength: 0)
            }.padding(14).frame(width: 205)
        }
        .frame(width: Self.themeSelectorWidth)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func homeGroup(_ state: DashboardState) -> some View {
        LandscapeGroup(title: "Home") {
            VStack(spacing: 9) {
                ForEach(homeZones(state)) { zone in
                    menu(zone.isHomeZone ? "HOME" : zone.name.uppercased(), id: .child(zone.id),
                         selected: homeSelection == zone.id) { homeSelection = zone.id }
                }
                Spacer(minLength: 0)
            }.padding(14).frame(width: 205)
            .id(Self.columnID(BandPanel.home, 0))
            if let zone = state.zone(id: homeSelection), zone.canUseLightingControls {
                ColorEncoder(zone: zone, state: state, focus: $focus, editingFocus: $editingFocus,
                             editMove: editMove, editCancel: editCancel)
                    .id(Self.columnID(BandPanel.home, 1))
            }
        }
    }

    private func systemsGroup(_ state: DashboardState) -> some View {
        LandscapeGroup(title: "Systems") {
            VStack(spacing: 9) {
                ForEach(state.primaryZones.filter { !$0.isHomeZone }) { zone in
                    menu(zone.name.uppercased(), id: .section(zone.id), selected: systemSelection == zone.id) {
                        systemSelection = zone.id
                    }
                }
                menu("REMINDERS", id: .section("__timers"), selected: systemSelection == "__timers") {
                    systemSelection = "__timers"
                }
                // The phonoscope opens the visualiser. It is a row of the systems
                // list, under Reminders (Adeline, 2026-09-20), rather than a
                // control hung off the right end of the band, so it is drawn by
                // the same row control the systems above it use.
                menu("PHONOSCOPE", id: .section(phonoscopeZoneID), selected: false) { onOpenPhonoscope() }
                Spacer(minLength: 0)
            }.padding(14).frame(width: 205)
            .id(Self.columnID(BandPanel.systems, 0))
            // One container for the selected system's controls, so the column has
            // one scroll id. Spacing 0, as the group's own row has.
            HStack(spacing: 0) { systemControls(state) }
                .id(Self.columnID(BandPanel.systems, 1))
        }
    }

    @ViewBuilder private func systemControls(_ state: DashboardState) -> some View {
            if systemSelection == "__timers" {
                TimerEncoder(focus: $focus, editingFocus: $editingFocus, editMove: editMove, editCancel: editCancel)
            } else if let zone = state.zone(id: systemSelection) {
                if zone.isClimateZone {
                    TemperatureEncoder(zone: zone, state: state, bedroom: false, focus: $focus,
                        editingFocus: $editingFocus, editMove: editMove, editCancel: editCancel)
                    TemperatureEncoder(zone: zone, state: state, bedroom: true, focus: $focus,
                        editingFocus: $editingFocus, editMove: editMove, editCancel: editCancel)
                } else if zone.isOutsideZone {
                    OutsideExpandedControls(zone: zone, weather: state.weather, focus: $focus)
                } else if zone.isNetworkZone {
                    NetworkStatusPanel(router: state.router, focus: $focus, focusValue: .action(zone.id, "network"))
                }
            }
    }
    private func menu(_ title: String, id: DashboardFocus, selected: Bool, action: @escaping () -> Void) -> some View {
        RibbonTitleButton(title: title, subtitle: "", focus: $focus, focusValue: id,
                          isFocused: focus == id, isExpanded: selected, compact: true, action: action)
            .frame(height: 72)
    }
    private func homeZones(_ state: DashboardState) -> [DashboardZone] {
        [state.homeZone].compactMap { $0 } + state.homeChildZones.filter(\.canUseLightingControls)
    }
    private func configureFeeds() {
        activity.extraFeeds = OrbInfoCatalogue.stackSources(store.state?.preferences?.orbInfo)
    }
    private func initialise() {
        guard let state = store.state else { return }
        if state.zone(id: homeSelection) == nil { homeSelection = state.homeZone?.id ?? "" }
        if systemSelection != "__timers" && state.zone(id: systemSelection) == nil {
            systemSelection = state.climateZone?.id ?? "__timers"
        }
        if focus == nil {
            let start = startOnPhonoscope ? DashboardFocus.section(phonoscopeZoneID) : orb
            focus = start
            navigationFocus = start
            onStarted()
        }
    }

    /// Hands the swipe engine what a step does and how a step is judged. Called
    /// again when focus changes so the closures never read a stale copy.
    private func connectRemote() {
        swipeInput.adjusting = editingFocus != nil
        swipeInput.enabled = store.fullScreenCameraID == nil && !editingHost
        swipeInput.onStep = { step($0) }
        swipeInput.classify = { classify($0) }
        swipeInput.onPanel = { switchPanel($0) }
        swipeInput.classifyPanel = { classifyPanel($0) }
        swipeInput.canCoast = { canCoast($0) }
        swipeInput.onTouchBegan = { touchPanel = bandCursor()?.panel }
    }

    /// The band as it is now, with a cursor on the control the last step left focus on.
    private func bandCursor() -> BandCursor? {
        guard let state = store.state else { return nil }
        let spec = bandSpec(state: state, homeSelection: homeSelection, systemSelection: systemSelection,
                            themeOverride: store.themeOverride)
        // A control that has since left the band (a zone that went away) leaves
        // nowhere to swipe from: start again from the orb.
        let origin = (navigationFocus ?? focus).flatMap { BandMap(spec).element($0) != nil ? $0 : nil } ?? orb
        return BandCursor(spec: spec, focus: origin, memory: bandMemory)
    }

    /// Whether a coasting flick may take its next step: only along its own row or list.
    private func canCoast(_ direction: RemoteDirection) -> Bool {
        guard editingFocus == nil, let cursor = bandCursor() else { return false }
        return cursor.pressStaysInColumn(direction)
    }

    /// Writes a cursor's place back: the selections and open groups it changed,
    /// what it remembers, and where focus now is.
    private func adopt(_ cursor: BandCursor) {
        homeSelection = cursor.spec.homeSelection
        systemSelection = cursor.spec.systemSelection
        bandMemory = cursor.memory
        navigationFocus = cursor.focus
        focus = cursor.focus
    }

    /// Whether the next step in `direction` goes anywhere, or the control is at the end.
    private func classify(_ direction: RemoteDirection) -> SwipeStepKind {
        guard editingFocus == nil, let cursor = bandCursor() else { return .move }
        return cursor.canPress(direction) ? .move : .bounce
    }

    private func classifyPanel(_ direction: RemoteDirection) -> SwipeStepKind {
        guard editingFocus == nil, let cursor = bandCursor() else { return .move }
        return cursor.canJump(direction, fromPanel: touchPanel ?? cursor.panel) ? .move : .bounce
    }

    /// A long horizontal swipe: the next panel along from the one the swipe began in.
    private func switchPanel(_ direction: RemoteDirection) {
        guard editingFocus == nil, var cursor = bandCursor() else { return }
        movesReceived &+= 1
        backGate.reset()
        guard cursor.jump(direction, fromPanel: touchPanel ?? cursor.panel) != .none else { return }
        movesAccepted &+= 1
        debugInteractionLog("panel \(direction) -> \(describe(cursor.focus))")
        InputTrace.shared.note("focus \(describe(cursor.focus)) by long swipe")
        adopt(cursor)
    }

    /// One step of travel, from a swipe, a coast or a clickpad press.
    private func step(_ direction: RemoteDirection) {
        movesReceived &+= 1
        if let editingFocus {
            // An unlocked control owns the remote and gives it back only by
            // itself. Checked before the state guard on purpose: a press is the
            // control's own step whatever the state poll is doing.
            movesAccepted &+= 1
            serial &+= 1
            backGate.reset()
            editMove = DashboardEditMove(serial: serial, focus: editingFocus, direction: direction)
            debugInteractionLog("move \(direction) -> unlocked \(describe(editingFocus))")
            return
        }
        movesAccepted &+= 1
        backGate.reset()
        serial &+= 1
        guard var cursor = bandCursor() else { return }
        let origin = cursor.focus
        guard cursor.press(direction) != .none else { return }
        debugInteractionLog("move \(direction) \(describe(origin)) -> \(describe(cursor.focus))")
        InputTrace.shared.note("focus \(describe(origin)) -> \(describe(cursor.focus))")
        adopt(cursor)
    }

    /// The phone's tap while a control is unlocked: keep what it shows, as
    /// Select on it does on the TV.
    private func commitByTouch() {
        guard let editingFocus else { return }
        serial &+= 1
        editCancel = DashboardEditCancel(serial: serial, focus: editingFocus, commit: true)
    }

    private func back() {
        if store.fullScreenCameraID != nil { store.fullScreenCameraID = nil; return }
        if let editingFocus {
            serial &+= 1
            editCancel = DashboardEditCancel(serial: serial, focus: editingFocus)
        } else if (navigationFocus ?? focus) != orb {
            navigationFocus = orb
            focus = orb
        }
        else if backGate.register(at: ProcessInfo.processInfo.systemUptime) {
            exit(0)
        }
    }
}
