import Foundation
import SwiftUI

@MainActor
final class DashboardStore: ObservableObject {
    @Published var state: DashboardState?
    @Published var theme = DashboardTheme.default
    @Published private(set) var followVisualizerWhenActive = false
    // Fraction (0..1) of the screen height the horizontal control band occupies.
    // Sourced from the shared theme API's top-level `layout` block so it can be
    // tuned live; defaults to 0.6 so the layout works before the server ships it.
    @Published var layoutHeightFraction: Double = 0.6
    @Published var errorMessage: String?
    @Published var selectedZoneID: String?
    @Published var isSending = false
    @Published var activeBaseURL: URL?
    @Published var lastSyncDate: Date?
    @Published var lastCommandMessage: String?
    // Camera id currently presented full-screen, if any. Owned here (not in the
    // camera tile) so the full-screen player is hosted by the stable root view
    // and survives the zone collapsing / the tile unmounting while the modal
    // holds focus.
    @Published var fullScreenCameraID: String?
    // Status orb modules by id: seeded from the compiled-in built-ins so the
    // orb renders offline, overlaid by GET /api/orb-modules (which already
    // merges the host's built-ins with hot-dropped module files).
    @Published var orbModules: [String: OrbModule] = OrbModuleCatalog.builtinMap

    private let decoder = JSONDecoder()
    private let sourceClientID = Int.random(in: 100_000...999_999)
    private var pollingTask: Task<Void, Never>?
    private var orbModulesTask: Task<Void, Never>?
    private var configuredTheme = DashboardTheme.default
    private var visualizerColorOverride: DashboardTheme?
    private var themeTransitionTask: Task<Void, Never>?

    var selectedZone: DashboardZone? {
        guard let state else { return nil }
        if let selectedZoneID,
           let zone = state.zone(id: selectedZoneID) {
            return zone
        }
        return state.primaryZones.first
    }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        // Orb modules change rarely (a JSON drop on the host), so they poll
        // on their own slow cadence — matching the web client's 5 minutes.
        orbModulesTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshOrbModules()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    /// Resolve a theme's orb module id against the fetched catalog with the
    /// shared fallback rule (fetched -> built-in -> classic), so the orb
    /// always has something to render.
    func orbModule(id: String?) -> OrbModule? {
        OrbModuleCatalog.resolve(id: id, fetched: orbModules)
    }

