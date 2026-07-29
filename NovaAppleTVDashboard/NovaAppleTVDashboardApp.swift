import SwiftUI

@main
struct NovaAppleTVDashboardApp: App {
    @StateObject private var dashboard = DashboardStore()
    @StateObject private var activity = NovaActivityStore()
    @StateObject private var speech = VoiceSpeechStore()
    @StateObject private var phonoscope = PhonoscopeStore()

    init() {
        #if DEBUG
        ParitySelfTests.run()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            TVDashboardView()
                .environmentObject(dashboard)
                .environmentObject(activity)
                .environmentObject(speech)
                .environmentObject(phonoscope)
                .task {
                    dashboard.start()
                    activity.start()
                    speech.start()
                }
        }
    }
}
