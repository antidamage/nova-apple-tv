import SwiftUI

@main
struct NovaAppleTVDashboardApp: App {
    @StateObject private var dashboard = DashboardStore()
    @StateObject private var activity = NovaActivityStore()
    @StateObject private var speech = VoiceSpeechStore()
    @StateObject private var phonoscope = PhonoscopeStore()
    @StateObject private var presets = PresetPlaybackStore()
    @StateObject private var host = HostChangeMonitor()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        ParitySelfTests.run()
        HostSettingsSelfTests.run()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            TVDashboardView()
                .environmentObject(dashboard)
                .environmentObject(activity)
                .environmentObject(speech)
                .environmentObject(phonoscope)
                .environmentObject(presets)
                .task {
                    dashboard.start()
                    activity.start()
                    speech.start()
                    presets.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { host.refresh() }
                }
                .onChange(of: host.current) { _, _ in
                    // A new host: forget which base last answered and move the
                    // event stream; the polls read the host per request.
                    dashboard.activeBaseURL = nil
                    speech.stop()
                    speech.start()
                }
        }
    }
}