    func refreshOrbModules() async {
        do {
            let (data, response) = try await get(path: "api/orb-modules")
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return
            }
            let payload = try decoder.decode(OrbModulesResponse.self, from: data)
            guard !payload.modules.isEmpty else { return }
            // Built-ins stay as the base so a partial server response can
            // never remove the offline fallbacks.
            var merged = OrbModuleCatalog.builtinMap
            for module in payload.modules {
                merged[module.id] = module
            }
            orbModules = merged
        } catch {
            // Orb modules are cosmetic; keep the last good catalog.
        }
    }

    func refresh() async {
        do {
            let (data, response) = try await get(path: "api/state")
            try validate(response: response, data: data)
            let nextState = try decoder.decode(DashboardState.self, from: data)
            state = nextState
            if selectedZoneID == nil || nextState.zone(id: selectedZoneID) == nil {
                selectedZoneID = nextState.primaryZones.first?.id
            }
            lastSyncDate = Date()
            errorMessage = nil
            await refreshTheme(sun: nextState.sun)
        } catch {
            errorMessage = error.localizedDescription
            await refreshTheme(sun: state?.sun)
        }
    }

    func refreshTheme(sun: SunStatus? = nil) async {
        do {
            let (data, response) = try await get(path: "api/theme")
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return
            }
            let payload = try decoder.decode(SharedThemeResponse.self, from: data)
            configuredTheme = DashboardTheme(sharedTheme: payload.theme?.resolved(sun: sun))
            followVisualizerWhenActive = payload.followVisualizerWhenActive == true
            if !followVisualizerWhenActive {
                visualizerColorOverride = nil
            }
            applyCurrentTheme()
            if let fraction = payload.layout?.tvHeightFraction {
                layoutHeightFraction = clamped(fraction, 0.3, 0.95)
            }
        } catch {
            // Shared theme is cosmetic; keep the last good value.
        }
    }

    func setVisualizerColorOverride(_ override: DashboardTheme?) {
        themeTransitionTask?.cancel()
        themeTransitionTask = nil
        visualizerColorOverride = followVisualizerWhenActive ? override : nil
        applyCurrentTheme()
    }

    func clearVisualizerColorOverride(duration: Double, delay: Double = 0) {
        themeTransitionTask?.cancel()
        visualizerColorOverride = nil
        guard duration > 0, theme != configuredTheme else {
            theme = configuredTheme
            return
        }

        let from = theme
        let target = configuredTheme
        themeTransitionTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
            }
            let started = Date()
            while !Task.isCancelled {
                let progress = min(1, Date().timeIntervalSince(started) / duration)
                let eased = progress * progress * (3 - 2 * progress)
                self?.theme = from.colorMixed(with: target, amount: eased)
                if progress >= 1 { break }
                try? await Task.sleep(for: .milliseconds(33))
            }
            guard !Task.isCancelled else { return }
            self?.theme = target
            self?.themeTransitionTask = nil
        }
    }

    private func applyCurrentTheme() {
        themeTransitionTask?.cancel()
        themeTransitionTask = nil
        theme = visualizerColorOverride.map {
            configuredTheme.colorMixed(with: $0, amount: 1)
        } ?? configuredTheme
    }

    func sendZoneAction(
        zoneID: String,
        action: ZoneAction,
        brightnessPct: Double? = nil,
        cursor: SpectrumCursor? = nil,
        rgb: RGBColor? = nil
    ) async {
        var body: [String: Any] = [
            "zoneId": zoneID,
            "action": action.rawValue,
            "sourceClientId": sourceClientID
        ]

        if let brightnessPct {
            body["brightnessPct"] = brightnessPct
        }
        if let cursor {
            body["cursor"] = ["x": cursor.x, "y": cursor.y]
        }
        if let rgb {
            body["rgb"] = rgb.array
        }

        do {
            isSending = true
            defer { isSending = false }
            let (data, response) = try await post(path: "api/zone", body: body)
            try validate(response: response, data: data)
            let nextState = try decoder.decode(DashboardState.self, from: data)
            state = nextState
            selectedZoneID = zoneID
            lastSyncDate = Date()
            lastCommandMessage = "\(action.rawValue) sent to \(zoneID)"
            errorMessage = nil
        } catch {
            lastCommandMessage = "\(action.rawValue) failed"
            errorMessage = error.localizedDescription
        }
    }

    func sendLightGroupAction(
        zone: DashboardZone,
        action: ZoneAction,
        brightnessPct: Double? = nil,
        cursor: SpectrumCursor? = nil,
        rgb: RGBColor? = nil
    ) async {
        guard zone.canUseLightingControls else {
            lastCommandMessage = "No lights in \(zone.name)"
            return
        }

        await sendZoneAction(
            zoneID: zone.id,
            action: action,
            brightnessPct: brightnessPct,
            cursor: cursor,
            rgb: rgb
        )
    }

    func sendEntityAction(
        entityID: String,
        domain: String,
        service: String,
        data: [String: Any] = [:],
        remember: [String: Any]? = nil,
        toast: String? = nil,
        selectedZoneID: String? = nil
    ) async {
        await sendEntityActions(
            [EntityCommand(entityID: entityID, domain: domain, service: service, data: data, remember: remember)],
            toast: toast ?? "\(service) sent",
            selectedZoneID: selectedZoneID
        )
    }

    func sendEntityActions(_ actions: [EntityCommand], toast: String, selectedZoneID: String? = nil) async {
        guard !actions.isEmpty else { return }

        do {
            isSending = true
            defer { isSending = false }

            var nextState: DashboardState?
            for action in actions {
                var body = action.body
                body["sourceClientId"] = sourceClientID
                let (data, response) = try await post(path: "api/entity", body: body)
                try validate(response: response, data: data)
                nextState = try decoder.decode(DashboardState.self, from: data)
            }

            if let nextState {
                state = nextState
            }
            if let selectedZoneID {
                self.selectedZoneID = selectedZoneID
            }
            lastSyncDate = Date()
            lastCommandMessage = toast
            errorMessage = nil
        } catch {
            lastCommandMessage = "\(toast) failed"
            errorMessage = error.localizedDescription
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard 200..<300 ~= http.statusCode else {
            if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = payload["error"] as? String {
                throw DashboardError.server(message)
            }
            throw DashboardError.server("Nova returned HTTP \(http.statusCode)")
        }
    }

    private func get(path: String) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for url in AppConfig.urls(path: path) {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 4
            do {
                let result = try await URLSession.shared.data(for: request)
                activeBaseURL = url.deletingLastPathComponent().deletingLastPathComponent()
                return result
            } catch {
                lastError = error
            }
        }
        throw lastError ?? DashboardError.server("Nova is unreachable")
    }

    private func post(path: String, body: [String: Any]) async throws -> (Data, URLResponse) {
        let payload = try JSONSerialization.data(withJSONObject: body)
        var lastError: Error?
        for url in AppConfig.urls(path: path) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 6
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload
            do {
                let result = try await URLSession.shared.data(for: request)
                activeBaseURL = url.deletingLastPathComponent().deletingLastPathComponent()
                return result
            } catch {
                lastError = error
            }
        }
        throw lastError ?? DashboardError.server("Nova is unreachable")
    }
}

