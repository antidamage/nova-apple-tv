import Darwin
import Foundation
import SwiftUI
import UIKit

// The dashboard root and the ribbon scaffolding around it.
//
// The whole UI is a single fixed-height horizontal "band" (a fraction of the
// screen height from the shared theme) that flows left→right: status orb, clock,
// then a horizontally-scrolling ribbon of zones whose controls expand to the
// right as you drill in. This file owns:
//   - the root view, which hosts the band, the background, the full-screen
//     camera cover, and the remote command handling, and
//   - the chrome around the zones (clock header, primary zone ribbon, the
//     expanded-zone dispatcher, footer, loading state).
// The focus model and graph live in DashboardFocus.swift; the per-zone control
// surfaces live in the LightingControlsView / ClimateControlsView / OutsideView
// files; reusable building blocks live in DashboardComponents.swift.

struct TVDashboardView: View {
    @EnvironmentObject private var store: DashboardStore
    @EnvironmentObject private var activity: NovaActivityStore
    @EnvironmentObject private var speech: VoiceSpeechStore
    @EnvironmentObject private var phonoscope: PhonoscopeStore
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focus: DashboardFocus?
    @State private var expandedTopZoneID: String?
    @State private var expandedChildZoneID: String?
    @State private var editingFocus: DashboardFocus?
    @State private var editMove: DashboardEditMove?
    @State private var editMoveSerial = 0
    @State private var editCancel: DashboardEditCancel?
    @State private var editCancelSerial = 0
    @State private var remoteMoveGate = RemoteMoveGate()
    @State private var stickyGate = StickyBoundaryGate()
    @State private var rootBackExitGate = RootBackExitGate()
    @State private var exitCommandShield = ExitCommandShield()
    // Transient horizontal "tug" applied to the control band when a sticky
    // boundary resists a swipe, so holding against it reads as resistance rather
    // than a dead remote.
    @State private var resistOffset: CGFloat = 0
    @State private var resistToken = 0
    @State private var exitCommandSerial = 0
    // Device verification can launch straight into the streamed surface without
    // changing normal startup or adding a production-only navigation path.
    @State private var isPhonoscopePresented =
        ProcessInfo.processInfo.arguments.contains("--launch-phonoscope")
        || ProcessInfo.processInfo.environment["NOVA_LAUNCH_PHONOSCOPE"] == "1"

