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
    @EnvironmentObject private var speech: VoiceSpeechStore
    let load: Double
    let listening: Bool
    let novaLoad: NovaLoad?
    let power: PowerSnapshot?
    let tasks: [TaskSummary]?
    let watchface: WatchfacePreferences?

    var body: some View {
        let resolved = OrbInfoCatalogue.resolve(store.state?.preferences?.orbInfo)
        // A clock showing seconds has to tick every second; everything else is
        // comfortable on the original 30s cadence.
        let cadence: TimeInterval = resolved.display.clockSeconds ? 1 : 30

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
                let readout = formatOrbValue(
                    resolved.module.read(sources, resolved.params),
                    resolved.display,
                    label: resolved.module.label
                )
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
                        Text(readout.text)
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
                    }
                }
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
        .accessibilityLabel(speech.phase == .idle ? "Nova status orb" : "Nova is speaking")
    }
}
