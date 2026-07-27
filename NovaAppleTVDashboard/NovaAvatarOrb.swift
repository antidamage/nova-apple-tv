import SwiftUI
import UIKit

// The status orb at the top-left of the band. This view owns only the drawing
// surface, the load shaping, and the gym-counter overlay; the entire draw stack
// is delegated to the theme-named status orb module (see OrbModules.swift),
// which interprets a declarative JSON document shared with the web dashboard.

struct NovaAvatarOrb: View {
    @EnvironmentObject private var store: DashboardStore
    @EnvironmentObject private var speech: VoiceSpeechStore
    let load: Double
    let listening: Bool
    let watchface: WatchfacePreferences?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            GeometryReader { geometry in
                let theme = store.theme
                let gymHours = gymHoursSinceReset(watchface?.gymLastResetAt, now: timeline.date)
                let gymAlert = Double(gymHours ?? 0) >= theme.avatar.gymAlertThresholdHours
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
                            speechActive: speechActive,
                            baseURL: store.activeBaseURL ?? AppConfig.dashboardBaseURL
                        )
                    }

                    if let gymHours {
                        Text("\(gymHours)")
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
                            .accessibilityLabel("Hours since last gym visit \(gymHours)")
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

/// Whole hours since the watchface's last gym reset, or nil when there is no
/// reset timestamp. Accepts ISO-8601 with or without fractional seconds.
private func gymHoursSinceReset(_ value: String?, now: Date) -> Int? {
    guard let value else { return nil }
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let parsed = fractionalFormatter.date(from: value) ?? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }()

    guard let parsed else { return nil }
    let seconds = max(0, now.timeIntervalSince(parsed))
    return Int(seconds / 3600)
}
