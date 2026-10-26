import SwiftUI

struct QuickAccessColumn: View {
    @EnvironmentObject private var store: DashboardStore
    let state: DashboardState
    let focus: FocusState<DashboardFocus?>.Binding
    @Binding var editingFocus: DashboardFocus?
    let editMove: DashboardEditMove?
    let editCancel: DashboardEditCancel?
    var body: some View {
        VStack(spacing: 12) {
            if let home = state.homeZone {
                ColorEncoder(zone: home, state: state, compact: true, focus: focus,
                    editingFocus: $editingFocus, editMove: editMove, editCancel: editCancel)
            }
            if let climate = state.climateZone {
                HStack(spacing: 0) {
                    TemperatureEncoder(zone: climate, state: state, bedroom: false, compact: true, focus: focus,
                        editingFocus: $editingFocus, editMove: editMove, editCancel: editCancel)
                    TemperatureEncoder(zone: climate, state: state, bedroom: true, compact: true, focus: focus,
                        editingFocus: $editingFocus, editMove: editMove, editCancel: editCancel)
                }
            }
            if let weather = state.weather {
                VStack(spacing: 4) {
                    Label("OUTSIDE", systemImage: "cloud.sun").font(.novaDisplay(20))
                    Text(weather.temperature.map { String(format: "%.1f°", $0) } ?? "—").font(.novaDisplay(30))
                }
            }
        }
        .frame(width: 480).frame(maxHeight: .infinity)
        .background(store.theme.panel.color.opacity(0.8))
        .overlay(Rectangle().stroke(store.theme.borderColor, lineWidth: 1))
        .overlay(alignment: .leading) { Rectangle().fill(store.theme.highlight.color).frame(width: 2) }
    }
}

struct LandscapeClockColumn: View {
    @EnvironmentObject private var store: DashboardStore
    var body: some View {
        TimelineView(.periodic(from: .now, by: UITestHarness.coarseTick)) { tick in
            VStack(spacing: 12) {
                HStack {
                    Text("[O_O]").font(.novaDisplay(30))
                    Spacer()
                    Text("NOVA").font(.novaMono(12))
                }
                Spacer()
                Text(tick.date, style: .time).font(.novaDisplay(42)).monospacedDigit()
                Text(tick.date.formatted(.dateTime.day().month(.wide).year())).font(.novaDisplay(22))
                HStack(spacing: 8) {
                    ForEach(1...7, id: \.self) { day in
                        let index = day % 7 + 1
                        Text(Calendar.current.shortWeekdaySymbols[index - 1].uppercased())
                            .font(.novaMono(12))
                            .padding(3)
                            .background(Calendar.current.component(.weekday, from: tick.date) == index ? store.theme.accent.color : .clear)
                    }
                }
                Spacer()
            }
            .foregroundStyle(store.theme.clockText)
            .padding(24).frame(width: 390).frame(maxHeight: .infinity)
            .background(store.theme.panel.color.opacity(0.8))
            .overlay(Rectangle().stroke(store.theme.borderColor, lineWidth: 1))
        }
    }
}
