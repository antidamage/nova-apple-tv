import SwiftUI
import UIKit

// The status orb at the top-left of the band. This view owns only the drawing
// surface, the load shaping, and the readout overlay; the entire draw stack
// is delegated to the theme-named status orb module (see OrbModules.swift),
// which interprets a declarative JSON document shared with the web dashboard.
//
// The readout itself is a selectable status orb info module (OrbInfo.swift) —
// gym hours, host load, the clock, the weather — configured on the dashboard
// and carried to this client on the shared state payload. This view renders
// whatever the selected module's display formats it into.

struct NovaAvatarOrb: View {
    @EnvironmentObject private var store: DashboardStore
    @EnvironmentObject private var activity: NovaActivityStore
    @EnvironmentObject private var speech: VoiceSpeechStore
    let load: Double
    let listening: Bool
    let novaLoad: NovaLoad?
    let power: PowerSnapshot?
    let tasks: [TaskSummary]?
    let watchface: WatchfacePreferences?

    var focus: FocusState<DashboardFocus?>.Binding
    @Binding var editingFocus: DashboardFocus?
    let editMove: DashboardEditMove?
    let editCancel: DashboardEditCancel?
    @State private var stackIndex = 0
    @State private var stackCount = 0
    /// Bumped on every accepted input while the stack is unlocked, so the idle
    /// timeout measures input rather than time since unlock.
    @State private var activityBeat = 0
    static let orbFocus = DashboardFocus.action("__orb", "dial")
    private var orbFocus: DashboardFocus { Self.orbFocus }
    private var editing: Bool { editingFocus == orbFocus }
    private func lock() { editingFocus = nil; stackIndex = 0 }