struct SharedThemeResponse: Decodable {
    let followVisualizerWhenActive: Bool?
    let theme: SharedThemePayload?
    let layout: SharedLayoutConfig?
}

// Top-level layout knobs on the theme payload envelope (sibling of `theme`).
// tvHeightFraction is the fraction of screen height the Apple TV control band
// fills; everything in the band is sized to fit within it.
struct SharedLayoutConfig: Decodable {
    let tvHeightFraction: Double?
}

struct SharedThemePayload: Decodable {
    let selection: String?
    let themes: SharedThemeVariants?
    private let legacyTheme: SharedDeviceTheme

    enum CodingKeys: String, CodingKey {
        case selection
        case themes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selection = try? container.decode(String.self, forKey: .selection)
        themes = try? container.decode(SharedThemeVariants.self, forKey: .themes)
        legacyTheme = (try? SharedDeviceTheme(from: decoder)) ?? SharedDeviceTheme()
    }

    func resolved(sun: SunStatus?) -> SharedDeviceTheme? {
        if let themes {
            let variant = resolvedVariant(sun: sun)
            let resolvedTheme: SharedDeviceTheme?
            if variant == "light" {
                resolvedTheme = themes.light ?? themes.dark
            } else {
                resolvedTheme = themes.dark ?? themes.light
            }
            if let resolvedTheme, resolvedTheme.hasThemeFields {
                return resolvedTheme
            }
        }

        return legacyTheme.hasThemeFields ? legacyTheme : nil
    }

    func resolved(variant: String) -> SharedDeviceTheme? {
        guard let themes else { return resolved(sun: nil) }
        return variant == "light" ? (themes.light ?? themes.dark) : (themes.dark ?? themes.light)
    }

    private func resolvedVariant(sun: SunStatus?) -> String {
        switch selection {
        case "light":
            return "light"
        case "auto":
            return sunResolvesDark(sun) ? "dark" : "light"
        default:
            return "dark"
        }
    }
}

struct SharedThemeVariants: Decodable {
    let dark: SharedDeviceTheme?
    let light: SharedDeviceTheme?
}

struct SharedDeviceTheme: Decodable {
    var accent: SharedThemeColor? = nil
    var highlight: SharedThemeColor? = nil
    var avatar: SharedAvatarTheme? = nil
    var background: SharedThemeColor? = nil
    var backgroundEffect: SharedBackgroundEffect? = nil
    var border: SharedThemeBorder? = nil
    var clockColor: SharedThemeColor? = nil
    var titleColors: SharedThemeTitleColors? = nil
    var titleTone: String? = nil

    var hasThemeFields: Bool {
        accent != nil ||
            highlight != nil ||
            avatar != nil ||
            background != nil ||
            backgroundEffect != nil ||
            border != nil ||
            clockColor != nil ||
            titleColors != nil ||
            titleTone != nil
    }
}

struct SharedBackgroundEffect: Decodable {
    let apexGlow: Double?
    let falloffPower: Double?
    let hueSpread: Double?
    let peakIntensity: Double?
    let textureScale: Double?
    let textureUrl: String?
    let warpAmplitude: Double?
}

struct SharedThemeBorder: Decodable {
    let color: SharedThemeColor?
    let enabled: Bool?
    let opacity: Double?
}

struct SharedThemeColor: Decodable {
    let rgb: [Double]?
    let intensity: Double?
}

struct SharedThemeTitleColors: Decodable {
    let dark: SharedThemeColor?
    let light: SharedThemeColor?
}

struct SharedAvatarTheme: Decodable {
    let gradientAlert: SharedThemeColor?
    let gradientCenter: SharedThemeColor?
    let gradientOuter: SharedThemeColor?
    let gymAlertThresholdHours: Double?
    let gymNumberColor: SharedThemeColor?
    let gymNumberOpacity: Double?
    let voiceGlowColor: SharedThemeColor?
    let lineColors: [SharedThemeColor]?
    let lineOpacities: [Double]?
    let innerShadowOpacity: Double?
    // Id of the status orb module this theme renders with (see
    // OrbModules.swift). The module defines the orb's layer stack; the
    // colors above skin it. Unknown/malformed ids fall back to "classic".
    let orbModule: String?
    let orbModuleSettings: [String: [String: Double]]?
    let glass: SharedGlassSettings?
}

