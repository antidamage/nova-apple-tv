import Foundation

enum AppConfig {
    /// The host set on this device (`HostSettings`), else the build default: the
    /// public build uses Nova's conventional mDNS name and contains no household
    /// addresses; installers that need more candidates can provide a
    /// `NovaDashboardBaseURLs` array in Info.plist through a private build setting.
    /// Read per request, so a host change applies on the next poll.
    static var dashboardBaseURLs: [URL] {
        HostSettings.baseURLs
    }

    static var dashboardBaseURL: URL {
        dashboardBaseURLs[0]
    }

    static func urls(path: String) -> [URL] {
        dashboardBaseURLs.compactMap { URL(string: path, relativeTo: $0.appendingPathComponent(""))?.absoluteURL }
    }

    // MARK: - Camera

    /// An optional standalone camera service. Keep its address in a private
    /// Info.plist override; the public source falls back to the dashboard's
    /// `/api/camera` proxy and contains no household hostname.
    static let cameraBaseURL: URL? = (
        Bundle.main.object(forInfoDictionaryKey: "NovaCameraBaseURL") as? String
    ).flatMap(URL.init(string:))

    /// Bearer token for the standalone camera host's LAN proxy
    /// (nocturnium-camera-proxy.py, see authentik/specs/authentik-sso.md
    /// "Camera bypass contract"). Only meaningful alongside `cameraBaseURL` —
    /// the dashboard's own same-origin `/api/camera` fallback needs no token,
    /// it attaches its own server-side. Kept in the same private Info.plist
    /// override as `cameraBaseURL`.
    static let cameraToken: String? = (
        Bundle.main.object(forInfoDictionaryKey: "NovaCameraToken") as? String
    ).flatMap { $0.isEmpty ? nil : $0 }

    /// HTTP headers to attach to any request against `cameraBaseURL` — empty
    /// when no token is configured (public builds, or the dashboard-proxy
    /// fallback, which needs none).
    static var cameraHeaders: [String: String] {
        guard let token = cameraToken else { return [:] }
        return ["Authorization": "Bearer \(token)"]
    }

    /// Build a camera resource URL, honouring `cameraBaseURL` when set and
    /// falling back to the dashboard's same-origin `/api/camera` route otherwise.
    static func cameraURL(cameraID: String, path: String) -> URL {
        if let base = cameraBaseURL {
            return base.appendingPathComponent("camera/\(cameraID)/\(path)")
        }
        return dashboardBaseURL.appendingPathComponent("api/camera/\(cameraID)/\(path)")
    }

    /// Candidate camera URLs to try in order (the remote host if configured, else
    /// every dashboard base). Used for the status side-channel.
    static func cameraURLs(cameraID: String, path: String) -> [URL] {
        if let base = cameraBaseURL {
            return [base.appendingPathComponent("camera/\(cameraID)/\(path)")]
        }
        return dashboardBaseURLs.map { $0.appendingPathComponent("api/camera/\(cameraID)/\(path)") }
    }
}

/// UI-test affordances. XCUI waits for a quiet app between interactions and
/// takes tens of seconds per remote press on this dashboard, because the band's
/// inks, the orb and the dial ticks never settle, and a press sequence can
/// outlast the encoder's five-second idle commit. A UI test run therefore
/// launches the app with `NOVA_UITEST=1` to slow the ticks and hold the idle
/// commit open long enough to observe a press sequence. The household build
/// never sets the variable, so nothing here reaches the Apple TV.
/// UI-test only: why the last dial draft ended, so a failing navigation test
/// names the frame that discarded it instead of guessing. Read by
/// `LandscapeDashboard.focusStateProbe`; written only while NOVA_UITEST is set.
/// Reasons carry no spaces ("scene-inactive+cancel") because the probe packs
/// them into one accessibility value.
enum UITestDraftLog {
    static var last = "none"
}

/// UI-test only: the channel a dial's left/right swipes have landed on, and the
/// full step order that dial walks. Read by `LandscapeDashboard.focusStateProbe`
/// so a test can assert the mode/ring order and both ends holding, instead of
/// only that a press arrived somewhere inside the dial. Written while
/// NOVA_UITEST is set; both are cleared when a draft ends.
enum UITestDialLog {
    static var channel = ""
    static var steps = ""
    /// The text of the value the selected channel is on, so a test can prove
    /// up/down turned the dial instead of merely reaching it.
    static var value = ""
    /// Advances every time a dial publishes. The accessibility tree can still
    /// hold the snapshot from before a press, so a test waits for this to move
    /// before it believes a field it read just after one.
    static var beat = 0
}

/// UI-test only: the last few focus transitions the dashboard saw, in order.
/// A press the dashboard moved shows up as one transition; a transition the TV's
/// own focus engine made on its own shows up as one the navigation never asked
/// for, which is what makes a stray move visible in the log.
enum UITestFocusLog {
    private static var trail: [String] = []
    static var recent: String { trail.joined(separator: ",") }
    static func note(_ from: String, _ to: String) {
        guard UITestHarness.isActive else { return }
        trail.append("\(from)>\(to)")
        if trail.count > 12 { trail.removeFirst(trail.count - 12) }
    }
}

enum UITestHarness {
    static let isActive = ProcessInfo.processInfo.environment["NOVA_UITEST"] == "1"
    /// Dial faces and the timer readouts only need to look current, not smooth.
    static let fineTick: TimeInterval = isActive ? 5 : 0.25
    /// The orb and the clock read fields that change on the second.
    static let coarseTick: TimeInterval = isActive ? 30 : 1
    /// How long an unlocked dial (or the orb) sits with no input before it
    /// commits its draft and locks again — the household's five seconds.
    /// A UI test run holds it open instead: XCUI can spend longer than five
    /// seconds delivering and settling a single remote press on this never-idle
    /// app, which would otherwise commit a draft mid-assertion. The lease test
    /// relaunches with `NOVA_DIAL_IDLE_COMMIT_S` to observe the timeout itself.
    static let dialIdleCommit: TimeInterval =
        ProcessInfo.processInfo.environment["NOVA_DIAL_IDLE_COMMIT_S"].flatMap(TimeInterval.init)
        ?? (isActive ? 600 : 5)
}
