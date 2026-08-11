import Foundation
import MusicKit
import SwiftUI

@MainActor
final class PhonoscopeStore: ObservableObject {
    @Published private(set) var configuration: PhonoscopeConfiguration?
    @Published private(set) var module: PhonoscopeModule?
    @Published private(set) var signal = PhonoscopeSignalFrame.idle
    @Published private(set) var track: PhonoscopeTrackIdentity?
    @Published private(set) var analysis: PhonoscopeTrackAnalysis?
    @Published private(set) var status = "AMBIENT"
    @Published private(set) var errorMessage: String?
    @Published private(set) var visualizerTheme: DashboardTheme?
    @Published private(set) var activeColorTheme: PhonoscopeColorTheme?
    @Published private(set) var resolvedModuleSettings: [String: Double] = [:]
    @Published private(set) var driverInterpolatedSettingIDs: Set<String> = []
    @Published private(set) var messageScale = 1.0
    /// The centre image's base size, as fractions of the frame. Width is the
    /// authored axis; height is read only under a manual fit with
    /// `centreImageProportional` off. See `phonoscopeImageHalfExtent`.
    @Published private(set) var centreImageHeight = PhonoscopeCentreImage.defaultHeightPercent / 100
    @Published private(set) var centreImageWidth = PhonoscopeCentreImage.defaultHeightPercent / 100
    @Published private(set) var centreImageFit: PhonoscopeImageFit = .manual
    @Published private(set) var centreImageProportional = true
    /// Image library id to fetchable URL, from the config envelope. Serves both
    /// slots — the centre image and the background image — because it is one
    /// library keyed by id.
    private var centreImageUrls: [String: String] = [:]

    /// The centre image that is LEAVING, while a transition runs. Nil the rest
    /// of the time, which is what tells the Metal pass there is one plane.
    @Published private(set) var centreImageFromURL: URL?
    /// The transition's progress, 0 to 1, already shaped by the authored ramp.
    @Published private(set) var centreImageProgress: Double = 1
    /// How the change is being made, LATCHED when it started.
    ///
    /// The initiator owns the transition: these are the values Nova published
    /// alongside the entry change, resolved from the settings groups that were
    /// in effect when the pulse fired — the entry being left, not the one being
    /// arrived at — and they are held unchanged until the run finishes.
    @Published private(set) var centreTransition = PhonoscopeCentreTransitionParams()
    /// The image the latch is currently against, so a change can be spotted.
    private var latchedCentreImageURL: URL?
    private var centreTransitionElapsed: Double = 0
    private var centreTransitionAttack: Double = 0
    private var centreTransitionHold: Double = 0
    private var centreTransitionRelease: Double = 0.6
    /// The shape Nova published with its latest selection, waiting for the image
    /// change it describes. Nil while an older dashboard is publishing no shape
    /// at all, in which case the picture keeps the cross-fade it always had.
    private var pendingCentreTransition: PhonoscopeTransitionState?

    /// The backdrop slot, mirroring the centre's above and on its own clock:
    /// the two change at the same moment but run independently, so the backdrop
    /// can still be dissolving after the centrepiece has landed.
    @Published private(set) var backgroundImageFromURL: URL?
    @Published private(set) var backgroundImageProgress: Double = 1
    @Published private(set) var backgroundTransition = PhonoscopeCentreTransitionParams()
    private var latchedBackgroundImageURL: URL?
    private var backgroundTransitionElapsed: Double = 0
    private var backgroundTransitionAttack: Double = 0
    private var backgroundTransitionHold: Double = 0
    private var backgroundTransitionRelease: Double = 0.6
    private var pendingBackgroundTransition: PhonoscopeTransitionState?

    /// What the centre of the frame holds. Only the local Metal fallback draws
    /// this: on the streamed path it is already baked into the picture.
    enum CentreSlot: Equatable {
        case nothing
        case message(String)
        case image(URL)
    }

    /// The centre slot, resolved in the same order as `Simulation::submit` in
    /// nova-visualiser:
    ///
    ///  1. a non-blank message draws text and no image;
    ///  2. otherwise the live colour theme's image, if it supplies one;
    ///  3. otherwise nothing.
    ///
    /// Emptying the message is "stop overriding", not "show nothing". The two
    /// engines must agree on this or the fallback shows something different
    /// from the stream it replaces.
    var centreSlot: CentreSlot {
        guard let configuration else { return .nothing }
        let message = configuration.message?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !message.isEmpty { return .message(message) }

        guard let imageId = activeColorTheme?.imageId,
              let path = centreImageUrls[imageId],
              let url = URL(string: path, relativeTo: AppConfig.dashboardBaseURL)
        else { return .nothing }
        return .image(url)
    }
    /// The live theme's backdrop, or nil when it names none — which is what
    /// makes the procedural field draw. Resolved from the same library as the
    /// centre image, because it IS the same library: a theme names which entry
    /// goes where and the library has no opinion.
    ///
    /// No message clause, unlike `centreSlot`: nothing overrides the backdrop.
    var backgroundImageURL: URL? {
        guard let imageId = activeColorTheme?.backgroundImageId,
              let path = centreImageUrls[imageId]
        else { return nil }
        return URL(string: path, relativeTo: AppConfig.dashboardBaseURL)
    }
    /// Final glow overlay, already resolved for this frame.
    @Published private(set) var glowOverlay = PhonoscopeGlowOverlaySettings()
    /// Frame geometry, vignette and scene blend, resolved through the same
    /// lanes as everything else. Defaults reproduce the original letterbox.
    @Published private(set) var pictureFrame = PhonoscopePictureFrame()
    @Published private(set) var housePartyEnabled = false
    @Published private(set) var themeSwitchingPaused = false
    @Published private(set) var themeInterpolationPaused = false
    @Published private(set) var themeTransitionDurationOverride: Double?

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let player = SystemMusicPlayer.shared
    private var pollTask: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private var themeTask: Task<Void, Never>?
    private var housePartyTask: Task<Void, Never>?
    private var authorizationRequested = false
    private var lastTrackIdentity: PhonoscopeTrackIdentity?
    private var lastPollDate = Date()
    private var lastLyricIndex = -1
    private var etag: String?
    /// The playlist entry that is live. Rotation walks entries, not themes:
    /// one theme can appear several times with different settings groups.
    private var currentColorEntryID: String?
    private var currentColorThemeID: String?
    /// Nova's household alt state. Only the local fallback rotation consults
    /// it: an authoritative state arrives with `themeId` already resolved.
    private var altThemeActive = false
    /// The settings groups Nova says the live entry is running.
    private var selectedSettingsGroupIds: [String] = []
    private var themeTarget: DashboardTheme?
    private var lastThemeAdvance = Date()
    private var lastWholeThemeChange = Date()
    private var lastWholeThemeBarIndex = 0
    private var lastVariantBarIndex = 0
    private var variantBlendFrom = 0.0
    private var variantBlendTarget = 0.0
    private var variantTransitionStart = Date()
    private var currentThemeVariant: String?
    /// The cross-fade Nova published with its current selection. Authored on the
    /// `__themeChange` binding's release, so different entries can fade at
    /// different speeds.
    private var themeStateTransitionSeconds: Double?
    private var currentThemeBroadcastTransitionSeconds = 0.0
    private var housePartySessionID: String?
    private var housePartySequence = 0
    private var housePartyGeneration = 0
    private var housePartyFallbackTheme = DashboardTheme.default
    private var smoothedHousePartyLocalBrightness = 50.0
    private var smoothedHousePartyCloudBrightness = 50.0
    private var lastHousePartyFrame: HousePartyFramePayload?
    private var lastHousePartyFrameDate = Date.distantPast
    private var housePartySendInFlight = false
    private var housePartyImmediatePending = false
    private var housePartyForcePending = false
    private var songSkipInFlight = false
    private var themePausedAt: Date?
    private var themeInterpolationPausedAt: Date?
    private var manualThemeTransition: (from: DashboardTheme, to: DashboardTheme, started: Date)?
    private var themeSelectionTransitionStarted = Date.distantPast
    private var themeSelectionTransitionDuration = 0.0
    private var themeSelectionTransitionForward = true
    private var authoritativeThemeRevision = -1
    private var hasAuthoritativeThemeState = false
    /// The colour group Nova says is live. Nil only on a cold client, which is
    /// the one case that falls back to re-deriving the group from config.
    private var authoritativeGroupID: String?
    /// Per driver-slot envelope state, owned here and threaded through the
    /// shared evaluator in PhonoscopeDrivers.swift.
    private var parameterDriverStates: [String: PhonoscopeDriverSlotState] = [:]

