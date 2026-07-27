import SwiftUI

// The Outside zone plus the two read-only status panels (weather, network).
// Outside owns the exterior light toggle, the live camera tile, and a weather
// readout; weather and network are passive focusable surfaces so the remote can
// swipe onto them (scrolling them into view) without offering a Select action.

/// The expanded Outside zone: light On/Off toggle, the live camera tile, and the
/// weather readout, left→right.
struct OutsideExpandedControls: View {
    // The toggle's command goes through the store; reach it via the environment.
    @EnvironmentObject private var store: DashboardStore
    let zone: DashboardZone
    let weather: WeatherStatus?
    var focus: FocusState<DashboardFocus?>.Binding

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            if let light = zone.lightEntities.first {
                let isOn = light.state == "on"
                // On/Off as a vertical toggle styled like the aircon
                // recirculate/fresh switch, but with the indicator at ON (top)
                // when lit.
                VerticalToggleSwitch(
                    topLabel: "ON",
                    bottomLabel: "OFF",
                    isOn: isOn,
                    indicatorAtTopWhenOn: true,
                    isFocused: focus.wrappedValue == .action(zone.id, "outside-power"),
                    focus: focus,
                    focusValue: .action(zone.id, "outside-power")
                ) {
                    Task {
                        await store.sendEntityAction(
                            entityID: light.entityID,
                            domain: light.domain,
                            service: isOn ? "turn_off" : "turn_on",
                            toast: "Outside light \(isOn ? "off" : "on")",
                            selectedZoneID: zone.id
                        )
                    }
                }
                .frame(width: 150).frame(maxHeight: .infinity)
            }

            // CCTV to the left of weather, both enlarged to fill the band.
            OutsideCameraPanel(zoneID: zone.id, cameraID: "outside", focus: focus)
                .frame(width: 700).frame(maxHeight: .infinity)

            WeatherPanelTV(weather: weather, focus: focus, focusValue: .action(zone.id, "weather"))
                .frame(width: 380).frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }
}

/// Live exterior camera feed in the Outside zone, mirroring the web dashboard's
/// Outside Camera panel. Shows an always-live inline preview (an ambient feed
/// suited to an always-on wall display) and is a focusable tile: pressing
/// Select opens the canonical tvOS full-screen player (`CameraFullScreenPlayer`)
/// with native play/pause, DVR scrub, and LIVE controls. The inline preview is
/// height-capped so the whole tile fits on screen and is fully revealed by the
/// dashboard's scroll-to-focus when it gains focus.
struct OutsideCameraPanel: View {
    @EnvironmentObject private var store: DashboardStore
    let zoneID: String
    let cameraID: String
    var focus: FocusState<DashboardFocus?>.Binding

    @State private var status: CameraFeedStatus?
    @State private var streamFailed = false

    // Max height of the inline preview, so the whole panel stays within the
    // scroll viewport when centred on focus.
    private let previewHeight: CGFloat = 250

    private var focusValue: DashboardFocus {
        .action(zoneID, "camera-\(cameraID)")
    }

    private var isFocused: Bool {
        focus.wrappedValue == focusValue
    }

    private var streamURL: URL {
        // Use an optional installer-supplied camera host, otherwise the active
        // dashboard's same-origin camera proxy.
        AppConfig.cameraURL(cameraID: cameraID, path: "index.m3u8")
    }

    // Offline when the recorder reports it is not recording, or the player
    // could not establish/keep a stream.
    private var offline: Bool {
        streamFailed || status?.recording == false
    }

    private var sourceLabel: String {
        switch status?.source {
        case "device": return "LIVE FEED"
        case "demo-clock": return "PLACEHOLDER"
        default: return offline ? "NO SIGNAL" : "CONNECTING"
        }
    }

    var body: some View {
        PanelFrame(title: "OUTSIDE CAMERA") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("EXTERIOR FEED")
                        .font(.novaMono(13))
                        .foregroundStyle(store.theme.muted)
                    Spacer()
                    Text(sourceLabel)
                        .font(.novaMono(13))
                        .foregroundStyle(offline ? Color.red.opacity(0.85) : store.theme.accent.color)
                }

