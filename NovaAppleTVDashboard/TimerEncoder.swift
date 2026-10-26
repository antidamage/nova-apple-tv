import SwiftUI

struct TimerEncoder: View {
    @EnvironmentObject private var store: DashboardStore
    let focus: FocusState<DashboardFocus?>.Binding
    @Binding var editingFocus: DashboardFocus?
    let editMove: DashboardEditMove?
    let editCancel: DashboardEditCancel?
    private var icons: [TimerEncoderIcon] {
        let configured = store.state?.preferences?.orbInfo?.timerIcons ?? []
        return configured.isEmpty ? [.fallback] : configured
    }
    private var timer: OrbTimerPayload? {
        guard let timer = store.orbEvents?.timer, timer.dismissedAt == nil else { return nil }
        return timer
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: UITestHarness.coarseTick)) { tick in
            let remaining = timer.map { max(0, ($0.endsAt / 1000 - tick.date.timeIntervalSince1970) / 60) } ?? 0
            // A timer whose end belongs to its driver — the wash's — is done when
            // that driver says so, never when its own period runs out
            // (specs/power-meters.md, "The wash's timer", in nova-ha-dashboard).
            let done = timer.map { ($0.completedAt != nil) || (($0.autoComplete ?? true) && remaining <= 0) } ?? false
            // A timer running past its own period is not this dial's "OFF" — that
            // word means no timer is set. It reads a countdown at zero, as its own
            // face and the orb read.
            let status = done ? "DONE" : remaining <= 0 ? "0:00" : TimerEncoderScale.text(ceil(remaining))
            let iconIndex = icons.firstIndex { $0.code == timer?.icon } ?? 0
            let durationIndex = TimerEncoderScale.nearestIndex(remaining)
            VStack {
                Text("REMINDERS").font(.novaDisplay(28))
                RotaryEncoder(title: "TIMER",
                    subtitle: timer == nil ? "SET A COUNTDOWN" : status,
                    symbol: orbEventSymbol(icons[iconIndex].code),
                    channels: [
                        RotaryChannel(id: "icon", label: "TYPE", value: Double(iconIndex),
                            maximum: Double(icons.count - 1), kind: .selector, color: store.theme.accent.color,
                            text: { icons[min(icons.count - 1, max(0, Int($0)))].label.uppercased() }),
                        RotaryChannel(id: "duration", label: "DURATION", value: Double(durationIndex),
                            maximum: Double(TimerEncoderScale.minutes.count - 1), color: store.theme.avatar.gradientAlert.color,
                            ring: true, text: { TimerEncoderScale.text(TimerEncoderScale.minutes[Int($0)]) },
                            valueFraction: { TimerEncoderScale.fraction(TimerEncoderScale.minutes[Int($0)]) })
                    ], faceReadout: done ? "DONE" : timer == nil ? "OFF" : String(format: "%d:%02d", Int(ceil(remaining * 60)) / 60, Int(ceil(remaining * 60)) % 60),
                    countdownFraction: done ? nil : timer.map { remaining * 60_000 / max(1, $0.durationMs) },
                    commitsOnRelease: false,
                    focus: focus, focusValue: .action("__timers", "timer"),
                    editingFocus: $editingFocus, editMove: editMove, editCancel: editCancel) { changes in
                        let selected = icons[min(icons.count - 1, max(0, Int(changes["icon"] ?? Double(iconIndex))))]
                        let minutes = TimerEncoderScale.minutes[Int(changes["duration"] ?? Double(durationIndex))]
                        Task {
                            await store.sendEncoderCommand(path: "api/orb-timer", body: [
                                "command": "set", "durationMs": minutes * 60_000,
                                "icon": selected.code, "label": selected.label
                            ])
                        }
                    }
                Text("Shared with every Nova screen").font(.novaMono(14)).foregroundStyle(store.theme.muted)
            }.padding(20).frame(width: 410)
        }
    }
}