    func enter(fallbackTheme: DashboardTheme) {
        guard pollTask == nil else { return }
        housePartyFallbackTheme = fallbackTheme
        visualizerTheme = fallbackTheme
        lastThemeAdvance = Date()
        configurationTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshConfiguration()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.authorizeIfNeeded()
            while !Task.isCancelled {
                await self.refreshPlayback()
                // Parameter drivers feed the 60 Hz simulation. Sampling them at
                // the old 4 Hz polling cadence visibly quantized otherwise
                // smooth attack/release ramps before they reached Metal.
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        themeTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.advanceTheme()
                // 60Hz. This loop now carries the colour interpolation for
                // broadcast-driven theme changes too, and at 33ms a fast
                // transition was visibly stepped.
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func leave() {
        setHousePartyEnabled(false, fallbackTheme: housePartyFallbackTheme)
        pollTask?.cancel()
        configurationTask?.cancel()
        themeTask?.cancel()
        housePartyTask?.cancel()
        pollTask = nil
        configurationTask = nil
        themeTask = nil
        housePartyTask = nil
        currentColorThemeID = nil
        activeColorTheme = nil
        resolvedModuleSettings = [:]
        driverInterpolatedSettingIDs = []
        parameterDriverStates = [:]
        currentThemeVariant = nil
        themeTarget = nil
        authoritativeThemeRevision = -1
        hasAuthoritativeThemeState = false
        authoritativeGroupID = nil
    }

    func setHousePartyEnabled(_ enabled: Bool, fallbackTheme: DashboardTheme) {
        housePartyFallbackTheme = fallbackTheme
        guard enabled != housePartyEnabled else { return }
        housePartyEnabled = enabled
        housePartyGeneration &+= 1
        let generation = housePartyGeneration
        housePartyTask?.cancel()
        housePartyTask = nil

        if enabled {
            housePartyTask = Task { [weak self] in
                await self?.runHouseParty(generation: generation)
            }
        } else if let id = housePartySessionID {
            housePartySessionID = nil
            Task { [weak self] in await self?.endHousePartySession(id: id) }
        }
    }

    func skipSong(forward: Bool) {
        guard !songSkipInFlight else { return }
        songSkipInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.songSkipInFlight = false }
            do {
                if forward {
                    try await self.player.skipToNextEntry()
                } else {
                    try await self.player.skipToPreviousEntry()
                }
                await self.refreshPlayback()
            } catch {
                self.errorMessage = forward ? "NEXT SONG UNAVAILABLE" : "PREVIOUS SONG UNAVAILABLE"
            }
        }
    }

    func togglePlayback() {
        Task { [weak self] in
            guard let self else { return }
            do {
                if self.player.state.playbackStatus == .playing {
                    self.player.pause()
                } else {
                    try await self.player.play()
                }
                await self.refreshPlayback()
            } catch {
                self.errorMessage = "PLAYBACK CONTROL UNAVAILABLE"
            }
        }
    }

    func toggleThemeSwitching() {
        let action = themeSwitchingPaused ? "resume" : "pause"
        Task { [weak self] in await self?.sendThemeCommand(action) }
    }

    /// Steps sideways to the next or previous colour theme GROUP, landing on
    /// its first entry. The sequence inside a group is left to run; only the
    /// pause button holds it.
    func stepThemeGroup(forward: Bool) {
        Task { [weak self] in
            await self?.sendThemeCommand(forward ? "next-group" : "previous-group")
        }
    }