    var body: some View {
        ZStack {
            if !isPhonoscopePresented {
                Group {
                FluidBackgroundView(theme: store.theme, baseURL: store.activeBaseURL ?? AppConfig.dashboardBaseURL)
                    .ignoresSafeArea()

                // Horizontal control band: the whole dashboard flows left->right
                // inside a fixed-height band (a fraction of the screen height, from
                // the shared theme's `layout.tvHeightFraction`). The band is
                // vertically centred, leaving ambient fluid background above/below.
                GeometryReader { geo in
                let bandHeight = geo.size.height * store.layoutHeightFraction

                HStack(alignment: .center, spacing: 18) {
                    // Status orb is the primary element: pinned far left, sized to
                    // ~60% of the working band height.
                    NovaAvatarOrb(
                        load: activity.load?.load ?? 0,
                        listening: activity.load?.listening == true,
                        watchface: store.state?.preferences?.watchface
                    )
                    .frame(width: bandHeight * 0.6, height: bandHeight * 0.6)
                    .zIndex(speech.phase == .idle ? 0 : 4_000)

                    // Time box, pinned next to the orb — always-visible clock.
                    DashboardHeader()

                    if let state = store.state {
                        // Everything from the zones rightward scrolls
                        // horizontally so deep control chains can always be
                        // reached. `scrollTo(focus)` keeps the focused column
                        // centred as you swipe — no dead ends.
                        ScrollViewReader { proxy in
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .center, spacing: 18) {
                                    ZoneRibbon(
                                        state: state,
                                        focus: $focus,
                                        expandedTopZoneID: $expandedTopZoneID,
                                        expandedChildZoneID: $expandedChildZoneID,
                                        editingFocus: $editingFocus,
                                        editMove: editMove,
                                        editCancel: editCancel,
                                        onOpenPhonoscope: openPhonoscope
                                    )
                                    // Tail spacer: lets the last control scroll
                                    // clear of the trailing edge when centred.
                                    Color.clear.frame(width: 120)
                                }
                                .frame(maxHeight: .infinity)
                                .padding(.vertical, 4)
                                // Sticky-boundary resistance feedback: a brief
                                // rubber-band tug in the push direction, springing
                                // back, without moving the scroll/focus position.
                                .offset(x: resistOffset)
                            }
                            // Let focus highlight/scale spill past the scroll
                            // bounds instead of being clipped at the edges.
                            .scrollClipDisabled()
                            .onChange(of: focus) { _, nextFocus in
                                guard let nextFocus else { return }
                                withAnimation(.easeOut(duration: 0.28)) {
                                    proxy.scrollTo(nextFocus, anchor: .center)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        LoadingView(message: store.errorMessage)
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: bandHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 54)
                .overlay(alignment: .bottom) {
                    FooterStatusView()
                        .padding(.horizontal, 54)
                        .padding(.bottom, 18)
                }
                }
            }
                .transition(.opacity)
            }

            if isPhonoscopePresented {
                PhonoscopeView(onBack: dismissPhonoscope)
                    .environmentObject(phonoscope)
                    .transition(.opacity)
                    .zIndex(10_000)
            }
        }
        .background(Color.black)
        .animation(
            .easeInOut(duration: Double(phonoscope.configuration?.transitionMs ?? 600) / 1_000),
            value: isPhonoscopePresented
        )
        .foregroundStyle(store.theme.text)
        .focusEffectDisabled()
        .onMoveCommand(perform: handleMove)
        .onExitCommand(perform: handleExit)
        .onChange(of: focus) { _, nextFocus in
            if let editingFocus, nextFocus != editingFocus {
                self.editingFocus = nil
            }

            guard let state = store.state else { return }
            if let zoneID = nextFocus?.zoneID, zoneID != phonoscopeZoneID {
                store.selectedZoneID = zoneID
            }
            collapseIfFocusLeftExpandedArea(nextFocus, state: state)
        }
        .onChange(of: store.state?.primaryZones.first?.id) { _, firstZoneID in
            if focus == nil, let firstZoneID {
                focus = .section(firstZoneID)
            }
        }
        .onChange(of: isPhonoscopePresented) { _, presented in
            setScreenAwake(presented)
            if !presented, phonoscope.housePartyEnabled {
                // The dashboard is fully transparent while Phonoscope is up.
                // Keep its followed palette intact through the crossfade back,
                // then visibly ease from those colours to the configured theme.
                store.clearVisualizerColorOverride(
                    duration: phonoscopeTransitionSeconds,
                    delay: phonoscopeTransitionSeconds
                )
            }
        }
        .onChange(of: phonoscope.visualizerTheme) { _, visualizerTheme in
            guard phonoscope.housePartyEnabled else { return }
            // Already eased upstream by `PhonoscopeStore.advanceTheme`, so this
            // tracks it directly rather than filtering it a second time.
            store.setVisualizerColorOverride(visualizerTheme)
        }
        .onChange(of: store.followVisualizerWhenActive) { _, followsVisualizer in
            if followsVisualizer, phonoscope.housePartyEnabled {
                store.setVisualizerColorOverride(
                    phonoscope.visualizerTheme,
                    duration: phonoscopeTransitionSeconds
                )
            } else if !followsVisualizer {
                store.clearVisualizerColorOverride(duration: phonoscopeTransitionSeconds)
            }
        }
        .onChange(of: phonoscope.housePartyEnabled) { _, housePartyEnabled in
            if housePartyEnabled {
                store.setVisualizerColorOverride(
                    phonoscope.visualizerTheme,
                    duration: phonoscopeTransitionSeconds
                )
            } else {
                store.clearVisualizerColorOverride(duration: phonoscopeTransitionSeconds)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // tvOS can rebuild or reactivate the SwiftUI scene after overlays
            // and interruptions. Reassert the lease when the app returns so
            // the system screen saver cannot take over a running visualiser.
            if phase == .active {
                setScreenAwake(isPhonoscopePresented)
            }
        }
        .onDisappear {
            setScreenAwake(false)
        }
        // Full-screen camera player, hosted by the root so it survives the zone
        // collapsing or the camera tile unmounting while the modal holds focus.
        .fullScreenCover(isPresented: cameraCoverBinding) {
            if let id = store.fullScreenCameraID {
                CameraFullScreenPlayer(
                    url: AppConfig.cameraURL(cameraID: id, path: "index.m3u8")
                )
                .ignoresSafeArea()
            }
        }
    }

    // Drives the full-screen camera cover from the store-owned camera id.
    private var cameraCoverBinding: Binding<Bool> {
        Binding(
            get: { store.fullScreenCameraID != nil },
            set: { presented in
                if !presented { store.fullScreenCameraID = nil }
            }
        )
    }

    // MARK: Remote command handling

    /// Routes a directional remote move: while a control is editing it forwards a
    /// serialized `editMove` to that control; otherwise it advances focus through
    /// the graph. Both paths run through `RemoteMoveGate` for debounce/gating.
    private func handleMove(_ direction: MoveCommandDirection) {
        guard !isPhonoscopePresented else { return }
        guard let remoteDirection = RemoteDirection(direction) else { return }
        rootBackExitGate.reset()

        if let editingFocus {
            guard remoteMoveGate.accept(direction: remoteDirection, focus: editingFocus, isEditing: true) else {
                debugInteractionLog("ignored edit move \(remoteDirection) focus=\(editingFocus)")
                return
            }
            editMoveSerial &+= 1
            editMove = DashboardEditMove(serial: editMoveSerial, focus: editingFocus, direction: remoteDirection)
            debugInteractionLog("edit move \(remoteDirection) focus=\(editingFocus)")
            return
        }

        guard remoteMoveGate.accept(direction: remoteDirection, focus: focus, isEditing: false) else {
            debugInteractionLog("ignored nav move \(remoteDirection) focus=\(String(describing: focus))")
            return
        }
        guard let state = store.state else { return }
        debugInteractionLog("accepted nav move \(remoteDirection) focus=\(String(describing: focus))")
        moveFocus(direction: remoteDirection, state: state)
    }

    /// Menu/Back: dismisses the camera cover, then cancels editing, then collapses
    /// the open child/zone, then steps focus one level shallower. At the root,
    /// two presses within a short window exit for remotes without a dedicated
    /// exit button.
    private func handleExit() {
        exitCommandSerial &+= 1
        let now = ProcessInfo.processInfo.systemUptime

        if isPhonoscopePresented {
            dismissPhonoscope()
            return
        }

        if exitCommandShield.contains(now) {
            debugInteractionLog("ignored trailing exit command after Phonoscope dismissal")
            return
        }

        // Menu/Back while the full-screen camera is up dismisses just the
        // player — it must not fall through and collapse the underlying zone.
        if store.fullScreenCameraID != nil {
            rootBackExitGate.reset()
            store.fullScreenCameraID = nil
            return
        }

        if cancelEditing() {
            rootBackExitGate.reset()
            return
        }

        // The physical Menu/Back button is always an immediate, deliberate
        // one-level exit; only swipe-driven Back (left at a control edge) is
        // gated by the hierarchy stickiness. Clear any half-charged swipe so the
        // button never inherits resistance.
        stickyGate.reset()
        if collapseOneLevel() {
            rootBackExitGate.reset()
            return
        }

        guard rootBackExitGate.register(at: now) else {
            debugInteractionLog("exit armed at root")
            return
        }

        debugInteractionLog("exit confirmed by double Back at root")
        exit(EXIT_SUCCESS)
    }

    private func dismissPhonoscope() {
        let now = ProcessInfo.processInfo.systemUptime
        exitCommandShield.begin(at: now)
        rootBackExitGate.reset()
        withAnimation {
            isPhonoscopePresented = false
        }
        focus = .section(phonoscopeZoneID)
    }

    private var phonoscopeTransitionSeconds: Double {
        Double(phonoscope.configuration?.transitionMs ?? 600) / 1_000
    }

    private func openPhonoscope() {
        editingFocus = nil
        expandedTopZoneID = nil
        expandedChildZoneID = nil
        rootBackExitGate.reset()
        withAnimation {
            isPhonoscopePresented = true
        }
    }

    /// Phonoscope is an intentionally unattended, continuously animated
    /// display. Own the global UIKit idle-timer lease at this stable root
    /// rather than the transient Metal child view so SwiftUI focus/view
    /// reconstruction cannot accidentally release it.
    private func setScreenAwake(_ awake: Bool) {
        guard UIApplication.shared.isIdleTimerDisabled != awake else { return }
        UIApplication.shared.isIdleTimerDisabled = awake
        debugInteractionLog("Phonoscope screen-awake lease \(awake ? "enabled" : "released")")
    }

    /// Steps exactly one level shallower: collapse an open child, else an open
    /// zone, else return to the owning title, else settle on the first zone.
    /// Shared by the Menu/Back button (instant) and the sticky left-edge swipe
    /// (once it has overcome the hierarchy resistance).
    @discardableResult
    private func collapseOneLevel() -> Bool {
        if let expandedChildZoneID {
            self.expandedChildZoneID = nil
            focus = .child(expandedChildZoneID)
            debugInteractionLog("exit collapsed child \(expandedChildZoneID)")
            return true
        }

        if let expandedTopZoneID {
            self.expandedTopZoneID = nil
            focus = .section(expandedTopZoneID)
            debugInteractionLog("exit collapsed section \(expandedTopZoneID)")
            return true
        }

        if let state = store.state {
            if let current = focus,
               let owner = ownerTitle(for: current, state: state) {
                focus = owner
                debugInteractionLog("exit returned \(current) -> \(owner)")
                return true
            }

            focus = state.primaryZones.first.map { .section($0.id) }
        }

        debugInteractionLog("exit reached root")
        return false
    }

    /// Advances focus through the transposed graph. up/down move between siblings
    /// in the current depth level; right drills deeper (expanding the focused
    /// title like Select); left steps shallower (or, at the left edge of a control
    /// group, behaves like Back). See DashboardFocus.swift for the graph.
    private func moveFocus(direction remoteDirection: RemoteDirection, state: DashboardState) {
        let graph = dashboardFocusGraph(state: state, expandedTopZoneID: expandedTopZoneID, expandedChildZoneID: expandedChildZoneID)
        guard !graph.rows.isEmpty else { return }

        guard let current = focus else {
            focus = graph.first
            return
        }
        guard let pos = graph.position(of: current) else {
            // Orphaned focus (its column isn't in the graph): recover to its
            // owning title rather than collapsing to the first zone button.
            if let owner = ownerTitle(for: current, state: state),
               graph.position(of: owner) != nil {
                focus = owner
            } else {
                focus = graph.first
            }
            return
        }

        // Horizontal (transposed) layout. The focus graph's outer index is a
        // depth level laid out left->right on screen; items within a level are
        // siblings stacked top->bottom. So the remote maps to:
        //   up/down -> move between siblings in the current level (vertical)
        //   right   -> go deeper (enter an expanded container / next level)
        //   left    -> go shallower (back to the owning title / previous level)
        // Moving between zone titles auto-collapses the open zone via
        // `collapseIfFocusLeftExpandedArea`; Menu collapses explicitly.
        switch remoteDirection {
        case .up, .down:
            // Siblings within one level never cross a sticky boundary.
            let delta = remoteDirection == .up ? -1 : 1
            if let next = graph.focus(row: pos.row, column: pos.column + delta) {
                stickyGate.reset()
                focus = next
                debugInteractionLog("nav \(remoteDirection) \(current) -> \(next)")
            }

        case .right:
            // From a zone/child title, drill in: expand whatever you're on (like
            // Select) and focus its first control, so "right" always opens the
            // button under focus — and "left" re-targets that same button coming
            // back out (its controls carry its zone id, see ownerTitle).
            switch current {
            case .section(let id):
                if let zone = state.zone(id: id) {
                    stickyGate.reset()
                    let entry = firstFocusInsideTopZone(zone, state: state) ?? .section(id)
                    if expandedTopZoneID == id {
                        focus = entry
                    } else {
                        expandedTopZoneID = id
                        expandedChildZoneID = nil
                        // Defer until the controls render, then target the first.
                        DispatchQueue.main.async { self.focus = entry }
                    }
                    debugInteractionLog("right entered section \(id) -> \(entry)")
                    return
                }
            case .child(let id):
                if let zone = state.zone(id: id) {
                    stickyGate.reset()
                    let entry = firstFocusInsideChildZone(zone) ?? .child(id)
                    if expandedChildZoneID == id {
                        focus = entry
                    } else {
                        expandedChildZoneID = id
                        DispatchQueue.main.async { self.focus = entry }
                    }
                    debugInteractionLog("right entered child \(id) -> \(entry)")
                    return
                }
            default:
                break
            }
            // Within a control surface: step one column deeper. Walking right
            // repeatedly reaches the rightmost control with no dead ends —
            // crossing into a different device group is sticky.
            if let next = graph.nearestFocus(row: pos.row + 1, column: pos.column) {
                moveAcrossControls(to: next, from: current, direction: .right, state: state)
            }

        case .left:
            if isControlFocus(current) {
                // Step to a shallower control column if there is one (sticky when
                // it lands in a different device group)...
                let prevRow = pos.row - 1
                if prevRow >= 0,
                   graph.rows[prevRow].contains(where: { isControlFocus($0) }),
                   let next = graph.nearestFocus(row: prevRow, column: pos.column) {
                    moveAcrossControls(to: next, from: current, direction: .left, state: state)
                    return
                }
                // ...otherwise we're at the left edge of the control group, so
                // left behaves like Back: collapse to the button that opened this
                // group — but a swipe must first overcome the hierarchy
                // stickiness so one stray flick can't pop the level.
                guard passesSticky(.hierarchy, from: current, direction: .left) else { return }
                collapseOneLevel()
                return
            }

            // On a title, return to the owning title one level shallower — also a
            // hierarchy step out, so equally sticky to a swipe.
            if let owner = ownerTitle(for: current, state: state),
               let ownerPos = graph.position(of: owner),
               ownerPos.row == pos.row - 1 {
                guard passesSticky(.hierarchy, from: current, direction: .left) else { return }
                focus = owner
                debugInteractionLog("left returned \(current) -> \(owner)")
                return
            }
            if let next = graph.nearestFocus(row: pos.row - 1, column: pos.column) {
                stickyGate.reset()
                focus = next
                debugInteractionLog("nav left \(current) -> \(next)")
            }
        }
    }

    /// Applies a horizontal control-to-control move. If it crosses into a
    /// different component group (e.g. air conditioner → panel heater) it must
    /// first overcome the component-group stickiness; moving control-to-control
    /// inside one device is immediate.
    private func moveAcrossControls(to next: DashboardFocus, from current: DashboardFocus, direction: RemoteDirection, state: DashboardState) {
        if controlGroupID(for: next, state: state) != controlGroupID(for: current, state: state) {
            guard passesSticky(.componentGroup, from: current, direction: direction) else { return }
        } else {
            stickyGate.reset()
        }
        focus = next
        debugInteractionLog("nav \(direction) \(current) -> \(next)")
    }

    /// Charges the sticky gate for a boundary crossing. Returns true once enough
    /// moves have accumulated to cross; while it returns false the move is
    /// withheld and a tug is played so the resistance is felt, not silent.
    private func passesSticky(_ kind: StickyBoundaryKind, from: DashboardFocus, direction: RemoteDirection) -> Bool {
        let boundary = StickyBoundary(from: from, direction: direction, kind: kind)
        switch stickyGate.register(boundary) {
        case .cross:
            return true
        case .resist(let progress):
            tug(direction: direction, progress: progress)
            debugInteractionLog("resist \(kind) from \(from) progress=\(progress)")
            return false
        }
    }

    /// A brief rubber-band tug of the control band in the push direction, growing
    /// with how close the boundary is to giving way, then springing back.
    private func tug(direction: RemoteDirection, progress: Double) {
        let sign: CGFloat
        switch direction {
        case .left: sign = -1
        case .right: sign = 1
        default: return
        }
        let magnitude = CGFloat(7 + 11 * progress)
        resistToken &+= 1
        let token = resistToken
        withAnimation(.spring(response: 0.10, dampingFraction: 0.55)) {
            resistOffset = sign * magnitude
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
            guard token == resistToken else { return }
            withAnimation(.spring(response: 0.26, dampingFraction: 0.72)) {
                resistOffset = 0
            }
        }
    }

    /// Sends the editing control a serialized cancel and clears `editingFocus`.
    /// Returns whether anything was editing (so Back can stop here).
    private func cancelEditing() -> Bool {
        guard let editingFocus else { return false }
        editCancelSerial &+= 1
        editCancel = DashboardEditCancel(serial: editCancelSerial, focus: editingFocus)
        self.editingFocus = nil
        debugInteractionLog("edit cancel focus=\(editingFocus)")
        return true
    }

    /// Collapses an expanded zone/child once focus has genuinely moved out of it.
    /// A `nil` focus is treated as a transient loss (e.g. the full-screen camera
    /// taking focus) and must NOT collapse anything — otherwise the modal's host
    /// unmounts and the cover dismisses the instant it opens.
    private func collapseIfFocusLeftExpandedArea(_ nextFocus: DashboardFocus?, state: DashboardState) {
        guard let nextFocus else { return }

        if let expandedTopZoneID,
           topID(for: nextFocus, state: state) != expandedTopZoneID {
            self.expandedTopZoneID = nil
            expandedChildZoneID = nil
        }

        if let expandedChildZoneID,
           !isFocus(nextFocus, insideChild: expandedChildZoneID) {
            self.expandedChildZoneID = nil
        }
    }
}

// MARK: - Clock header

/// The always-visible clock card pinned beside the orb: label, NOVA wordmark, a
/// location chip, and a large monospaced time/date block that re-renders each
/// second via `TimelineView`.
private struct DashboardHeader: View {
    @EnvironmentObject private var store: DashboardStore
    private let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        PanelFrame {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("SYSTEM TIME")
                            .font(.novaMono(18))
                            .foregroundStyle(store.theme.muted)
                        Text("NOVA")
                            .font(.novaDisplay(36))
                    }

                    Spacer()

                    Text(dashboardLocationText())
                        .font(.novaMono(15))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .overlay {
                            Rectangle().stroke(store.theme.borderColor, lineWidth: 1)
                        }
                }

                // Big time block centres itself in the tall column.
                Spacer(minLength: 24)

                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let currentWeekday = dashboardWeekdayIndex(timeline.date)
                    VStack(spacing: 9) {
                        Text(timeText(timeline.date))
                            .font(.novaMono(92))
                            .monospacedDigit()
                            .minimumScaleFactor(0.62)
                            .lineLimit(1)
                        Text(dashboardDateText(timeline.date))
                            .font(.novaMono(34))
                            .minimumScaleFactor(0.72)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            ForEach(Array(weekdays.enumerated()), id: \.offset) { index, day in
                                Text(day)
                                    .font(.novaMono(15))
                                    .foregroundStyle(
                                        index == currentWeekday
                                            ? store.theme.clockDayText
                                            : store.theme.clockText
                                    )
                                    .frame(minWidth: 48)
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 4)
                                    .background {
                                        if index == currentWeekday {
                                            Rectangle().fill(store.theme.clockDayFill)
                                        }
                                    }
                            }
                        }
                    }
                    .foregroundStyle(store.theme.clockText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .padding(.horizontal, 22)
                    .overlay {
                        Rectangle().stroke(store.theme.borderColor, lineWidth: 1)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 560)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Zone ribbon

/// The primary zone ribbon (Lighting / Climate / Outside / Network) as a
/// vertical column of title buttons, with the expanded zone's controls growing
/// in to the right. Expanding/collapsing animates; selecting a title toggles its
/// expansion and moves focus to its first control.
private struct ZoneRibbon: View {
    @EnvironmentObject private var store: DashboardStore
    let state: DashboardState
    var focus: FocusState<DashboardFocus?>.Binding
    @Binding var expandedTopZoneID: String?
    @Binding var expandedChildZoneID: String?
    @Binding var editingFocus: DashboardFocus?
    let editMove: DashboardEditMove?
    let editCancel: DashboardEditCancel?
    let onOpenPhonoscope: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            // Zone buttons as a vertical column that evenly divides the band.
            PanelFrame {
                VStack(spacing: 12) {
                    ForEach(state.primaryZones) { zone in
                        RibbonTitleButton(
                            title: majorTitle(zone),
                            subtitle: majorSubtitle(zone, state: state),
                            focus: focus,
                            focusValue: .section(zone.id),
                            isFocused: focus.wrappedValue == .section(zone.id),
                            isExpanded: expandedTopZoneID == zone.id
                        ) {
                            let willExpand = expandedTopZoneID != zone.id
                            if willExpand {
                                expandedTopZoneID = zone.id
                            } else {
                                expandedTopZoneID = nil
                            }
                            expandedChildZoneID = nil
                            let nextFocus = willExpand ? firstFocusInsideTopZone(zone, state: state) ?? .section(zone.id) : .section(zone.id)
                            focus.wrappedValue = .section(zone.id)
                            DispatchQueue.main.async {
                                focus.wrappedValue = nextFocus
                            }
                            debugInteractionLog("\(expandedTopZoneID == zone.id ? "expanded" : "collapsed") section \(zone.id)")
                        }
                        .frame(maxHeight: .infinity)
                    }

                    RibbonTitleButton(
                        title: "PHONOSCOPE",
                        subtitle: "MUSIC VISUALISER",
                        focus: focus,
                        focusValue: .section(phonoscopeZoneID),
                        isFocused: focus.wrappedValue == .section(phonoscopeZoneID),
                        isExpanded: false,
                        action: onOpenPhonoscope
                    )
                    .frame(maxHeight: .infinity)
                }
                .frame(width: 240).frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)

            // Expanded zone's controls grow in to the right.
            if let topZone = state.zone(id: expandedTopZoneID) {
                ExpandedZoneView(
                    zone: topZone,
                    state: state,
                    focus: focus,
                    expandedChildZoneID: $expandedChildZoneID,
                    editingFocus: $editingFocus,
                    editMove: editMove,
                    editCancel: editCancel
                )
                .frame(maxHeight: .infinity)
                .transition(.asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            }
        }
        .frame(maxHeight: .infinity)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: expandedTopZoneID)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: expandedChildZoneID)
    }
}