    var body: some View {
        let cadence: TimeInterval = UITestHarness.coarseTick

        return TimelineView(.periodic(from: .now, by: cadence)) { timeline in
            GeometryReader { geometry in
                let theme = store.theme
                let sources = OrbInfoSources(
                    now: timeline.date,
                    watchface: watchface,
                    gymAlertThresholdHours: theme.avatar.gymAlertThresholdHours,
                    novaLoad: novaLoad,
                    state: store.state,
                    power: power,
                    tasks: tasks
                )
                let selection = OrbInfoCatalogue.resolveStack(store.state?.preferences?.orbInfo, events: store.orbEvents, sources: sources, index: editing ? stackIndex : 0)
                let readout = selection.readout
                let gymAlert = readout.alert
                let speechCentered = speech.phase == .speaking
                let speechActive = speech.phase != .idle
                let frame = geometry.frame(in: .global)
                let screen = UIScreen.main.bounds
                let baseSize = max(1, min(geometry.size.width, geometry.size.height))
                let targetSize = min(screen.width, screen.height) * 0.45
                let speechScale = max(1.3, min(3, targetSize / baseSize))
                let speechOffset = CGSize(
                    width: screen.midX - frame.midX,
                    height: screen.midY - frame.midY
                )

                ZStack {
                    if let module = store.orbModule(id: theme.avatar.orbModule) {
                        MetalOrbView(
                            module: module,
                            theme: theme,
                            load: load,
                            listening: listening,
                            gymAlert: gymAlert,
                            speech: speech.snapshot,
                            speechActive: speechActive
                        )
                    }

                    if !readout.text.isEmpty {
                        VStack(spacing: 4) {
                            if let icon = selection.event?.icon {
                                ZStack {
                                    if icon.hasPrefix("text:") { Text(String(icon.dropFirst(5))).font(.novaMono(32)) }
                                    else { Image(systemName: orbEventSymbol(icon)).font(.system(size: 32, weight: .bold)) }
                                    if let fraction = selection.event?.countdownFraction {
                                        Circle().trim(from: 0, to: max(0, min(1, fraction)))
                                            .stroke(theme.avatar.gradientAlert.color, lineWidth: 3)
                                            .rotationEffect(.degrees(-90))
                                    }
                                }.frame(width: 60, height: 60)
                            }
                            Text(readout.text).font(.novaMono(selection.event == nil ? 52 : 26))
                        }
                            .font(.novaMono(52))
                            .monospacedDigit()
                            .foregroundStyle(
                                theme.avatar.gymNumberColor.color.opacity(theme.avatar.gymNumberOpacity)
                            )
                            .shadow(color: theme.background.color.opacity(0.4), radius: 3)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                            .opacity(speechActive ? 0 : 1)
                            .animation(.easeOut(duration: 0.18), value: speechActive)
                            .accessibilityLabel(readout.accessibilityLabel)
                            .id(stackIndex)
                            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                    removal: .move(edge: .leading).combined(with: .opacity)))
                    }
                }
                .animation(.easeOut(duration: 0.22), value: stackIndex)
                .overlay {
                    if editing {
                        RotaryIndicator(fraction: Double(stackIndex) / Double(max(1, selection.count - 1)),
                                        color: theme.accent.color)
                    }
                }
                .focusOutline(focus.wrappedValue == orbFocus, Circle())
                .dashboardTapTarget(focus, equals: orbFocus) {
                    if let dismiss = selection.event?.dismiss {
                        Task { await store.dismissOrbEvent(dismiss); await activity.refreshTasks() }
                    } else if editing { lock() }
                    else { editingFocus = orbFocus }
                }
                .onChange(of: timeline.date) { _, _ in
                    stackCount = selection.count
                    stackIndex = min(stackIndex, max(0, selection.count - 1))
                }
                .onAppear { stackCount = selection.count }
                .scaleEffect(speechCentered ? speechScale : 1)
                .offset(
                    x: speechCentered ? speechOffset.width : 0,
                    y: speechCentered ? speechOffset.height : 0
                )
                .animation(
                    .spring(response: speechCentered ? 0.48 : 0.52, dampingFraction: 0.86),
                    value: speechCentered
                )
                .zIndex(speechActive ? 4_000 : 0)
            }
        }
        .onChange(of: editMove) { _, move in
            guard editing, move?.focus == orbFocus, let direction = move?.direction else { return }
            activityBeat &+= 1
            withAnimation(.easeOut(duration: 0.22)) {
                stackIndex = min(max(0, stackCount - 1), max(0, stackIndex + (direction == .right || direction == .down ? 1 : -1)))
            }
        }
        .onChange(of: focus.wrappedValue) { _, next in
            if editing && next != orbFocus {
                // The focus engine moves focus on a direction press even when
                // onMoveCommand handles it. An unlocked orb holds its target
                // until a second click releases it, so it takes focus straight
                // back rather than reading the theft as leaving.
                focus.wrappedValue = orbFocus
            }
        }
        .onChange(of: editCancel) { _, cancel in
            if cancel?.focus == orbFocus { lock() }
        }
        // The stack browsing lease: idle for the household's five seconds and the
        // orb returns to priority order on its own, exactly as Select or Back does.
        .task(id: editing ? activityBeat : nil) {
            guard editing else { return }
            try? await Task.sleep(for: .seconds(UITestHarness.dialIdleCommit))
            guard !Task.isCancelled, editing else { return }
            lock()
        }
        .accessibilityLabel(speech.phase == .idle ? "Nova status orb" : "Nova is speaking")
    }
}

func orbEventSymbol(_ icon: String) -> String {
    switch icon {
    case "washing-machine": return "washer"
    case "barbell": return "dumbbell.fill"
    case "umbrella": return "umbrella.fill"
    case "lightning": return "bolt.fill"
    case "spinner": return "arrow.triangle.2.circlepath"
    case "egg": return "oval.portrait.fill"
    case "coffee": return "cup.and.saucer.fill"
    case "pill": return "pill.fill"
    case "bell": return "bell.fill"
    default: return "timer"
    }
}