struct SharedGlassSettings: Decodable, Equatable {
    let enabled: Bool?
    let displace: Double?
    let localStretch: Double?
    let flipVertical: Bool?
    let refractPower: Double?
    let smoothness: Double?
    let imageBlur: Double?
    let refractionOpacity: Double?
    let clarity: Double?
    let gloss: Double?
    let shadow: Double?
    let reflection: Double?
    let drift: Double?
}

struct ThemeRGB: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    var color: Color {
        Color(red: red / 255, green: green / 255, blue: blue / 255)
    }

    var vector: SIMD4<Float> {
        SIMD4(Float(red / 255), Float(green / 255), Float(blue / 255), 1)
    }

    var luminance: Double {
        (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255
    }

    func mixed(with other: ThemeRGB, amount: Double) -> ThemeRGB {
        ThemeRGB(
            red: clamped(red + (other.red - red) * amount, 0, 255),
            green: clamped(green + (other.green - green) * amount, 0, 255),
            blue: clamped(blue + (other.blue - blue) * amount, 0, 255)
        )
    }

    func opacity(_ alpha: Double) -> Color {
        color.opacity(alpha)
    }
}

private func resolveThemeColor(_ value: SharedThemeColor?, fallback: ThemeRGB) -> ThemeRGB {
    guard let rgb = value?.rgb, rgb.count >= 3 else { return fallback }
    let intensity = clamped((value?.intensity ?? 100) / 100, 0, 1)
    return ThemeRGB(
        red: clamped(rgb[0] * intensity, 0, 255),
        green: clamped(rgb[1] * intensity, 0, 255),
        blue: clamped(rgb[2] * intensity, 0, 255)
    )
}

private func sunResolvesDark(_ sun: SunStatus?) -> Bool {
    if sun?.state == "below_horizon" { return true }
    if sun?.state == "above_horizon" { return false }

    if let nextRising = parseISODate(sun?.nextRising),
       let nextSetting = parseISODate(sun?.nextSetting) {
        return nextRising < nextSetting
    }

    let hour = Calendar.current.component(.hour, from: Date())
    return hour < 6 || hour >= 18
}

private func parseISODate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractionalFormatter.date(from: value) {
        return date
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}

struct DashboardAvatarTheme: Equatable {
    var gradientAlert: ThemeRGB
    var gradientCenter: ThemeRGB
    var gradientOuter: ThemeRGB
    var gymAlertThresholdHours: Double
    var gymNumberColor: ThemeRGB
    var gymNumberOpacity: Double
    var voiceGlowColor: ThemeRGB
    var lineColors: [ThemeRGB]
    var lineOpacities: [Double]
    // Opacity of the orb's dark inner bevel shadow. Shared config only (not
    // surfaced in any config UI); mirrors the web avatar's innerShadowOpacity.
    var innerShadowOpacity: Double
    // Status orb module id this theme renders with (see OrbModules.swift).
    var orbModule: String
    // Saved values for module-declared controls, keyed module id then setting id.
    var orbModuleSettings: [String: [String: Double]]
    // Native Metal counterpart of the web dashboard's liquid-glass overlay.
    var glass: DashboardGlassSettings

    static let `default` = DashboardAvatarTheme(
        gradientAlert: ThemeRGB(red: 0, green: 255, blue: 64),
        gradientCenter: ThemeRGB(red: 59, green: 0, blue: 161),
        gradientOuter: ThemeRGB(red: 0, green: 18, blue: 66),
        gymAlertThresholdHours: 46,
        gymNumberColor: ThemeRGB(red: 255, green: 255, blue: 255),
        gymNumberOpacity: 1,
        voiceGlowColor: ThemeRGB(red: 60, green: 220, blue: 240),
        lineColors: [
            ThemeRGB(red: 80, green: 130, blue: 255),
            ThemeRGB(red: 180, green: 95, blue: 240),
            ThemeRGB(red: 60, green: 220, blue: 240)
        ],
        lineOpacities: [1, 1, 1],
        innerShadowOpacity: 0.5,
        orbModule: "classic",
        orbModuleSettings: [:],
        glass: .default
    )