    private func runHouseParty(generation: Int) async {
        while housePartyEnabled, generation == housePartyGeneration, !Task.isCancelled {
            do {
                var request = URLRequest(url: preferredBaseURL.appendingPathComponent("api/phonoscope/house-party/session"))
                request.httpMethod = "POST"
                request.timeoutInterval = 3
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                    throw URLError(.badServerResponse)
                }
                let session = try decoder.decode(HousePartySessionEnvelope.self, from: data)
                guard housePartyEnabled, generation == housePartyGeneration else {
                    await endHousePartySession(id: session.id)
                    return
                }
                housePartySessionID = session.id
                housePartySequence = 0
                lastHousePartyFrame = nil
                lastHousePartyFrameDate = .distantPast
                while housePartyEnabled, generation == housePartyGeneration, !Task.isCancelled {
                    if !(await transmitHousePartyFrame(sessionID: session.id)) {
                        housePartySessionID = nil
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                guard generation == housePartyGeneration else { return }
                housePartyEnabled = false
                housePartySessionID = nil
                errorMessage = "HOUSE PARTY OFFLINE"
                return
            }
            if housePartyEnabled, generation == housePartyGeneration, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func transmitHousePartyFrame(sessionID: String, force: Bool = false) async -> Bool {
        if housePartySendInFlight {
            housePartyImmediatePending = true
            housePartyForcePending = housePartyForcePending || force
            return true
        }
        housePartySendInFlight = true
        var succeeded = true
        var forceNext = force
        repeat {
            housePartyImmediatePending = false
            housePartyForcePending = false
            succeeded = await sendHousePartyFrame(sessionID: sessionID, force: forceNext)
            forceNext = housePartyForcePending
        } while succeeded && housePartyImmediatePending && housePartySessionID == sessionID
        housePartySendInFlight = false
        return succeeded
    }

    private func requestImmediateHousePartyFrame() {
        guard housePartyEnabled, let sessionID = housePartySessionID else { return }
        housePartyImmediatePending = true
        housePartyForcePending = true
        Task { [weak self] in
            _ = await self?.transmitHousePartyFrame(sessionID: sessionID, force: true)
        }
    }

    private func sendHousePartyFrame(sessionID: String, force: Bool) async -> Bool {
        // Light commands must leave before the audible beat. Local HA devices
        // need only a small head start; cloud Tuya devices need roughly a
        // second. Both predictions come from the complete cached beat timeline.
        let localRawPeak = min(1, max(signal.energy, housePartyBeatPulse(at: signal.time + 0.25)))
        let cloudRawPeak = min(1, max(signal.energy, housePartyBeatPulse(at: signal.time + 1.10)))
        let localBrightness = 5 + localRawPeak * 95
        let cloudBrightness = 5 + cloudRawPeak * 95
        // One beat is both the native fade duration and its target cadence:
        // LIFX/Tapo finish each hardware interpolation before the next target.
        let bpm = analysis?.bpm ?? signal.bpm
        let lightTransitionSeconds = max(0.08, min(2, 60 / max(20, bpm)))
        let localSmoothing = localBrightness > smoothedHousePartyLocalBrightness ? 1.0 : 0.28
        let cloudSmoothing = cloudBrightness > smoothedHousePartyCloudBrightness ? 1.0 : 0.28
        smoothedHousePartyLocalBrightness +=
            (localBrightness - smoothedHousePartyLocalBrightness) * localSmoothing
        smoothedHousePartyCloudBrightness +=
            (cloudBrightness - smoothedHousePartyCloudBrightness) * cloudSmoothing
        let theme = visualizerTheme ?? housePartyFallbackTheme
        let backgroundAverage = housePartyBackgroundAverage(theme)
        let targetRgb = [
            Int(backgroundAverage.red.rounded()),
            Int(backgroundAverage.green.rounded()),
            Int(backgroundAverage.blue.rounded()),
        ]
        let colorGroup = activeColorGroup
        let palette = activeColorTheme.map { theme in
            Dictionary(uniqueKeysWithValues: theme.colors.map { key, value in
                let rgb = value.themeRGB
                return (key, [
                    Int(rgb.red.rounded()),
                    Int(rgb.green.rounded()),
                    Int(rgb.blue.rounded()),
                ])
            })
        }
        let target = HousePartyFramePayload(
            sequence: housePartySequence,
            peakRgb: targetRgb,
            peakBrightnessPct: smoothedHousePartyLocalBrightness,
            cloudPeakBrightnessPct: smoothedHousePartyCloudBrightness,
            transitionSeconds: lightTransitionSeconds,
            hueMode: "follow",
            brightnessMode: "follow",
            ambient: !signal.playing,
            themeId: nil,
            themeVariant: currentThemeVariant,
            themeTransitionSeconds: currentThemeBroadcastTransitionSeconds,
            colorThemeId: currentColorThemeID,
            palette: palette,
            clock: track.map { currentTrack in
                HousePartyMasterClockPayload(
                    trackKey: analysis?.trackKey ?? currentTrack.appleMusicId,
                    position: signal.time,
                    duration: signal.duration,
                    playing: signal.playing,
                    sampledAtMs: Date().timeIntervalSince1970 * 1_000
                )
            }
        )
        let interpolation = 0.4
        let frame = lastHousePartyFrame.map { previous in
            HousePartyFramePayload(
                sequence: housePartySequence,
                peakRgb: zip(previous.peakRgb, target.peakRgb).map {
                    Int((Double($0.0) + (Double($0.1 - $0.0) * interpolation)).rounded())
                },
                peakBrightnessPct: target.peakBrightnessPct,
                cloudPeakBrightnessPct: target.cloudPeakBrightnessPct,
                transitionSeconds: target.transitionSeconds,
                hueMode: target.hueMode,
                brightnessMode: target.brightnessMode,
                ambient: target.ambient,
                themeId: target.themeId,
                themeVariant: target.themeVariant,
                themeTransitionSeconds: target.themeTransitionSeconds,
                colorThemeId: target.colorThemeId,
                palette: target.palette,
                clock: target.clock
            )
        } ?? target
        let changed = lastHousePartyFrame.map {
            zip($0.peakRgb, frame.peakRgb).contains { pair in abs(pair.0 - pair.1) >= 1 }
                || abs($0.peakBrightnessPct - frame.peakBrightnessPct) >= 0.75
                || abs($0.cloudPeakBrightnessPct - frame.cloudPeakBrightnessPct) >= 0.75
                || abs($0.transitionSeconds - frame.transitionSeconds) >= 0.01
                || $0.hueMode != frame.hueMode
                || $0.brightnessMode != frame.brightnessMode
                || $0.ambient != frame.ambient
                || $0.themeId != frame.themeId
                || $0.themeVariant != frame.themeVariant
                || $0.themeTransitionSeconds != frame.themeTransitionSeconds
                || $0.colorThemeId != frame.colorThemeId
                || $0.palette != frame.palette
        } ?? true
        guard force || changed || Date().timeIntervalSince(lastHousePartyFrameDate) >= 2 else { return true }
        housePartySequence &+= 1
        var request = URLRequest(url: preferredBaseURL.appendingPathComponent("api/phonoscope/house-party/session/\(sessionID)"))
        request.httpMethod = "PUT"
        request.timeoutInterval = 1.5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? encoder.encode(frame)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 202 else {
                return false
            }
            lastHousePartyFrame = frame
            lastHousePartyFrameDate = Date()
            return true
        } catch {
            // Frames are deliberately fire-and-forget. The next fresh frame is
            // more useful than retrying stale lighting output.
            return true
        }
    }

    private func housePartyBeatPulse(at position: Double) -> Double {
        let beats = analysis?.beatTimes ?? []
        if !beats.isEmpty {
            var lower = 0
            var upper = beats.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if beats[middle] <= position { lower = middle + 1 } else { upper = middle }
            }
            let index = lower - 1
            guard index >= 0 else { return 0 }
            let interval: Double
            if index + 1 < beats.count {
                interval = max(0.05, beats[index + 1] - beats[index])
            } else {
                interval = 60 / max(20, analysis?.bpm ?? signal.bpm)
            }
            let phase = max(0, min(1, (position - beats[index]) / interval))
            return pow(max(0, 1 - phase), 5)
        }
        let bpm = analysis?.bpm ?? signal.bpm
        let interval = 60 / max(20, bpm)
        let adjusted = max(0, position - (analysis?.beatOffset ?? 0))
        let phase = (adjusted / interval).truncatingRemainder(dividingBy: 1)
        return pow(max(0, 1 - phase), 5)
    }

    private func housePartyBackgroundAverage(_ theme: DashboardTheme) -> ThemeRGB {
        guard module?.id == "particle-ripples" else { return theme.background }
        // The ripple visualiser's visible central strip is the fluid background:
        // a background base with moving accent/highlight blobs. Weight that
        // rendered region only; the black letterbox above and below is excluded.
        return ThemeRGB(
            red: theme.background.red * 0.68 + theme.accent.red * 0.16 + theme.highlight.red * 0.16,
            green: theme.background.green * 0.68 + theme.accent.green * 0.16 + theme.highlight.green * 0.16,
            blue: theme.background.blue * 0.68 + theme.accent.blue * 0.16 + theme.highlight.blue * 0.16
        )
    }

    private func endHousePartySession(id: String) async {
        var request = URLRequest(url: preferredBaseURL.appendingPathComponent("api/phonoscope/house-party/session/\(id)"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 2
        _ = try? await URLSession.shared.data(for: request)
    }

    private func authorizeIfNeeded() async {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        let authorization = await MusicAuthorization.request()
        if authorization != .authorized {
            status = "APPLE MUSIC ACCESS NOT GRANTED"
        }
    }

    func refreshConfiguration() async {
        do {
            var request = URLRequest(url: preferredBaseURL.appendingPathComponent("api/phonoscope/config"))
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 304 { return }
            guard 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
            let envelope = try decoder.decode(PhonoscopeConfigurationEnvelope.self, from: data)
            let previousGroup = activeColorGroup?.id
            let previousColorGroup = activeColorGroup
            let previousPreviewEntryID = configuration?.editorPreviewColorEntryId
            let changed = configuration?.activeModuleId != envelope.config.activeModuleId
                || configuration?.activeModuleVersion != envelope.config.activeModuleVersion
            configuration = envelope.config
            centreImageUrls = envelope.centreImageUrls ?? [:]
            etag = http.value(forHTTPHeaderField: "ETag")
            if changed || module == nil {
                await loadModule(id: envelope.config.activeModuleId, version: envelope.config.activeModuleVersion)
            }
            if currentColorEntryID == nil
                || previousGroup != activeColorGroup?.id
                || previousColorGroup != activeColorGroup
                || previousPreviewEntryID != configuration?.editorPreviewColorEntryId {
                selectNextTheme(force: true)
            }
            refreshResolvedSettings()
            await refreshAuthoritativeTheme()
            errorMessage = nil
        } catch {
            if configuration == nil { errorMessage = "PHONOSCOPE CONFIG OFFLINE" }
        }
    }

    private func refreshAuthoritativeTheme() async {
        do {
            var request = URLRequest(url: preferredBaseURL.appendingPathComponent("api/phonoscope/theme"))
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 2
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                throw URLError(.badServerResponse)
            }
            applyAuthoritativeTheme(try decoder.decode(PhonoscopeThemeState.self, from: data))
        } catch {
            // Preserve the last state across a short dashboard outage. Only a
            // cold client falls back to its local rotation implementation.
        }
    }

    private func sendThemeCommand(_ action: String) async {
        do {
            var request = URLRequest(url: preferredBaseURL.appendingPathComponent("api/phonoscope/theme"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 2
            request.httpBody = try encoder.encode(["action": action])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                throw URLError(.badServerResponse)
            }
            applyAuthoritativeTheme(try decoder.decode(PhonoscopeThemeState.self, from: data))
            errorMessage = nil
        } catch {
            errorMessage = "THEME CONTROL OFFLINE"
        }
    }

    private func applyAuthoritativeTheme(_ state: PhonoscopeThemeState) {
        hasAuthoritativeThemeState = true
        themeSwitchingPaused = state.paused
        // Kept current even on a revision this client already holds, so that
        // dropping back to the local fallback resumes on the right side of the
        // flip rather than on whatever it last saw.
        altThemeActive = state.altActive ?? false
        // Kept current on every reply for the same reason as the alt state, and
        // taken on trust: a remote group step and genre routing both land here,
        // and neither is something this client can re-derive from config.
        authoritativeGroupID = state.groupId.isEmpty ? nil : state.groupId
        guard state.revision != authoritativeThemeRevision else { return }
        authoritativeThemeRevision = state.revision
        guard let group = activeColorGroup else { return }
        let entry = group.entries.first(where: { $0.id == state.entryId })
        // Resolve the published theme id rather than the entry's own. They are
        // the same during normal rotation, but a solo holds the picture on a
        // theme that need not appear in this group's playlist at all, and the
        // published id already has the household's alt state applied.
        guard let selected = colorTheme(id: state.themeId)
            ?? entry.flatMap({ resolvedTheme(for: $0) })
        else { return }

        currentThemeVariant = nil
        currentColorEntryID = entry?.id
        currentColorThemeID = selected.id
        // Behaviour arrives with the colour, so a theme that shares a palette
        // with the previous entry still swaps its drivers.
        selectedSettingsGroupIds = state.settingsGroupIds ?? entry?.settingsGroupIds ?? []
        themeStateTransitionSeconds = state.transitionSeconds
        // Held until the centre image actually changes. A rotation step that
        // lands on an entry with the same image is not a transition at all, so
        // there is nothing for this to describe yet.
        pendingCentreTransition = state.transition
        pendingBackgroundTransition = state.backgroundTransition
        activeColorTheme = selected
        parameterDriverStates = [:]
        let target = dashboardTheme(for: selected)
        themeTarget = target
        currentThemeBroadcastTransitionSeconds = state.transitionSeconds
        // Only a cold client jumps straight to the endpoint; once a palette is
        // on screen `advanceTheme` eases across to the new target over the
        // broadcast transition duration.
        if visualizerTheme == nil || state.transitionSeconds <= 0 {
            visualizerTheme = target
        }
        themeTransitionDurationOverride = state.transitionSeconds
        refreshResolvedSettings()
    }

    private func loadModule(id: String, version: String) async {
        let cacheURL = moduleCacheURL(id: id, version: version)
        do {
            let url = preferredBaseURL.appendingPathComponent("api/phonoscope/modules/\(id)/\(version)/compiled")
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                throw URLError(.badServerResponse)
            }
            let decoded = try decoder.decode(PhonoscopeModule.self, from: data)
            module = decoded
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        } catch {
            if let data = try? Data(contentsOf: cacheURL),
               let cached = try? decoder.decode(PhonoscopeModule.self, from: data) {
                module = cached
            } else if module == nil {
                errorMessage = "NO VALID PHONOSCOPE MODULE"
            }
        }
    }

    private func refreshPlayback() async {
        let now = Date()
        let delta = min(1, max(0, now.timeIntervalSince(lastPollDate)))
        lastPollDate = now
        let previousSignal = signal
        var clockDiscontinuity = false
        guard MusicAuthorization.currentStatus == .authorized else {
            signal = makeSignal(position: signal.time + delta, playing: false, identity: nil, analysis: nil, delta: delta)
            refreshResolvedSettings()
            return
        }

        let entry = player.queue.currentEntry
        var nextIdentity: PhonoscopeTrackIdentity?
        if case .song(let song) = entry?.item {
            nextIdentity = PhonoscopeTrackIdentity(
                appleMusicId: song.id.rawValue,
                isrc: song.isrc,
                title: song.title,
                artist: song.artistName,
                album: song.albumTitle,
                duration: song.duration ?? 0,
                artworkUrl: song.artwork?.url(width: 1024, height: 1024)?.absoluteString,
                genreNames: song.genreNames
            )
        }

        if let nextIdentity, nextIdentity.duration > 0, nextIdentity != lastTrackIdentity {
            clockDiscontinuity = true
            lastTrackIdentity = nextIdentity
            track = nextIdentity
            analysis = nil
            lastLyricIndex = -1
            status = "RESOLVING \(nextIdentity.title.uppercased())"
            Task { [weak self] in await self?.resolveTrack(nextIdentity) }
            selectNextTheme(force: true)
        } else if nextIdentity == nil {
            clockDiscontinuity = lastTrackIdentity != nil
            lastTrackIdentity = nil
            track = nil
            analysis = nil
        }

        let playing = player.state.playbackStatus == .playing
        let position = player.playbackTime.isFinite ? player.playbackTime : signal.time + (playing ? delta : 0)
        let expectedPosition = previousSignal.time + (previousSignal.playing ? delta : 0)
        if abs(position - expectedPosition) >= 0.65 || playing != previousSignal.playing {
            clockDiscontinuity = true
        }
        signal = makeSignal(position: position, playing: playing, identity: track, analysis: analysis, delta: delta)
        refreshResolvedSettings()
        if clockDiscontinuity {
            requestImmediateHousePartyFrame()
        }
        if let track {
            status = playing ? "\(track.artist.uppercased()) — \(track.title.uppercased())" : "PAUSED — \(track.title.uppercased())"
        } else if configuration?.idleBehavior == "black" {
            status = ""
        } else {
            status = "AMBIENT — START APPLE MUSIC"
        }
    }

    private var activeColorGroup: PhonoscopeColorGroup? {
        guard let configuration else { return nil }
        if let id = authoritativeGroupID,
           let published = configuration.colorGroups?.first(where: { $0.id == id }) {
            return published
        }
        let previewGroupID = configuration.editorPreviewColorGroupId.flatMap { $0.isEmpty ? nil : $0 }
        guard let id = previewGroupID
            ?? configuration.moduleColorGroupIds?[configuration.activeModuleId]
            ?? configuration.colorGroups?.first(where: { $0.moduleId == configuration.activeModuleId })?.id
        else { return nil }
        return configuration.colorGroups?.first {
            $0.id == id && $0.moduleId == configuration.activeModuleId
        }
    }

    /// The live playlist entry, resolved against Nova's selection.
    var activeColorGroupEntry: PhonoscopeColorGroupEntry? {
        guard let group = activeColorGroup else { return nil }
        if let id = currentColorEntryID, let entry = group.entries.first(where: { $0.id == id }) {
            return entry
        }
        return group.entries.first
    }

    /// The cross-fade between playlist entries. Nova publishes the authored
    /// value with its selection; genre routing and rotation timing are both its
    /// business now, not this client's.
    var settingTransitionSeconds: Double {
        if let themeTransitionDurationOverride { return themeTransitionDurationOverride }
        if configuration?.editorPreviewColorEntryId?.isEmpty == false { return 0.05 }
        return themeStateTransitionSeconds ?? Double(configuration?.transitionMs ?? 600) / 1_000
    }

    private func selectManualTheme(forward: Bool) -> DashboardTheme? {
        let now = Date()
        let selectionInProgress = now.timeIntervalSince(themeSelectionTransitionStarted)
            < themeSelectionTransitionDuration

        func destinationIndex(current: Int?, count: Int) -> Int {
            guard let current else { return forward ? 0 : count - 1 }
            if selectionInProgress, forward == themeSelectionTransitionForward {
                return current
            }
            return (current + (forward ? 1 : -1) + count) % count
        }

        if let group = activeColorGroup {
            let candidates = group.entries
            guard !candidates.isEmpty else { return nil }
            let currentIndex = currentColorEntryID.flatMap { id in candidates.firstIndex { $0.id == id } }
            let nextIndex = destinationIndex(current: currentIndex, count: candidates.count)
            let entry = candidates[nextIndex]
            guard let next = resolvedTheme(for: entry) else { return nil }
            currentThemeVariant = nil
            currentColorEntryID = entry.id
            currentColorThemeID = next.id
            selectedSettingsGroupIds = entry.settingsGroupIds ?? []
            activeColorTheme = next
            lastWholeThemeChange = Date()
            lastWholeThemeBarIndex = signal.barIndex
            parameterDriverStates = [:]
            refreshResolvedSettings()
            themeSelectionTransitionStarted = now
            themeSelectionTransitionDuration = 1
            themeSelectionTransitionForward = forward
            return dashboardTheme(for: next)
        }

        return nil
    }

    private func selectNextTheme(force: Bool) {
        guard let group = activeColorGroup else {
            currentThemeVariant = nil
            visualizerTheme = nil
            return
        }
        let candidates = group.entries
        guard !candidates.isEmpty else {
            activeColorTheme = nil
            currentColorEntryID = nil
            currentColorThemeID = nil
            visualizerTheme = nil
            return
        }
        let entry: PhonoscopeColorGroupEntry
        if let previewID = configuration?.editorPreviewColorEntryId, !previewID.isEmpty,
           let preview = candidates.first(where: { $0.id == previewID }) {
            entry = preview
        } else if let currentColorEntryID,
                  let index = candidates.firstIndex(where: { $0.id == currentColorEntryID }) {
            entry = candidates[(index + 1) % candidates.count]
        } else {
            entry = candidates[0]
        }
        if !force, entry.id == currentColorEntryID { return }
        guard let next = resolvedTheme(for: entry) else { return }
        currentThemeVariant = nil
        currentColorEntryID = entry.id
        currentColorThemeID = next.id
        selectedSettingsGroupIds = entry.settingsGroupIds ?? []
        activeColorTheme = next
        let transition = settingTransitionSeconds
        currentThemeBroadcastTransitionSeconds = transition
        let target = dashboardTheme(for: next)
        themeTarget = target
        themeSelectionTransitionStarted = Date()
        themeSelectionTransitionDuration = max(0, transition)
        themeSelectionTransitionForward = true
        lastWholeThemeChange = Date()
        lastWholeThemeBarIndex = signal.barIndex
        parameterDriverStates = [:]
        refreshResolvedSettings()
    }

    /// Looks a colour theme up in the flat library.
    private func colorTheme(id: String) -> PhonoscopeColorTheme? {
        configuration?.colorThemes?.first { $0.id == id }
    }

    /// The theme an entry shows right now, for the local fallback rotation.
    ///
    /// The alt state is the household's and the alt link is the entry's, so an
    /// entry with no alt keeps its own colours rather than blanking, and the
    /// state stays on for the next entry that does have one. When Nova's
    /// authoritative state is arriving this is not consulted at all: `themeId`
    /// on that state is already resolved the same way.
    private func resolvedTheme(for entry: PhonoscopeColorGroupEntry) -> PhonoscopeColorTheme? {
        if altThemeActive, let altID = entry.altThemeId, !altID.isEmpty,
           let alt = colorTheme(id: altID) {
            return alt
        }
        return colorTheme(id: entry.themeId)
    }

    private func advanceTheme() {
        let now = Date()
        let delta = max(0, min(0.25, now.timeIntervalSince(lastThemeAdvance)))
        lastThemeAdvance = now

        // The dashboard owns runtime *selection*. Local rotation remains only
        // as an offline fallback for an older Nova server -- but the
        // interpolation still has to run here, because the authoritative state
        // only ever hands over a new endpoint. Returning outright meant every
        // broadcast rotation hard-cut the palette, which is what made the
        // titles and every other theme-driven colour snap.
        if hasAuthoritativeThemeState {
            if themeInterpolationPaused { return }
            if let target = themeTarget {
                let amount = phonoscopeChaseAmount(
                    delta: delta,
                    settlingDuration: max(0, currentThemeBroadcastTransitionSeconds)
                )
                visualizerTheme = (visualizerTheme ?? target).mixed(with: target, amount: amount)
            }
            // No `refreshResolvedSettings()` here: the playback loop already
            // recomputes it every 16ms in this mode.
            return
        }
        if themeInterpolationPaused { return }
        if let transition = manualThemeTransition {
            let progress = min(1, max(0, now.timeIntervalSince(transition.started)))
            let eased = progress * progress * (3 - 2 * progress)
            visualizerTheme = transition.from.mixed(with: transition.to, amount: eased)
            if progress >= 1 {
                visualizerTheme = transition.to
                manualThemeTransition = nil
                // Let the renderer consume the exact target with a zero-duration
                // update before freezing its independently interpolated palette
                // and parameter values at the same endpoint.
                themeTransitionDurationOverride = 0
                lastWholeThemeChange = now
                if themeSwitchingPaused {
                    themePausedAt = now
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(50))
                        guard let self, self.themeSwitchingPaused,
                              self.manualThemeTransition == nil else { return }
                        self.themeInterpolationPaused = true
                        self.themeTransitionDurationOverride = nil
                    }
                } else {
                    themeTransitionDurationOverride = nil
                }
            }
            return
        }
        guard !themeSwitchingPaused else { return }
        func chase(_ target: DashboardTheme, duration: Double) {
            let amount = phonoscopeChaseAmount(delta: delta, settlingDuration: duration)
            visualizerTheme = (visualizerTheme ?? target).mixed(with: target, amount: amount)
        }
        if activeColorGroup != nil {
            let preview = configuration?.editorPreviewColorEntryId?.isEmpty == false
            if let target = themeTarget {
                chase(target, duration: preview ? 0.05 : max(0, settingTransitionSeconds))
            }
            refreshResolvedSettings()
            return
        }
        visualizerTheme = themeTarget
    }


