import Foundation

enum AppConfig {
    /// Bootstrap-only discovery: the public build uses Nova's conventional mDNS
    /// name and contains no household addresses. Installers that need additional
    /// candidates can provide a `NovaDashboardBaseURLs` array in Info.plist
    /// through a private xcconfig or build setting.
    static let dashboardBaseURLs: [URL] = {
        let configured = Bundle.main.object(forInfoDictionaryKey: "NovaDashboardBaseURLs")
            as? [String] ?? []
        let urls = configured.compactMap(URL.init(string:))
        return urls.isEmpty ? [URL(string: "http://nova.local")!] : urls
    }()

    static var dashboardBaseURL: URL {
        dashboardBaseURLs[0]
    }

    static func urls(path: String) -> [URL] {
        dashboardBaseURLs.map { $0.appendingPathComponent(path) }
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
