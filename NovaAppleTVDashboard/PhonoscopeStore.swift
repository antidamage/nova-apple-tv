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
    private var themeLibrary: [PhonoscopeThemeLibraryEntry] = []
    private var currentThemeEntry: PhonoscopeThemeGroupEntry?
    private var currentColorThemeID: String?
    private var themeTarget: DashboardTheme?
    private var lastThemeAdvance = Date()
    private var lastWholeThemeChange = Date()
    private var lastWholeThemeBarIndex = 0
    private var lastVariantBarIndex = 0
    private var variantBlendFrom = 0.0
    private var variantBlendTarget = 0.0
    private var variantTransitionStart = Date()
    private var currentThemeVariant: String?
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
    private struct ParameterDriverState {
        var current: Double
        var target: Double
        var eventKey: String
        var lastUpdated: Date
        var holdUntil: Date
        var wasAttacking: Bool
    }
    private var parameterDriverStates: [String: ParameterDriverState] = [:]

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
                try? await Task.sleep(for: .milliseconds(33))
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
        currentThemeEntry = nil
        currentColorThemeID = nil
        activeColorTheme = nil
        resolvedModuleSettings = [:]
        driverInterpolatedSettingIDs = []
        parameterDriverStates = [:]
        currentThemeVariant = nil
        themeTarget = nil
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
        let now = Date()
        themeSwitchingPaused.toggle()
        if themeSwitchingPaused {
            themePausedAt = now
            themeInterpolationPausedAt = now
            themeInterpolationPaused = true
        } else if let pausedAt = themePausedAt {
            let pauseDuration = now.timeIntervalSince(pausedAt)
            lastWholeThemeChange = lastWholeThemeChange.addingTimeInterval(pauseDuration)
            variantTransitionStart = variantTransitionStart.addingTimeInterval(pauseDuration)
            themePausedAt = nil
            if let interpolationPausedAt = themeInterpolationPausedAt,
               var transition = manualThemeTransition {
                transition.started = transition.started.addingTimeInterval(
                    now.timeIntervalSince(interpolationPausedAt)
                )
                manualThemeTransition = transition
            }
            themeInterpolationPausedAt = nil
            themeInterpolationPaused = false
        }
        lastThemeAdvance = now
    }

    func stepTheme(forward: Bool) {
        let now = Date()
        if !themeSwitchingPaused {
            themeSwitchingPaused = true
            themePausedAt = now
        }
        guard let target = selectManualTheme(forward: forward) else { return }
        let source = visualizerTheme ?? target
        themeTarget = target
        currentThemeBroadcastTransitionSeconds = 1
        manualThemeTransition = (source, target, now)
        themeTransitionDurationOverride = 1
        themeInterpolationPausedAt = nil
        themeInterpolationPaused = false
        lastThemeAdvance = now
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
        let legacyGroup = activeThemeGroup
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
            hueMode: colorGroup?.housePartyHueMode ?? legacyGroup?.housePartyHueMode ?? "follow",
            brightnessMode: colorGroup?.housePartyBrightnessMode ?? legacyGroup?.housePartyBrightnessMode ?? "follow",
            ambient: !signal.playing,
            themeId: currentThemeEntry?.themeId,
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
            let previousGroup = activeThemeGroup
            let previousColorGroup = activeColorGroup
            let previousPreviewThemeID = configuration?.editorPreviewColorThemeId
            let changed = configuration?.activeModuleId != envelope.config.activeModuleId
                || configuration?.activeModuleVersion != envelope.config.activeModuleVersion
            configuration = envelope.config
            themeLibrary = envelope.themeLibrary?.entries ?? []
            etag = http.value(forHTTPHeaderField: "ETag")
            if changed || module == nil {
                await loadModule(id: envelope.config.activeModuleId, version: envelope.config.activeModuleVersion)
            }
            if (currentThemeEntry == nil && currentColorThemeID == nil)
                || previousGroup != activeThemeGroup
                || previousColorGroup != activeColorGroup
                || previousPreviewThemeID != configuration?.editorPreviewColorThemeId {
                selectNextTheme(force: true)
            }
            refreshResolvedSettings()
            errorMessage = nil
        } catch {
            if configuration == nil { errorMessage = "PHONOSCOPE CONFIG OFFLINE" }
        }
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
            selectNextTheme(force: activeColorGroup?.changeMode == "song" || activeThemeGroup?.changeMode == "song")
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
        let previewGroupID = configuration.editorPreviewColorGroupId.flatMap { $0.isEmpty ? nil : $0 }
        guard let id = previewGroupID
            ?? configuration.moduleColorGroupIds?[configuration.activeModuleId]
            ?? configuration.colorGroups?.first(where: { $0.moduleId == configuration.activeModuleId })?.id
        else { return nil }
        return configuration.colorGroups?.first {
            $0.id == id && $0.moduleId == configuration.activeModuleId
        }
    }

    private var activeThemeGroup: PhonoscopeThemeGroup? {
        guard let configuration,
              let id = configuration.moduleThemeGroupIds?[configuration.activeModuleId]
        else { return nil }
        return configuration.themeGroups?.first { $0.id == id }
    }

    var settingTransitionSeconds: Double {
        if let themeTransitionDurationOverride { return themeTransitionDurationOverride }
        if configuration?.editorPreviewColorThemeId?.isEmpty == false { return 0.05 }
        if let group = activeColorGroup { return group.transitionSeconds }
        return activeThemeGroup?.transitionSeconds ?? Double(configuration?.transitionMs ?? 600) / 1_000
    }

    private func matchingEntries(_ group: PhonoscopeThemeGroup) -> [PhonoscopeThemeGroupEntry] {
        guard group.useGenres else { return group.themes }
        let songGenres = Set((track?.genreNames ?? []).map(normalizedGenre))
        guard !songGenres.isEmpty else { return group.themes }
        let matches = group.themes.filter { entry in
            entry.genres.contains { configured in
                let wanted = normalizedGenre(configured)
                return songGenres.contains { $0 == wanted || $0.contains(wanted) || wanted.contains($0) }
            }
        }
        return matches.isEmpty ? group.themes : matches
    }

    private func normalizedGenre(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
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
            let candidates = group.themes
            guard !candidates.isEmpty else { return nil }
            let currentIndex = currentColorThemeID.flatMap { id in candidates.firstIndex { $0.id == id } }
            let nextIndex = destinationIndex(current: currentIndex, count: candidates.count)
            let next = candidates[nextIndex]
            currentThemeEntry = nil
            currentThemeVariant = nil
            currentColorThemeID = next.id
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

        guard let group = activeThemeGroup else { return nil }
        let candidates = matchingEntries(group)
        guard !candidates.isEmpty else { return nil }
        let currentIndex = currentThemeEntry.flatMap { current in
            candidates.firstIndex { $0.themeId == current.themeId }
        }
        let nextIndex = destinationIndex(current: currentIndex, count: candidates.count)
        let next = candidates[nextIndex]
        guard let saved = themeLibrary.first(where: { $0.id == next.themeId }),
              let resolved = saved.themeSet.resolved(variant: next.baseVariant)
        else { return nil }
        currentThemeEntry = next
        currentThemeVariant = next.baseVariant
        lastWholeThemeChange = Date()
        lastWholeThemeBarIndex = signal.barIndex
        lastVariantBarIndex = signal.barIndex
        variantBlendFrom = 0
        variantBlendTarget = 0
        variantTransitionStart = Date()
        themeSelectionTransitionStarted = now
        themeSelectionTransitionDuration = 1
        themeSelectionTransitionForward = forward
        return DashboardTheme(sharedTheme: resolved)
    }

    private func selectNextTheme(force: Bool) {
        if let group = activeColorGroup {
            let candidates = group.themes
            guard !candidates.isEmpty else {
                activeColorTheme = nil
                currentColorThemeID = nil
                visualizerTheme = nil
                return
            }
            let next: PhonoscopeColorTheme
            if let previewID = configuration?.editorPreviewColorThemeId, !previewID.isEmpty,
               let preview = candidates.first(where: { $0.id == previewID }) {
                next = preview
            } else if group.order == "shuffle", candidates.count > 1 {
                next = candidates.filter { $0.id != currentColorThemeID }.randomElement() ?? candidates[0]
            } else if let currentColorThemeID,
                      let index = candidates.firstIndex(where: { $0.id == currentColorThemeID }) {
                next = candidates[(index + 1) % candidates.count]
            } else {
                next = candidates[0]
            }
            if !force, next.id == currentColorThemeID { return }
            currentThemeEntry = nil
            currentThemeVariant = nil
            currentColorThemeID = next.id
            activeColorTheme = next
            currentThemeBroadcastTransitionSeconds = group.transitionSeconds
            let target = dashboardTheme(for: next)
            themeTarget = target
            themeSelectionTransitionStarted = Date()
            themeSelectionTransitionDuration = max(0, group.transitionSeconds)
            themeSelectionTransitionForward = true
            lastWholeThemeChange = Date()
            lastWholeThemeBarIndex = signal.barIndex
            parameterDriverStates = [:]
            refreshResolvedSettings()
            return
        }
        guard let group = activeThemeGroup else {
            currentThemeEntry = nil
            currentThemeVariant = nil
            visualizerTheme = nil
            return
        }
        let candidates = matchingEntries(group)
        guard !candidates.isEmpty else {
            currentThemeVariant = nil
            visualizerTheme = nil
            return
        }
        let next: PhonoscopeThemeGroupEntry
        if group.order == "shuffle", candidates.count > 1 {
            next = candidates.filter { $0.themeId != currentThemeEntry?.themeId }.randomElement() ?? candidates[0]
        } else if let current = currentThemeEntry,
                  let index = candidates.firstIndex(where: { $0.themeId == current.themeId }) {
            next = candidates[(index + 1) % candidates.count]
        } else {
            next = candidates[0]
        }
        if !force, next.themeId == currentThemeEntry?.themeId { return }
        currentThemeEntry = next
        currentThemeVariant = next.baseVariant
        currentThemeBroadcastTransitionSeconds = group.transitionSeconds
        guard let saved = themeLibrary.first(where: { $0.id == next.themeId }),
              let resolved = saved.themeSet.resolved(variant: next.baseVariant)
        else { return }
        let target = DashboardTheme(sharedTheme: resolved)
        themeTarget = target
        themeSelectionTransitionStarted = Date()
        themeSelectionTransitionDuration = max(0, group.transitionSeconds)
        themeSelectionTransitionForward = true
        lastWholeThemeChange = Date()
        lastWholeThemeBarIndex = signal.barIndex
        lastVariantBarIndex = signal.barIndex
        variantBlendFrom = 0
        variantBlendTarget = 0
        variantTransitionStart = Date()
    }

    private func advanceTheme() {
        let now = Date()
        let delta = max(0, min(0.25, now.timeIntervalSince(lastThemeAdvance)))
        lastThemeAdvance = now
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
        if let group = activeColorGroup {
            if configuration?.editorPreviewColorThemeId?.isEmpty == false {
                if let target = themeTarget { chase(target, duration: 0.05) }
                refreshResolvedSettings()
                return
            }
            if group.changeMode == "interval",
               Date().timeIntervalSince(lastWholeThemeChange) >= group.waitSeconds + group.transitionSeconds {
                selectNextTheme(force: true)
            } else if group.changeMode == "downbeat",
                      signal.playing,
                      signal.barIndex != lastWholeThemeBarIndex {
                selectNextTheme(force: true)
            }
            if let target = themeTarget { chase(target, duration: max(0, group.transitionSeconds)) }
            refreshResolvedSettings()
            return
        }
        guard let group = activeThemeGroup else { visualizerTheme = nil; return }
        if group.changeMode == "interval",
           Date().timeIntervalSince(lastWholeThemeChange) >= group.waitSeconds + group.transitionSeconds {
            selectNextTheme(force: true)
        } else if group.changeMode == "downbeat",
                  signal.playing,
                  signal.barIndex != lastWholeThemeBarIndex {
            selectNextTheme(force: true)
        }
        guard var target = themeTarget else { return }
        if currentThemeEntry?.swapOnDownbeat == true,
           let entry = currentThemeEntry,
           let saved = themeLibrary.first(where: { $0.id == entry.themeId }),
           let opposite = saved.themeSet.resolved(variant: entry.baseVariant == "dark" ? "light" : "dark") {
            let now = Date()
            let currentDuration = variantBlendTarget == 1 ? 0.25 : 1.0
            let currentElapsed = min(1, now.timeIntervalSince(variantTransitionStart) / currentDuration)
            let currentEased = currentElapsed * currentElapsed * (3 - 2 * currentElapsed)
            var variantBlend = variantBlendFrom + (variantBlendTarget - variantBlendFrom) * currentEased
            if signal.playing, signal.barIndex != lastVariantBarIndex {
                variantBlendFrom = variantBlend
                variantBlendTarget = 1
                variantTransitionStart = now
                lastVariantBarIndex = signal.barIndex
            } else if variantBlendTarget == 1, currentElapsed >= 1 {
                variantBlendFrom = 1
                variantBlendTarget = 0
                variantTransitionStart = now
                variantBlend = 1
            } else {
                let duration = variantBlendTarget == 1 ? 0.25 : 1.0
                let elapsed = min(1, now.timeIntervalSince(variantTransitionStart) / duration)
                let eased = elapsed * elapsed * (3 - 2 * elapsed)
                variantBlend = variantBlendFrom + (variantBlendTarget - variantBlendFrom) * eased
            }
            target = target.mixed(with: DashboardTheme(sharedTheme: opposite), amount: variantBlend)
            let nextVariant = variantBlend >= 0.5
                ? (entry.baseVariant == "dark" ? "light" : "dark")
                : entry.baseVariant
            if nextVariant != currentThemeVariant {
                currentThemeVariant = nextVariant
                currentThemeBroadcastTransitionSeconds =
                    nextVariant == entry.baseVariant ? 1.0 : 0.25
            }
        } else {
            lastVariantBarIndex = signal.barIndex
            variantBlendFrom = 0
            variantBlendTarget = 0
            currentThemeVariant = currentThemeEntry?.baseVariant
            currentThemeBroadcastTransitionSeconds = group.transitionSeconds
        }
        chase(target, duration: max(0, currentThemeBroadcastTransitionSeconds))
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

    private func refreshResolvedSettings() {
        let messageScaleSetting = PhonoscopeModuleSetting(
            id: "messageScale", label: "Message scale", description: nil,
            control: "slider", min: 1, max: 3, step: 0.001, default: 1,
            affects: nil, curve: nil, options: nil, section: nil, updateMode: "smooth"
        )
        messageScale = resolvedValue(
            source: configuration?.messageScaleSource ?? PhonoscopeParameterSource(
                type: "manual", value: 1, min: nil, max: nil, cadence: nil,
                intervalSeconds: nil, transitionSeconds: nil, attackSeconds: nil, holdSeconds: nil, releaseSeconds: nil
            ),
            setting: messageScaleSetting,
            baseline: 1,
            key: "visualiser:messageScale"
        )
        guard let module else {
            resolvedModuleSettings = [:]
            driverInterpolatedSettingIDs = []
            return
        }
        var values = Dictionary(uniqueKeysWithValues: module.settings.map { ($0.id, $0.default) })
        var drivenSettingIDs: Set<String> = []
        if let configured = configuration?.moduleSettings[module.id] {
            values.merge(configured) { _, configured in configured }
        }
        if let sources = configuration?.moduleParameterSources?[module.id] {
            for setting in module.settings {
                guard let source = sources[setting.id], setting.updateMode != "structural" else { continue }
                let baseline = values[setting.id] ?? setting.default
                values[setting.id] = resolvedValue(
                    source: source,
                    setting: setting,
                    baseline: baseline,
                    key: "baseline:\(module.id):\(setting.id)"
                )
                if source.type != "manual" {
                    drivenSettingIDs.insert(setting.id)
                }
            }
        }
        guard let theme = activeColorTheme,
              let overrides = theme.parameterOverrides[module.id]
        else {
            resolvedModuleSettings = values
            driverInterpolatedSettingIDs = drivenSettingIDs
            return
        }
        for setting in module.settings {
            guard let source = overrides[setting.id], setting.updateMode != "structural" else { continue }
            let baseline = values[setting.id] ?? setting.default
            values[setting.id] = resolvedValue(
                source: source,
                setting: setting,
                baseline: baseline,
                key: "\(theme.id):\(module.id):\(setting.id)"
            )
            if source.type == "manual" {
                drivenSettingIDs.remove(setting.id)
            } else {
                drivenSettingIDs.insert(setting.id)
            }
        }
        resolvedModuleSettings = values
        driverInterpolatedSettingIDs = drivenSettingIDs
    }

    private func resolvedValue(
        source: PhonoscopeParameterSource,
        setting: PhonoscopeModuleSetting,
        baseline: Double,
        key: String
    ) -> Double {
        func bounded(_ value: Double) -> Double {
            max(setting.min, min(setting.max, value))
        }
        func configured(_ value: Double) -> Double {
            let bounded = bounded(value)
            guard setting.step > 0 else { return bounded }
            return max(setting.min, min(setting.max, setting.min + ((bounded - setting.min) / setting.step).rounded() * setting.step))
        }
        if source.type == "manual" { return configured(source.value ?? baseline) }
        // Steps describe editable endpoint precision, not runtime animation
        // precision. Driven outputs remain continuous between those endpoints.
        let lower = configured(source.min ?? baseline)
        let upper = max(lower, configured(source.max ?? baseline))
        let now = Date()
        var state = parameterDriverStates[key] ?? ParameterDriverState(
            current: lower,
            target: lower,
            eventKey: "",
            lastUpdated: now,
            holdUntil: now,
            wasAttacking: false
        )
        let delta = max(1.0 / 120.0, min(0.25, signal.delta))
        if source.type == "random" {
            let eventKey: String
            switch source.cadence ?? "beat" {
            case "downbeat", "bar": eventKey = "bar:\(signal.barIndex)"
            case "song": eventKey = "song:\(track?.appleMusicId ?? track?.title ?? "ambient")"
            case "interval":
                let interval = max(0.25, source.intervalSeconds ?? 4)
                eventKey = "interval:\(Int(floor(signal.time / interval)))"
            default: eventKey = "beat:\(signal.beatIndex)"
            }
            if eventKey != state.eventKey {
                state.eventKey = eventKey
                let seed = stableSeed("\(key):\(eventKey)")
                let fraction = Double(seed % 1_000_003) / 1_000_002
                state.target = lower + (upper - lower) * fraction
            }
            let duration = max(0, source.transitionSeconds ?? 0.5)
            let amount = duration == 0 ? 1 : min(1, delta / duration)
            state.current += (state.target - state.current) * amount
        } else {
            let driver: Double
            switch source.type {
            case "beat": driver = signal.beatPulse
            case "downbeat": driver = signal.downbeatPulse
            case "energy": driver = signal.energy
            case "bass": driver = Double(signal.spectrum.prefix(8).max() ?? 0)
            case "mid": driver = Double(signal.spectrum.dropFirst(8).prefix(12).max() ?? 0)
            case "treble": driver = Double(signal.spectrum.dropFirst(20).max() ?? 0)
            default: driver = 0
            }
            state.target = lower + (upper - lower) * max(0, min(1, driver))
            let signalEventKey: String
            switch source.type {
            case "downbeat": signalEventKey = "bar:\(signal.barIndex)"
            default: signalEventKey = "beat:\(signal.beatIndex)"
            }
            let newSignalEvent = signalEventKey != state.eventKey
            if newSignalEvent {
                // A fresh beat/bass observation supersedes an older envelope,
                // including a hold or release already in progress.
                state.eventKey = signalEventKey
                state.holdUntil = now
            }
            let attacking = state.target >= state.current
            if attacking {
                state.wasAttacking = true
            } else if state.wasAttacking && !newSignalEvent {
                state.holdUntil = now.addingTimeInterval(max(0, source.holdSeconds ?? 0))
                state.wasAttacking = false
            }
            let holding = !attacking && now < state.holdUntil
            let seconds = attacking
                ? max(0, source.attackSeconds ?? 0.05)
                : max(0, source.releaseSeconds ?? 0.6)
            if holding {
                // Preserve the attained level until the configured hold phase
                // ends; the release ramp begins from this exact value.
            } else if seconds == 0 {
                state.current = state.target
            } else {
                // Attack and release are full-range ramp durations, not hold or
                // exponential settling times. Partial target changes therefore
                // consume the corresponding fraction of the configured time.
                let fullRange = max(Double.ulpOfOne, upper - lower)
                let step = fullRange * delta / seconds
                if state.target >= state.current {
                    state.current = min(state.target, state.current + step)
                } else {
                    state.current = max(state.target, state.current - step)
                }
            }
        }
        state.lastUpdated = now
        parameterDriverStates[key] = state
        return bounded(state.current)
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