    private func dashboardTheme(for theme: PhonoscopeColorTheme) -> DashboardTheme {
        var target = housePartyFallbackTheme
        if let color = theme.colors["backgroundPrimary"]?.themeRGB { target.background = color }
        if let color = theme.colors["backgroundSecondary"]?.themeRGB {
            // Particle Ripples renders its letterboxed background through
            // FluidBackgroundView, whose blob channels are accent/highlight.
            // Keep dot palette slots exclusive to the Metal particle renderer.
            target.accent = color
            target.highlight = color
        }
        if let color = theme.colors["primaryText"]?.themeRGB { target.clockColor = color }
        if let color = theme.colors["secondaryText"]?.themeRGB {
            target.titleDark = color
            target.titleLight = color
            target.titleTone = "light"
        }
        return target
    }

    /// Resolves every driven value for this frame through the shared lane
    /// evaluator in PhonoscopeDrivers.swift.
    ///
    /// Picture-level effects are declared here because no module manifest
    /// declares them; the declarations mirror PHONOSCOPE_PICTURE_EFFECTS in the
    /// dashboard and the private settings Engine.cpp synthesises. All three
    /// must agree on every range.
    private func refreshResolvedSettings() {
        var declarations: [String: PhonoscopeEffectDeclaration] = [
            PhonoscopeEffectID.messageScale: PhonoscopeEffectDeclaration(
                id: PhonoscopeEffectID.messageScale, min: 0.1, max: 5, step: 0.1, defaultValue: 1),
            PhonoscopeEffectID.glowBlur: PhonoscopeEffectDeclaration(
                id: PhonoscopeEffectID.glowBlur, min: 0, max: 20, step: 0.1, defaultValue: 0),
            PhonoscopeEffectID.glowOpacity: PhonoscopeEffectDeclaration(
                id: PhonoscopeEffectID.glowOpacity, min: 0, max: 100, step: 1, defaultValue: 0),
            // Multiplied into the blurred copy before it is clamped; 1 is the
            // identity.
            PhonoscopeEffectID.glowOverdrive: PhonoscopeEffectDeclaration(
                id: PhonoscopeEffectID.glowOverdrive, min: 1, max: 10, step: 0.1, defaultValue: 1),
            // 0/1: clamped by default, the display-referred behaviour.
            PhonoscopeEffectID.glowClamp: PhonoscopeEffectDeclaration(
                id: PhonoscopeEffectID.glowClamp, min: 0, max: 1, step: 1, defaultValue: 1),
            // 0 screen, 1 multiply, 2 overlay, snapped to the nearest rather
            // than cross-faded. A step of 1 keeps every authored endpoint on a
            // real mode.
            PhonoscopeEffectID.glowBlend: PhonoscopeEffectDeclaration(
                id: PhonoscopeEffectID.glowBlend, min: 0,
                max: Double(PhonoscopeGlowBlendMode.modeCount - 1), step: 1, defaultValue: 0),
            // Frame geometry, as a PERCENTAGE of the render view. The defaults
            // are the fixed letterbox these replaced: a centred band one third
            // high and full width. Authored 0-100 because "33%" is what the
            // control means; `makePictureFrame` divides by 100 once, so
            // everything downstream stays in unit space.
            // The centre image's base height, as a percentage of the frame. A
            // separate axis from the scale above: this is how big the image is,
            // that is a multiplier on top of it.
            PhonoscopeEffectID.centreWidth: PhonoscopeEffectDeclaration(
                id: PhonoscopeEffectID.centreWidth, min: 0, max: 100, step: 1,
                defaultValue: PhonoscopeCentreImage.defaultHeightPercent),
            PhonoscopeEffectID.centreHeight: PhonoscopeEffectDeclaration(
                id: PhonoscopeEffectID.centreHeight, min: 0, max: 100, step: 1,
                defaultValue: PhonoscopeCentreImage.defaultHeightPercent),
            // 0 manual, 1 fit to screen, 2 fill screen. Append-only.
            PhonoscopeEffectID.centreFit: PhonoscopeEffectDeclaration(
                id: PhonoscopeEffectID.centreFit, min: 0,
                max: Double(PhonoscopeImageFit.modeCount - 1), step: 1, defaultValue: 0),
            // On by default: keeping the source's proportions is what every
            // centre image authored before this axis existed was doing.
            PhonoscopeEffectID.centreProportional: PhonoscopeEffectDeclaration(
                id: PhonoscopeEffectID.centreProportional, min: 0, max: 1, step: 1,
                defaultValue: 1),
            PhonoscopeEffectID.backgroundHeight: PhonoscopeEffectDeclaration(
                id: PhonoscopeEffectID.backgroundHeight, min: 0, max: 100, step: 1,
                defaultValue: 33),
            PhonoscopeEffectID.backgroundWidth: PhonoscopeEffectDeclaration(
                id: PhonoscopeEffectID.backgroundWidth, min: 0, max: 100, step: 1,
                defaultValue: 100),
            // 1 is the identity, so an existing band is exactly the band it was.
            PhonoscopeEffectID.backgroundScale: PhonoscopeEffectDeclaration(
                id: PhonoscopeEffectID.backgroundScale,
                min: PhonoscopeImageScale.minimum, max: PhonoscopeImageScale.maximum,
                step: 0.1, defaultValue: 1),
            PhonoscopeEffectID.backgroundFit: PhonoscopeEffectDeclaration(
                id: PhonoscopeEffectID.backgroundFit, min: 0,
                max: Double(PhonoscopeImageFit.modeCount - 1), step: 1, defaultValue: 0),
            PhonoscopeEffectID.backgroundProportional: PhonoscopeEffectDeclaration(
                id: PhonoscopeEffectID.backgroundProportional, min: 0, max: 1, step: 1,
                defaultValue: 1),
            // The four `__bgTransition*` axes are deliberately NOT declared here,
            // exactly as the centre's are not: the dashboard latches them when
            // the change fires and publishes the answer on the theme state,
            // because the initiator owns the transition and this side has no way
            // to know which entry a change started from.
            // 96% and 1 are the authored PhonoscopeEdgeVignette exactly, so an
            // undriven frame is the one that was always drawn. Size stays a
            // plain multiplier rather than a percentage because it can go past
            // 1 — that is how the vignette closes the band down to a slit.
            PhonoscopeEffectID.vignetteOpacity: PhonoscopeEffectDeclaration(
                id: PhonoscopeEffectID.vignetteOpacity, min: 0, max: 100, step: 1,
                defaultValue: 96),
            PhonoscopeEffectID.vignetteSize: PhonoscopeEffectDeclaration(
                id: PhonoscopeEffectID.vignetteSize, min: 0, max: 3, step: 0.05,
                defaultValue: 1),
            // 0 linear, 1 screen, 2 overlay, 3 multiply. Linear is the original
            // composite term and so the default.
            PhonoscopeEffectID.sceneBlend: PhonoscopeEffectDeclaration(
                id: PhonoscopeEffectID.sceneBlend, min: 0,
                max: Double(PhonoscopeSceneBlendMode.modeCount - 1), step: 1, defaultValue: 0),
        ]

        var values: [String: Double] = [:]
        if let module {
            for setting in module.settings {
                values[setting.id] = setting.default
                guard setting.updateMode != "structural" else { continue }
                declarations[setting.id] = PhonoscopeEffectDeclaration(
                    id: setting.id, min: setting.min, max: setting.max, step: setting.step,
                    defaultValue: setting.default)
            }
            if let configured = configuration?.moduleSettings[module.id] {
                values.merge(configured) { _, configured in configured }
            }
        }
        for (id, declaration) in declarations where values[id] == nil {
            values[id] = declaration.defaultValue
        }

        // Which settings groups apply is Nova's answer, arriving with the
        // selected entry. Their lanes stack and their scalars layer.
        let library = configuration?.settingsGroups ?? []
        var wanted = selectedSettingsGroupIds
        if wanted.isEmpty, let entry = activeColorGroupEntry {
            wanted = entry.settingsGroupIds ?? []
        }
        var chosen = wanted.compactMap { id in library.first { $0.id == id }?.group }
        if chosen.isEmpty, let fallback = library.first(where: { $0.isDefault ?? false })?.group {
            // Nothing named anything usable, so fall back to the group
            // everything falls back to rather than dropping every driver.
            chosen = [fallback]
        }

        let merged = mergePhonoscopeSettingsGroups(chosen)
        for (id, value) in merged.staticSettings { values[id] = value }
        let evaluation = evaluatePhonoscopeDriverLanes(
            lanes: merged.lanes, combine: merged.combine, declarations: declarations,
            frame: signal, states: &parameterDriverStates)
        for (id, value) in evaluation.values { values[id] = value }

        messageScale = values[PhonoscopeEffectID.messageScale] ?? 1
        // The centre image's base height, as a fraction. Authored 0-100 and
        // divided once here, mirroring Simulation::submit in nova-visualiser.
        centreImageHeight = min(max(
            values[PhonoscopeEffectID.centreHeight]
                ?? PhonoscopeCentreImage.defaultHeightPercent, 0), 100) / 100
        centreImageWidth = min(max(
            values[PhonoscopeEffectID.centreWidth]
                ?? PhonoscopeCentreImage.defaultHeightPercent, 0), 100) / 100
        centreImageFit = PhonoscopeImageFit(value: values[PhonoscopeEffectID.centreFit] ?? 0)
        centreImageProportional = (values[PhonoscopeEffectID.centreProportional] ?? 1) >= 0.5
        advanceCentreTransition(delta: signal.delta)
        advanceBackgroundTransition(delta: signal.delta)
        glowOverlay = PhonoscopeGlowOverlaySettings(
            blurAmount: values[PhonoscopeEffectID.glowBlur] ?? 0,
            opacity: values[PhonoscopeEffectID.glowOpacity] ?? 0,
            overdrive: values[PhonoscopeEffectID.glowOverdrive] ?? 1,
            clamped: (values[PhonoscopeEffectID.glowClamp] ?? 1) >= 0.5,
            // Mirrors nova::glowBlendModeFor.
            blendMode: PhonoscopeGlowBlendMode(driven: values[PhonoscopeEffectID.glowBlend] ?? 0))
        // The first three are authored as percentages and held as fractions.
        // The divide happens exactly here, mirroring Simulation::submit in
        // nova-visualiser, so PhonoscopePictureFrame and everything reading it
        // stays in unit space.
        pictureFrame = PhonoscopePictureFrame(
            backgroundHeight: (values[PhonoscopeEffectID.backgroundHeight] ?? 33) / 100,
            backgroundWidth: (values[PhonoscopeEffectID.backgroundWidth] ?? 100) / 100,
            // A plain multiplier rather than a percentage, so no divide.
            backgroundScale: values[PhonoscopeEffectID.backgroundScale] ?? 1,
            backgroundFit: PhonoscopeImageFit(
                value: values[PhonoscopeEffectID.backgroundFit] ?? 0),
            backgroundProportional:
                (values[PhonoscopeEffectID.backgroundProportional] ?? 1) >= 0.5,
            vignetteOpacity: (values[PhonoscopeEffectID.vignetteOpacity] ?? 96) / 100,
            vignetteSize: values[PhonoscopeEffectID.vignetteSize] ?? 1,
            // Mirrors nova::sceneBlendModeFor.
            sceneBlendMode: PhonoscopeSceneBlendMode(
                driven: values[PhonoscopeEffectID.sceneBlend] ?? 0))

        guard let module else {
            resolvedModuleSettings = [:]
            driverInterpolatedSettingIDs = []
            return
        }
        resolvedModuleSettings = values.filter { key, _ in
            module.settings.contains { $0.id == key }
        }
        driverInterpolatedSettingIDs = Set(evaluation.driven.filter { id in
            module.settings.contains { $0.id == id }
        })
    }