    init(
        gradientAlert: ThemeRGB,
        gradientCenter: ThemeRGB,
        gradientOuter: ThemeRGB,
        gymAlertThresholdHours: Double,
        gymNumberColor: ThemeRGB,
        gymNumberOpacity: Double,
        voiceGlowColor: ThemeRGB,
        lineColors: [ThemeRGB],
        lineOpacities: [Double],
        innerShadowOpacity: Double,
        orbModule: String,
        orbModuleSettings: [String: [String: Double]],
        glass: DashboardGlassSettings
    ) {
        self.gradientAlert = gradientAlert
        self.gradientCenter = gradientCenter
        self.gradientOuter = gradientOuter
        self.gymAlertThresholdHours = gymAlertThresholdHours
        self.gymNumberColor = gymNumberColor
        self.gymNumberOpacity = gymNumberOpacity
        self.voiceGlowColor = voiceGlowColor
        self.lineColors = lineColors
        self.lineOpacities = lineOpacities
        self.innerShadowOpacity = innerShadowOpacity
        self.orbModule = orbModule
        self.orbModuleSettings = orbModuleSettings
        self.glass = glass
    }

    init(shared: SharedAvatarTheme?) {
        let fallback = DashboardAvatarTheme.default
        let lineColorValues = shared?.lineColors ?? []
        let opacityValues = shared?.lineOpacities ?? []
        let sharedModule = shared?.orbModule ?? fallback.orbModule
        self.init(
            gradientAlert: resolveThemeColor(shared?.gradientAlert, fallback: fallback.gradientAlert),
            gradientCenter: resolveThemeColor(shared?.gradientCenter, fallback: fallback.gradientCenter),
            gradientOuter: resolveThemeColor(shared?.gradientOuter, fallback: fallback.gradientOuter),
            gymAlertThresholdHours: clamped(shared?.gymAlertThresholdHours ?? fallback.gymAlertThresholdHours, 1, 168),
            gymNumberColor: resolveThemeColor(shared?.gymNumberColor, fallback: fallback.gymNumberColor),
            gymNumberOpacity: clamped((shared?.gymNumberOpacity ?? fallback.gymNumberOpacity * 100) / 100, 0, 1),
            voiceGlowColor: resolveThemeColor(shared?.voiceGlowColor, fallback: fallback.voiceGlowColor),
            lineColors: (0..<3).map { index in
                resolveThemeColor(index < lineColorValues.count ? lineColorValues[index] : nil, fallback: fallback.lineColors[index])
            },
            lineOpacities: (0..<3).map { index in
                clamped((index < opacityValues.count ? opacityValues[index] : fallback.lineOpacities[index] * 100) / 100, 0, 1)
            },
            innerShadowOpacity: clamped(shared?.innerShadowOpacity ?? fallback.innerShadowOpacity, 0, 1),
            orbModule: isValidOrbModuleID(sharedModule) ? sharedModule : fallback.orbModule,
            orbModuleSettings: normalizeOrbModuleSettings(shared?.orbModuleSettings),
            glass: DashboardGlassSettings(shared: shared?.glass)
        )
    }

    func colorMixed(with other: DashboardAvatarTheme, amount: Double) -> DashboardAvatarTheme {
        let blend = min(1, max(0, amount))
        return DashboardAvatarTheme(
            gradientAlert: gradientAlert.mixed(with: other.gradientAlert, amount: blend),
            gradientCenter: gradientCenter.mixed(with: other.gradientCenter, amount: blend),
            gradientOuter: gradientOuter.mixed(with: other.gradientOuter, amount: blend),
            gymAlertThresholdHours: gymAlertThresholdHours,
            gymNumberColor: gymNumberColor.mixed(with: other.gymNumberColor, amount: blend),
            gymNumberOpacity: gymNumberOpacity,
            voiceGlowColor: voiceGlowColor.mixed(with: other.voiceGlowColor, amount: blend),
            lineColors: lineColors.enumerated().map { index, color in
                color.mixed(with: index < other.lineColors.count ? other.lineColors[index] : color, amount: blend)
            },
            lineOpacities: lineOpacities,
            innerShadowOpacity: innerShadowOpacity,
            orbModule: orbModule,
            orbModuleSettings: orbModuleSettings,
            glass: glass
        )
    }

}

private func normalizeOrbModuleSettings(_ value: [String: [String: Double]]?) -> [String: [String: Double]] {
    guard let value else { return [:] }
    var result: [String: [String: Double]] = [:]
    for (moduleID, group) in value where isValidOrbModuleID(moduleID) {
        var settings: [String: Double] = [:]
        for (settingID, number) in group where isValidOrbModuleID(settingID) && number.isFinite {
            settings[settingID] = number
        }
        if !settings.isEmpty {
            result[moduleID] = settings
        }
    }
    return result
}

