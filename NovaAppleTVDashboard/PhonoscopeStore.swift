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

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let player = SystemMusicPlayer.shared
    private var pollTask: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private var authorizationRequested = false
    private var lastTrackIdentity: PhonoscopeTrackIdentity?
    private var lastPollDate = Date()
    private var lastLyricIndex = -1
    private var etag: String?

    func enter() {
        guard pollTask == nil else { return }
        configurationTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshConfiguration()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.authorizeIfNeeded()
            while !Task.isCancelled {
                await self.refreshPlayback()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func leave() {
        pollTask?.cancel()
        configurationTask?.cancel()
        pollTask = nil
        configurationTask = nil
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
            let changed = configuration?.activeModuleId != envelope.config.activeModuleId
                || configuration?.activeModuleVersion != envelope.config.activeModuleVersion
            configuration = envelope.config
            etag = http.value(forHTTPHeaderField: "ETag")
            if changed || module == nil {
                await loadModule(id: envelope.config.activeModuleId, version: envelope.config.activeModuleVersion)
            }
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
        guard MusicAuthorization.currentStatus == .authorized else {
            signal = makeSignal(position: signal.time + delta, playing: false, identity: nil, analysis: nil, delta: delta)
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
                artworkUrl: song.artwork?.url(width: 1024, height: 1024)?.absoluteString
            )
        }

        if let nextIdentity, nextIdentity.duration > 0, nextIdentity != lastTrackIdentity {
            lastTrackIdentity = nextIdentity
            track = nextIdentity
            analysis = nil
            lastLyricIndex = -1
            status = "RESOLVING \(nextIdentity.title.uppercased())"
            Task { [weak self] in await self?.resolveTrack(nextIdentity) }
        } else if nextIdentity == nil {
            lastTrackIdentity = nil
            track = nil
            analysis = nil
        }

        let playing = player.state.playbackStatus == .playing
        let position = player.playbackTime.isFinite ? player.playbackTime : signal.time + (playing ? delta : 0)
        signal = makeSignal(position: position, playing: playing, identity: track, analysis: analysis, delta: delta)
        if let track {
            status = playing ? "\(track.artist.uppercased()) — \(track.title.uppercased())" : "PAUSED — \(track.title.uppercased())"
        } else if configuration?.idleBehavior == "black" {
            status = ""
        } else {
            status = "AMBIENT — START APPLE MUSIC"
        }
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
        let adjusted = max(0, position - (analysis?.beatOffset ?? 0))
        let beatValue = adjusted / beatLength
        let beatIndex = Int(floor(beatValue))
        let beatPhase = beatValue - floor(beatValue)
        let beatPulse = pow(max(0, 1 - beatPhase), 5)
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