    /// Runs the centre image's transition: spots a change, latches how it is to
    /// be made, and walks its progress.
    ///
    /// Port of the block in `Simulation::submit` / `advanceConfiguration` that
    /// does the same in nova-visualiser, and it makes the same two decisions
    /// for the same reasons:
    ///
    ///  - The latch happens at the instant the image changes, because the entry
    ///    the change STARTS from owns the transition. Reading the published
    ///    shape again next tick would let the entry being arrived at rewrite a
    ///    transition already halfway through, since the rotation swaps the
    ///    settings groups on the way past.
    ///  - A transition that has begun always finishes, even under a pause. A
    ///    manual skip pauses the rotation, and stranding the progress at 0 would
    ///    hold the OUTGOING image on screen permanently.
    private func advanceCentreTransition(delta: Double) {
        var target: URL?
        if case .image(let url) = centreSlot { target = url }

        if target != latchedCentreImageURL {
            centreImageFromURL = latchedCentreImageURL
            latchedCentreImageURL = target
            centreTransitionElapsed = 0
            let shape = pendingCentreTransition
            centreTransitionAttack = max(0, shape?.attackSeconds ?? 0)
            centreTransitionHold = max(0, shape?.holdSeconds ?? 0)
            centreTransitionRelease = max(0, shape?.releaseSeconds ?? 0.6)
            centreTransition = shape?.params ?? PhonoscopeCentreTransitionParams()
            let length = centreTransitionAttack + centreTransitionHold + centreTransitionRelease
            // Nothing to leave from, or no time to do it in, means it is simply
            // there — a first paint should not fly on from off screen.
            centreImageProgress = (centreImageFromURL != nil && length > 0) ? 0 : 1
            if centreImageProgress >= 1 { centreImageFromURL = nil }
        }

        guard centreImageProgress < 1 else { return }
        centreTransitionElapsed += max(0, delta)
        centreImageProgress = phonoscopeTransitionRamp(
            elapsed: centreTransitionElapsed,
            attack: centreTransitionAttack,
            hold: centreTransitionHold,
            release: centreTransitionRelease)
        if centreImageProgress >= 1 { centreImageFromURL = nil }
    }

