import Foundation

/// The dashboard host the household picked on this device (`specs/host-settings.md`).
///
/// One `UserDefaults` value, written by the iOS Settings app through
/// `Settings.bundle` or by the TV's HOST modal. Empty means the build default.
/// Read on every request, so a change lands on the next poll without a relaunch.
enum HostSettings {
    static let key = "nova.host.dashboardURL"
    static let buildDefaultFallback = URL(string: "http://nova.local")!

    /// What is stored, untouched — the text the editor shows.
    static var stored: String {
        UserDefaults.standard.string(forKey: key) ?? ""
    }

    /// The stored host when it is set and valid; nil means use the build default.
    static var override: URL? {
        normalised(stored)
    }

    /// The Info.plist candidates, then `http://nova.local`.
    static let buildDefaults: [URL] = {
        let configured = Bundle.main.object(forInfoDictionaryKey: "NovaDashboardBaseURLs")
            as? [String] ?? []
        let urls = configured.compactMap(URL.init(string:))
        return urls.isEmpty ? [buildDefaultFallback] : urls
    }()

    /// A set host is the only base tried, so a wrong one fails where it can be
    /// seen instead of hiding behind a fallback.
    static var baseURLs: [URL] {
        override.map { [$0] } ?? buildDefaults
    }

    /// Trimmed, `http://` added to a bare host, one trailing slash dropped.
    /// Nil for an empty entry and for anything that is not http(s) with a host.
    static func normalised(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "http://" + value }
        if value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    enum SaveResult: Equatable { case saved, cleared, invalid }

    /// The in-app editor's save: empty clears to the build default, an invalid
    /// entry is refused and the previous value kept.
    @discardableResult
    static func save(_ text: String) -> SaveResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
            return .cleared
        }
        guard let url = normalised(trimmed) else { return .invalid }
        UserDefaults.standard.set(url.absoluteString, forKey: key)
        return .saved
    }
}

/// Notices the host changing under the app — the Settings app writing the key
/// while Nova was in the background, or the TV's HOST modal — so the one
/// long-lived connection (the voice event stream) can move to the new host.
/// Polled requests need nothing: they read the host per call.
@MainActor
final class HostChangeMonitor: ObservableObject {
    @Published private(set) var current: [URL] = HostSettings.baseURLs
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Also called when the app comes back to the foreground.
    func refresh() {
        let next = HostSettings.baseURLs
        if next != current { current = next }
    }
}

#if DEBUG
enum HostSettingsSelfTests {
    static func run() {
        assert(HostSettings.normalised("") == nil)
        assert(HostSettings.normalised("   ") == nil)
        assert(HostSettings.normalised("nova.local")?.absoluteString == "http://nova.local")
        assert(HostSettings.normalised(" nova.local:3000/ ")?.absoluteString == "http://nova.local:3000")
        assert(HostSettings.normalised("https://dash.example")?.absoluteString == "https://dash.example")
        assert(HostSettings.normalised("ftp://nova.local") == nil, "Only http and https are hosts")
        assert(HostSettings.normalised("http://") == nil, "A URL with no host is refused")
        print("[NovaTV][tests] host settings passed")
    }
}
#endif