struct DashboardGlassSettings: Equatable {
    var enabled: Bool
    var displace: Double
    var localStretch: Double
    var flipVertical: Bool
    var refractPower: Double
    var smoothness: Double
    var imageBlur: Double
    var refractionOpacity: Double
    var clarity: Double
    var gloss: Double
    var shadow: Double
    var reflection: Double
    var drift: Double

    static let `default` = DashboardGlassSettings(
        enabled: true,
        displace: 85,
        localStretch: 0,
        flipVertical: false,
        refractPower: 50,
        smoothness: 30,
        imageBlur: 0,
        refractionOpacity: 100,
        clarity: 60,
        gloss: 50,
        shadow: 50,
        reflection: 55,
        drift: 60
    )

    init(
        enabled: Bool,
        displace: Double,
        localStretch: Double,
        flipVertical: Bool,
        refractPower: Double,
        smoothness: Double,
        imageBlur: Double,
        refractionOpacity: Double,
        clarity: Double,
        gloss: Double,
        shadow: Double,
        reflection: Double,
        drift: Double
    ) {
        self.enabled = enabled
        self.displace = displace
        self.localStretch = localStretch
        self.flipVertical = flipVertical
        self.refractPower = refractPower
        self.smoothness = smoothness
        self.imageBlur = imageBlur
        self.refractionOpacity = refractionOpacity
        self.clarity = clarity
        self.gloss = gloss
        self.shadow = shadow
        self.reflection = reflection
        self.drift = drift
    }

    init(shared: SharedGlassSettings?) {
        let fallback = DashboardGlassSettings.default
        self.init(
            enabled: shared?.enabled ?? fallback.enabled,
            displace: clamped(shared?.displace ?? fallback.displace, 0, 100),
            localStretch: clamped(shared?.localStretch ?? fallback.localStretch, -100, 300),
            flipVertical: shared?.flipVertical ?? fallback.flipVertical,
            refractPower: clamped(shared?.refractPower ?? fallback.refractPower, 0, 100),
            smoothness: clamped(shared?.smoothness ?? fallback.smoothness, 0, 100),
            imageBlur: clamped(shared?.imageBlur ?? fallback.imageBlur, 0, 10),
            refractionOpacity: clamped(shared?.refractionOpacity ?? fallback.refractionOpacity, 0, 100),
            clarity: clamped(shared?.clarity ?? fallback.clarity, 0, 100),
            gloss: clamped(shared?.gloss ?? fallback.gloss, 0, 100),
            shadow: clamped(shared?.shadow ?? fallback.shadow, 0, 100),
            reflection: clamped(shared?.reflection ?? fallback.reflection, 0, 100),
            drift: clamped(shared?.drift ?? fallback.drift, 0, 100)
        )
    }
}

struct FluidBackgroundSettings: Equatable {
    var apexGlow: Double
    var falloffPower: Double
    var hueSpread: Double
    var peakIntensity: Double
    var textureScale: Double
    var textureURL: String?
    var warpAmplitude: Double

    static let `default` = FluidBackgroundSettings(
        apexGlow: 55,
        falloffPower: 125,
        hueSpread: 100,
        peakIntensity: 60,
        textureScale: 100,
        textureURL: nil,
        warpAmplitude: 120
    )

    init(apexGlow: Double, falloffPower: Double, hueSpread: Double, peakIntensity: Double, textureScale: Double, textureURL: String?, warpAmplitude: Double) {
        self.apexGlow = apexGlow
        self.falloffPower = falloffPower
        self.hueSpread = hueSpread
        self.peakIntensity = peakIntensity
        self.textureScale = textureScale
        self.textureURL = textureURL
        self.warpAmplitude = warpAmplitude
    }

    init(shared: SharedBackgroundEffect?) {
        let fallback = FluidBackgroundSettings.default
        let trimmedURL = shared?.textureUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            apexGlow: clamped(shared?.apexGlow ?? fallback.apexGlow, 0, 240),
            falloffPower: clamped(shared?.falloffPower ?? fallback.falloffPower, 80, 320),
            hueSpread: clamped(shared?.hueSpread ?? fallback.hueSpread, 0, 100),
            peakIntensity: clamped(shared?.peakIntensity ?? fallback.peakIntensity, 40, 260),
            textureScale: clamped(shared?.textureScale ?? fallback.textureScale, 25, 500),
            textureURL: (trimmedURL?.isEmpty == false) ? trimmedURL : nil,
            warpAmplitude: clamped(shared?.warpAmplitude ?? fallback.warpAmplitude, 40, 220)
        )
    }
}