    /// The backdrop's transition, on exactly the same terms as the centre's
    /// above and on its own clock — the two slots change at the same moment but
    /// run independently, which is the whole reason they have separate axes.
    ///
    /// No message clause, unlike the centre: nothing overrides the backdrop.
    private func advanceBackgroundTransition(delta: Double) {
        let target = backgroundImageURL

        if target != latchedBackgroundImageURL {
            backgroundImageFromURL = latchedBackgroundImageURL
            latchedBackgroundImageURL = target
            backgroundTransitionElapsed = 0
            let shape = pendingBackgroundTransition
            backgroundTransitionAttack = max(0, shape?.attackSeconds ?? 0)
            backgroundTransitionHold = max(0, shape?.holdSeconds ?? 0)
            backgroundTransitionRelease = max(0, shape?.releaseSeconds ?? 0.6)
            backgroundTransition = shape?.params ?? PhonoscopeCentreTransitionParams()
            let length = backgroundTransitionAttack + backgroundTransitionHold
                + backgroundTransitionRelease
            // Nothing to leave from, or no time to do it in, means it is simply
            // there — a first paint should not fly on from off screen.
            backgroundImageProgress = (backgroundImageFromURL != nil && length > 0) ? 0 : 1
            if backgroundImageProgress >= 1 { backgroundImageFromURL = nil }
        }

        guard backgroundImageProgress < 1 else { return }
        backgroundTransitionElapsed += max(0, delta)
        backgroundImageProgress = phonoscopeTransitionRamp(
            elapsed: backgroundTransitionElapsed,
            attack: backgroundTransitionAttack,
            hold: backgroundTransitionHold,
            release: backgroundTransitionRelease)
        if backgroundImageProgress >= 1 { backgroundImageFromURL = nil }
    }