/// Dispatches the expanded top-level zone to the correct control surface based
/// on its kind (Home → room ribbon, Climate, Outside, Network, or a plain
/// lighting zone).
private struct ExpandedZoneView: View {
    let zone: DashboardZone
    let state: DashboardState
    var focus: FocusState<DashboardFocus?>.Binding
    @Binding var expandedChildZoneID: String?
    @Binding var editingFocus: DashboardFocus?
    let editMove: DashboardEditMove?
    let editCancel: DashboardEditCancel?

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            if zone.isHomeZone {
                LightingRibbon(
                    home: zone,
                    state: state,
                    focus: focus,
                    expandedChildZoneID: $expandedChildZoneID,
                    editingFocus: $editingFocus,
                    editMove: editMove,
                    editCancel: editCancel
                )
            } else if zone.isClimateZone {
                ClimateExpandedControls(zone: zone, state: state, focus: focus, editingFocus: $editingFocus, editMove: editMove, editCancel: editCancel)
            } else if zone.isOutsideZone {
                OutsideExpandedControls(zone: zone, weather: state.weather, focus: focus)
            } else if zone.isNetworkZone {
                NetworkStatusPanel(router: state.router, focus: focus, focusValue: .action(zone.id, "network"))
            } else {
                LightingControlPanel(zone: zone, state: state, focus: focus, editingFocus: $editingFocus, editMove: editMove, editCancel: editCancel)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Footer & loading

/// Thin status line pinned to the bottom of the band: error / sending / last
/// sync on the left, warning count on the right.
private struct FooterStatusView: View {
    @EnvironmentObject private var store: DashboardStore

    var body: some View {
        HStack {
            if let error = store.errorMessage {
                Text(error.uppercased())
                    .foregroundStyle(store.theme.highlight.color)
            } else if store.isSending {
                Text("SENDING")
                    .foregroundStyle(store.theme.highlight.color)
            } else if let generatedAt = store.state?.generatedAt {
                Text("SYNC \(generatedAt)")
                    .foregroundStyle(store.theme.muted)
            }
            Spacer()
            if let warningCount = store.state?.warnings.count, warningCount > 0 {
                Text("\(warningCount) WARNINGS")
                    .foregroundStyle(store.theme.highlight.color)
            }
        }
        .font(.novaMono(14))
        .frame(height: 28)
    }
}

/// Full-band placeholder shown before the first successful state fetch (or while
/// reconnecting), surfacing the connection error message when present.
private struct LoadingView: View {
    @EnvironmentObject private var store: DashboardStore
    let message: String?

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .scaleEffect(1.55)
            Text((message ?? "CONNECTING").uppercased())
                .font(.novaDisplay(34))
        }
        .frame(maxWidth: .infinity, minHeight: 520)
        .foregroundStyle(store.theme.text)
    }
}

// MARK: - Zone title text

/// Display title for a primary zone button (Home is branded "LIGHTING").
private func majorTitle(_ zone: DashboardZone) -> String {
    if zone.isHomeZone { return "LIGHTING" }
    return zone.name.uppercased()
}

/// One-line subtitle summarising a primary zone, shown when it is focused or
/// expanded.
private func majorSubtitle(_ zone: DashboardZone, state: DashboardState) -> String {
    if zone.isHomeZone { return "\(state.homeChildZones.count + 1) LIGHT ZONES" }
    if zone.isClimateZone { return "\(zone.climateCount) CLIMATE / \(zone.switchCount) SWITCH" }
    if zone.isOutsideZone { return "ON/OFF / WEATHER" }
    if zone.isNetworkZone { return state.router?.wanConnected == false ? "WAN DOWN" : state.router?.wanState?.uppercased() ?? "CONNECTED" }
    return zone.counts.summaryParts.joined(separator: " / ").uppercased()
}