struct DashboardTheme: Equatable {
    var accent: ThemeRGB
    var highlight: ThemeRGB
    var background: ThemeRGB
    var backgroundEffect: FluidBackgroundSettings
    var avatar: DashboardAvatarTheme
    var border: ThemeRGB
    var borderOpacity: Double
    var clockColor: ThemeRGB
    var titleDark: ThemeRGB
    var titleLight: ThemeRGB
    var titleTone: String

    static let `default` = DashboardTheme(
        accent: ThemeRGB(red: 97, green: 97, blue: 97),
        highlight: ThemeRGB(red: 255, green: 0, blue: 187),
        background: ThemeRGB(red: 26, green: 26, blue: 26),
        backgroundEffect: .default,
        avatar: .default,
        border: ThemeRGB(red: 255, green: 255, blue: 255),
        borderOpacity: 0.19,
        clockColor: ThemeRGB(red: 224, green: 205, blue: 154),
        titleDark: ThemeRGB(red: 42, green: 0, blue: 61),
        titleLight: ThemeRGB(red: 173, green: 173, blue: 173),
        titleTone: "auto"
    )

    init(
        accent: ThemeRGB,
        highlight: ThemeRGB,
        background: ThemeRGB,
        backgroundEffect: FluidBackgroundSettings,
        avatar: DashboardAvatarTheme,
        border: ThemeRGB,
        borderOpacity: Double,
        clockColor: ThemeRGB,
        titleDark: ThemeRGB,
        titleLight: ThemeRGB,
        titleTone: String
    ) {
        self.accent = accent
        self.highlight = highlight
        self.background = background
        self.backgroundEffect = backgroundEffect
        self.avatar = avatar
        self.border = border
        self.borderOpacity = borderOpacity
        self.clockColor = clockColor
        self.titleDark = titleDark
        self.titleLight = titleLight
        self.titleTone = titleTone
    }

    init(sharedTheme: SharedDeviceTheme?) {
        let fallback = DashboardTheme.default
        let accent = resolveThemeColor(sharedTheme?.accent, fallback: fallback.accent)
        let highlight = resolveThemeColor(sharedTheme?.highlight, fallback: fallback.highlight)
        let background = resolveThemeColor(sharedTheme?.background, fallback: fallback.background)
        let backgroundEffect = FluidBackgroundSettings(shared: sharedTheme?.backgroundEffect)
        let avatar = DashboardAvatarTheme(shared: sharedTheme?.avatar)
        let borderEnabled = sharedTheme?.border?.enabled ?? true
        let border = borderEnabled ? resolveThemeColor(sharedTheme?.border?.color, fallback: fallback.border) : accent
        let borderOpacity = borderEnabled ? clamped((sharedTheme?.border?.opacity ?? fallback.borderOpacity * 100) / 100, 0, 1) : 0.36
        let titleDark = resolveThemeColor(sharedTheme?.titleColors?.dark, fallback: fallback.titleDark)
        let titleLight = resolveThemeColor(sharedTheme?.titleColors?.light, fallback: fallback.titleLight)
        let titleTone = sharedTheme?.titleTone ?? fallback.titleTone
        let derivedClockFallback: ThemeRGB
        if titleTone == "dark" {
            derivedClockFallback = titleDark
        } else if titleTone == "light" {
            derivedClockFallback = titleLight
        } else {
            derivedClockFallback = background.luminance > 0.5 ? titleDark : titleLight
        }

        self.init(
            accent: accent,
            highlight: highlight,
            background: background,
            backgroundEffect: backgroundEffect,
            avatar: avatar,
            border: border,
            borderOpacity: borderOpacity,
            clockColor: resolveThemeColor(sharedTheme?.clockColor, fallback: derivedClockFallback),
            titleDark: titleDark,
            titleLight: titleLight,
            titleTone: titleTone
        )
    }