    private func resolveTrack(_ identity: PhonoscopeTrackIdentity) async {
        do {
            var request = URLRequest(url: preferredBaseURL.appendingPathComponent("api/phonoscope/tracks/resolve"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(["track": identity])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                throw URLError(.badServerResponse)
            }
            let envelope = try decoder.decode(PhonoscopeTrackAnalysisEnvelope.self, from: data)
            guard lastTrackIdentity == identity else { return }
            analysis = envelope.analysis
            requestImmediateHousePartyFrame()
        } catch {
            guard lastTrackIdentity == identity else { return }
            analysis = nil
        }
    }

    private func makeSignal(
        position: Double,
        playing: Bool,
        identity: PhonoscopeTrackIdentity?,
        analysis: PhonoscopeTrackAnalysis?,
        delta: Double
    ) -> PhonoscopeSignalFrame {
        let seed = stableSeed(identity.map { "\($0.artist)|\($0.title)|\($0.duration)" } ?? "ambient")

        // Nothing playing means nothing to visualise. This used to keep
        // synthesising beats and a full spectrum off an advancing idle
        // position, so an idle screen animated as hard as a playing one --
        // driving every audio-reactive parameter and every effect trigger for
        // no audio at all. A resting drift now comes from a driver's floor
        // rather than from a fake beat.
        //
        // PARITY: mirrors the `!playing` branch of `buildSignal` in
        // nova-visualiser/src/core/signal.cpp. See PHONOSCOPE_MODULE_SPEC.md
        // §11 -- the two engines must agree tick for tick.
        guard playing else {
            return PhonoscopeSignalFrame(
                time: position,
                delta: delta,
                duration: identity?.duration ?? 0,
                progress: 0,
                playing: false,
                // bpm/valence/quality keep their canonical idle-frame values;
                // only the audio-reactive channels are zeroed. Every field here
                // must match the C++ branch exactly or conformance diverges.
                bpm: 72,
                beatPhase: 0,
                beatPulse: 0,
                beatIndex: 0,
                barPhase: 0,
                barIndex: 0,
                downbeatPulse: 0,
                energy: 0,
                valence: 0.5,
                lyricProgress: 0,
                lyricPulse: 0,
                lyricIndex: -1,
                lyricCurrent: "",
                lyricNext: "",
                spectrum: Array(repeating: 0, count: 32),
                quality: .idle,
                trackSeed: seed
            )
        }

        let fallbackBPM = 72 + Double(seed % 61)
        let bpm = analysis?.bpm ?? fallbackBPM
        let beatLength = 60 / max(20, bpm)
        let beatIndex: Int
        let beatPhase: Double
        let beatPulse: Double
        if let beatTimes = analysis?.beatTimes, !beatTimes.isEmpty {
            var lower = 0
            var upper = beatTimes.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if beatTimes[middle] <= position { lower = middle + 1 } else { upper = middle }
            }
            let resolvedIndex = lower - 1
            if resolvedIndex >= 0 {
                beatIndex = resolvedIndex
                let nextTime = resolvedIndex + 1 < beatTimes.count
                    ? beatTimes[resolvedIndex + 1]
                    : beatTimes[resolvedIndex] + beatLength
                beatPhase = max(0, min(1, (position - beatTimes[resolvedIndex]) / max(0.05, nextTime - beatTimes[resolvedIndex])))
                beatPulse = pow(max(0, 1 - beatPhase), 5)
            } else {
                beatIndex = 0
                beatPhase = 1
                beatPulse = 0
            }
        } else {
            let adjusted = max(0, position - (analysis?.beatOffset ?? 0))
            let beatValue = adjusted / beatLength
            beatIndex = Int(floor(beatValue))
            beatPhase = beatValue - floor(beatValue)
            beatPulse = pow(max(0, 1 - beatPhase), 5)
        }
        let timeSignature = max(1, analysis?.timeSignature ?? 4)
        let barIndex = beatIndex / timeSignature
        let barPhase = (Double(beatIndex % timeSignature) + beatPhase) / Double(timeSignature)
        let downbeatPulse = beatIndex % timeSignature == 0 ? beatPulse : 0
        let lyrics = analysis?.lyrics ?? []
        var lyricIndex = -1
        for index in lyrics.indices where lyrics[index].time <= position { lyricIndex = index }
        let nextIndex = lyricIndex + 1
        let currentTime = lyricIndex >= 0 ? lyrics[lyricIndex].time : 0
        let nextTime = nextIndex < lyrics.count ? lyrics[nextIndex].time : max(currentTime + 4, identity?.duration ?? currentTime + 4)
        let lyricProgress = min(1, max(0, (position - currentTime) / max(0.01, nextTime - currentTime)))
        let lyricPulse = lyricIndex != lastLyricIndex && lyricIndex >= 0 ? 1 : max(0, signal.lyricPulse - delta * 3)
        lastLyricIndex = lyricIndex
        let energy = analysis?.energy ?? (0.25 + Double(seed % 50) / 100)
        let valence = analysis?.valence ?? (0.25 + Double((seed >> 8) % 50) / 100)
        let quality: PhonoscopeSignalQuality
        if identity == nil { quality = .idle }
        else if !(analysis?.lyrics.isEmpty ?? true) { quality = .timeline }
        else if analysis?.bpm != nil { quality = .bpm }
        else { quality = .metadata }
        let spectrum = syntheticSpectrum(
            position: position,
            beatPhase: beatPhase,
            beatPulse: beatPulse,
            energy: energy,
            seed: seed
        )
        return PhonoscopeSignalFrame(
            time: position,
            delta: delta,
            duration: identity?.duration ?? 0,
            progress: identity.map { min(1, max(0, position / max(0.01, $0.duration))) } ?? 0,
            playing: playing,
            bpm: bpm,
            beatPhase: beatPhase,
            beatPulse: beatPulse,
            beatIndex: beatIndex,
            barPhase: barPhase,
            barIndex: barIndex,
            timeSignature: timeSignature,
            downbeatPulse: downbeatPulse,
            energy: energy,
            valence: valence,
            lyricProgress: lyricProgress,
            lyricPulse: lyricPulse,
            lyricIndex: lyricIndex,
            lyricCurrent: lyricIndex >= 0 ? lyrics[lyricIndex].text : "",
            lyricNext: nextIndex < lyrics.count ? lyrics[nextIndex].text : "",
            spectrum: spectrum,
            quality: quality,
            trackSeed: seed
        )
    }

    private func syntheticSpectrum(position: Double, beatPhase: Double, beatPulse: Double, energy: Double, seed: UInt64) -> [Float] {
        (0..<32).map { index in
            let band = Double(index) / 31
            let wave = 0.5 + 0.5 * sin(position * (1.7 + band * 4.2) + Double((seed >> (index % 16)) & 0xff) * 0.017)
            let bass = exp(-band * 4) * beatPulse
            return Float(min(1, max(0, (wave * 0.35 + bass * 0.8) * (0.4 + energy))))
        }
    }

    private func stableSeed(_ value: String) -> UInt64 {
        value.utf8.reduce(1_469_598_103_934_665_603) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    private var preferredBaseURL: URL {
        AppConfig.dashboardBaseURL
    }

    private func moduleCacheURL(id: String, version: String) -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("Phonoscope", isDirectory: true)
            .appendingPathComponent("\(id)-\(version).json")
    }
}