                ZStack {
                    // PAL S-Video capture is 4:3; letterbox it inside a
                    // height-capped black stage.
                    CameraPlayerView(url: streamURL, failed: $streamFailed)
                        .aspectRatio(4.0 / 3.0, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if offline {
                        VStack(spacing: 8) {
                            Image(systemName: "video.slash.fill")
                                .font(.system(size: 42))
                            Text("NO SIGNAL")
                                .font(.novaMono(16))
                            Text("Waiting for capture device")
                                .font(.novaMono(12))
                                .foregroundStyle(store.theme.muted)
                        }
                        .foregroundStyle(.white.opacity(0.72))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: previewHeight, maxHeight: .infinity)
                .background(Color.black)
                .clipped()
                .overlay(alignment: .topLeading) { livePill }
                .overlay(alignment: .bottomTrailing) {
                    // Affordance: only meaningful when there is a stream to open.
                    if !offline {
                        HStack(spacing: 7) {
                            Image(systemName: "play.rectangle.fill")
                            Text("SELECT FOR LIVE")
                                .font(.novaMono(12))
                        }
                        .foregroundStyle(.white.opacity(isFocused ? 0.95 : 0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.5))
                        .padding(10)
                    }
                }
                // Highlight border tracks focus, matching every other control.
                .overlay {
                    Rectangle().stroke(
                        isFocused ? store.theme.highlight.color : store.theme.borderColor,
                        lineWidth: isFocused ? 3 : 1
                    )
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        // Select opens the native full-screen player; nothing to open when there
        // is no live stream. The presentation is owned by the root view (via the
        // store) so collapsing this zone can't dismiss it.
        .dashboardTapTarget(focus, equals: focusValue) {
            guard !offline else { return }
            store.fullScreenCameraID = cameraID
        }
        .accessibilityLabel("Outside camera, \(offline ? "offline" : "live"). Open full screen.")
        .task(id: cameraID) {
            // Poll status on its own slow cadence; the player handles the stream.
            while !Task.isCancelled {
                await fetchStatus()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private var livePill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(offline ? Color.gray : Color.red)
                .frame(width: 9, height: 9)
            Text(offline ? "OFFLINE" : "LIVE")
                .font(.novaMono(12))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.45))
        .padding(10)
    }

    private func fetchStatus() async {
        for url in AppConfig.cameraURLs(cameraID: cameraID, path: "status") {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 4
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
               let decoded = try? JSONDecoder().decode(CameraFeedStatus.self, from: data) {
                status = decoded
                return
            }
        }
        // Nothing reachable: keep the last-known status; the player drives offline.
    }
}

/// Read-only weather readout: condition + "feels like", then a 2×2 grid of temp
/// / rain / wind / UV. A passive focus target (no Select action) so it can be
/// swiped onto and scrolled into view.
struct WeatherPanelTV: View {
    @EnvironmentObject private var store: DashboardStore
    let weather: WeatherStatus?
    var focus: FocusState<DashboardFocus?>.Binding
    let focusValue: DashboardFocus

    private var isFocused: Bool { focus.wrappedValue == focusValue }

    var body: some View {
        PanelFrame(title: "WEATHER") {
            if let weather {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(weather.condition.replacingOccurrences(of: "_", with: " ").uppercased())
                            .font(.novaDisplay(34))
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                        Text("FEELS \(temperatureText(weather.feelsLike))")
                            .font(.novaMono(14))
                    }

                    // 2x2 readout grid filling the rest of the vertical space.
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            ReadoutTile(title: "TEMP", value: temperatureText(weather.temperature)).frame(maxHeight: .infinity)
                            ReadoutTile(title: "RAIN", value: percentText(weather.rainChancePct)).frame(maxHeight: .infinity)
                        }
                        HStack(spacing: 12) {
                            ReadoutTile(title: "WIND", value: windText(weather)).frame(maxHeight: .infinity)
                            ReadoutTile(title: "UV", value: numberText(weather.uvIndex, digits: 1)).frame(maxHeight: .infinity)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                EmptyStatePanel(title: "WEATHER MISSING", detail: "No weather provider is available in the dashboard state.")
            }
        }
        .frame(maxHeight: .infinity)
        // Passive surface: focusable so it can be swiped onto (scrolls into
        // view) and shows a highlight border, but has no Select action.
        .overlay {
            CutCornerShape(cut: 18)
                .stroke(store.theme.highlight.color, lineWidth: 3)
                .opacity(isFocused ? 1 : 0)
        }
        .dashboardFocusTarget(focus, equals: focusValue)
    }
}

/// Read-only router/WAN status panel for the Network zone. Like the weather
/// panel it is a passive focus target with no Select action.
struct NetworkStatusPanel: View {
    @EnvironmentObject private var store: DashboardStore
    let router: RouterStatus?
    var focus: FocusState<DashboardFocus?>.Binding
    let focusValue: DashboardFocus

    private var isFocused: Bool { focus.wrappedValue == focusValue }

    var body: some View {
        PanelFrame(title: "NETWORK") {
            if let router {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(router.name.uppercased())
                            .font(.novaDisplay(32))
                        Text("WAN \(router.wanState?.uppercased() ?? "UNKNOWN")")
                            .font(.novaMono(14))
                            .foregroundStyle(router.wanConnected == false ? store.theme.highlight.color : store.theme.accent.color)
                    }
                    Spacer()
                    ReadoutTile(title: "DOWNLOAD", value: router.download?.display ?? "--")
                    ReadoutTile(title: "UPLOAD", value: router.upload?.display ?? "--")
                    ReadoutTile(title: "LINK", value: router.wanConnected == false ? "DISCONNECTED" : "CONNECTED")
                }
            } else {
                EmptyStatePanel(title: "NETWORK STATUS MISSING", detail: "Router status is not available in the dashboard state.")
            }
        }
        .frame(maxHeight: .infinity)
        // Passive surface: focusable so it can be swiped onto / scrolled into
        // view and highlighted, with no Select action.
        .overlay {
            CutCornerShape(cut: 18)
                .stroke(store.theme.highlight.color, lineWidth: 3)
                .opacity(isFocused ? 1 : 0)
        }
        .dashboardFocusTarget(focus, equals: focusValue)
    }
}