    func mixed(with other: DashboardTheme, amount rawAmount: Double) -> DashboardTheme {
        let amount = min(1, max(0, rawAmount))
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * amount }
        return DashboardTheme(
            accent: accent.mixed(with: other.accent, amount: amount),
            highlight: highlight.mixed(with: other.highlight, amount: amount),
            background: background.mixed(with: other.background, amount: amount),
            backgroundEffect: FluidBackgroundSettings(
                apexGlow: lerp(backgroundEffect.apexGlow, other.backgroundEffect.apexGlow),
                falloffPower: lerp(backgroundEffect.falloffPower, other.backgroundEffect.falloffPower),
                hueSpread: lerp(backgroundEffect.hueSpread, other.backgroundEffect.hueSpread),
                peakIntensity: lerp(backgroundEffect.peakIntensity, other.backgroundEffect.peakIntensity),
                textureScale: lerp(backgroundEffect.textureScale, other.backgroundEffect.textureScale),
                textureURL: nil,
                warpAmplitude: lerp(backgroundEffect.warpAmplitude, other.backgroundEffect.warpAmplitude)
            ),
            avatar: amount < 0.5 ? avatar : other.avatar,
            border: border.mixed(with: other.border, amount: amount),
            borderOpacity: lerp(borderOpacity, other.borderOpacity),
            clockColor: clockColor.mixed(with: other.clockColor, amount: amount),
            titleDark: titleDark.mixed(with: other.titleDark, amount: amount),
            titleLight: titleLight.mixed(with: other.titleLight, amount: amount),
            titleTone: amount < 0.5 ? titleTone : other.titleTone
        )
    }

    var panel: ThemeRGB {
        background.mixed(with: ThemeRGB(red: 0, green: 0, blue: 0), amount: 0.16)
    }

    var panelSoft: ThemeRGB {
        background.mixed(with: ThemeRGB(red: 255, green: 255, blue: 255), amount: 0.07)
    }

    var text: Color {
        titleColor(for: background, allowOverride: true)
    }

    var muted: Color {
        let base = titleRGB(for: background, allowOverride: true)
        return base.mixed(with: background, amount: 0.42).color
    }

    var titleOnAccent: Color {
        titleColor(for: accent, allowOverride: false)
    }

    var titleOnHighlight: Color {
        titleColor(for: highlight, allowOverride: false)
    }

    var borderColor: Color {
        border.opacity(borderOpacity)
    }

    var clockText: Color {
        clockColor.color
    }

    var clockDayFill: Color {
        titleRGB(for: background, allowOverride: true).color
    }

    var clockDayText: Color {
        background.color
    }

    private func titleColor(for rgb: ThemeRGB, allowOverride: Bool) -> Color {
        titleRGB(for: rgb, allowOverride: allowOverride).color
    }

    private func titleRGB(for rgb: ThemeRGB, allowOverride: Bool) -> ThemeRGB {
        guard allowOverride else {
            return rgb.luminance > 0.5 ? titleDark : titleLight
        }

        if titleTone == "dark" {
            return titleDark
        }
        if titleTone == "light" {
            return titleLight
        }
        return rgb.luminance > 0.5 ? titleDark : titleLight
    }

    /// Blend only colour values. Fonts, sizes, background dynamics, opacity,
    /// orb module/settings, glass and title-tone behaviour stay on the dashboard
    /// theme so a visualiser follow is always a temporary palette override.
    func colorMixed(with other: DashboardTheme, amount rawAmount: Double) -> DashboardTheme {
        let amount = min(1, max(0, rawAmount))
        return DashboardTheme(
            accent: accent.mixed(with: other.accent, amount: amount),
            highlight: highlight.mixed(with: other.highlight, amount: amount),
            background: background.mixed(with: other.background, amount: amount),
            backgroundEffect: backgroundEffect,
            avatar: avatar.colorMixed(with: other.avatar, amount: amount),
            border: border.mixed(with: other.border, amount: amount),
            borderOpacity: borderOpacity,
            clockColor: clockColor.mixed(with: other.clockColor, amount: amount),
            titleDark: titleDark.mixed(with: other.titleDark, amount: amount),
            titleLight: titleLight.mixed(with: other.titleLight, amount: amount),
            titleTone: titleTone
        )
    }
}

@MainActor
final class NovaActivityStore: ObservableObject {
    @Published var load: NovaLoad?

    private let decoder = JSONDecoder()
    private var pollingTask: Task<Void, Never>?

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refresh() async {
        do {
            let (data, response) = try await get(path: "api/nova-load")
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return
            }
            load = try decoder.decode(NovaLoad.self, from: data)
        } catch {
            load = nil
        }
    }

    private func get(path: String) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for url in AppConfig.urls(path: path) {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 3
            do {
                return try await URLSession.shared.data(for: request)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? DashboardError.server("Nova activity is unreachable")
    }
}

enum ZoneAction: String {
    case on
    case off
    case brightness
    case color
    case candlelight
    case white
}

struct EntityCommand {
    let entityID: String
    let domain: String
    let service: String
    var data: [String: Any] = [:]
    var remember: [String: Any]? = nil

    var body: [String: Any] {
        var payload: [String: Any] = [
            "entityId": entityID,
            "domain": domain,
            "service": service
        ]
        if !data.isEmpty {
            payload["data"] = data
        }
        if let remember {
            payload["remember"] = remember
        }
        return payload
    }
}

enum DashboardError: LocalizedError {
    case server(String)

    var errorDescription: String? {
        switch self {
        case .server(let message):
            message
        }
    }
}
