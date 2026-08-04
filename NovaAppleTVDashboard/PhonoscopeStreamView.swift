import AVFoundation
import SwiftUI

/// Hosts the stream client's `AVSampleBufferDisplayLayer`.
///
/// Deliberately thin: everything above this is the same visualiser UX the local
/// Metal engine sits behind, so switching between the two changes only what
/// fills the surface.
struct PhonoscopeStreamView: UIViewRepresentable {
    let client: PhonoscopeStreamClient

    func makeUIView(context: Context) -> UIView {
        let view = StreamHostView()
        view.backgroundColor = .black
        view.attach(layer: client.displayLayer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? StreamHostView)?.attach(layer: client.displayLayer)
    }
}

private final class StreamHostView: UIView {
    private weak var attached: AVSampleBufferDisplayLayer?

    func attach(layer: AVSampleBufferDisplayLayer) {
        guard attached !== layer else { return }
        attached?.removeFromSuperlayer()
        layer.frame = bounds
        self.layer.addSublayer(layer)
        attached = layer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The layer is not auto-resized because it is owned by the client, not
        // by this view; it outlives any particular host.
        attached?.frame = bounds
    }
}

/// Reports Apple Music playback up to Nova.
///
/// This is the one signal that must still originate on the Apple TV: MusicKit's
/// `SystemMusicPlayer` is only observable on the device the music is playing on.
/// Everything downstream — beat timeline, theme rotation, house-party lighting,
/// the render itself — is derived server-side from what this posts.
@MainActor
final class PhonoscopeNowPlayingReporter {
    private var task: Task<Void, Never>?
    private var signalTask: Task<Void, Never>?
    private let session = URLSession(configuration: .ephemeral)

    func start(baseURL: URL, snapshot: @escaping @MainActor () -> PhonoscopeNowPlayingSnapshot) {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.post(baseURL: baseURL, snapshot: snapshot())
                // 4 Hz. The server extrapolates position between samples, so
                // this only has to be often enough to correct drift and catch
                // transport changes promptly.
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        signalTask?.cancel()
        task = nil
        signalTask = nil
    }

    func startSignal(
        url: URL,
        snapshot: @escaping @MainActor () -> PhonoscopeResolvedSignalSnapshot
    ) {
        signalTask?.cancel()
        signalTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.postSignal(url: url, snapshot: snapshot())
                // Band/envelope drivers are visibly quantized at the 4 Hz
                // transport cadence. Thirty small LAN posts per second keeps
                // the streamed renderer on the original engine's signal frame.
                try? await Task.sleep(nanoseconds: 33_333_333)
            }
        }
    }

    private func post(baseURL: URL, snapshot: PhonoscopeNowPlayingSnapshot) async {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/phonoscope/now-playing"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 4
        guard let body = try? JSONSerialization.data(withJSONObject: snapshot.payload) else { return }
        request.httpBody = body
        _ = try? await session.data(for: request)
    }

    private func postSignal(url: URL, snapshot: PhonoscopeResolvedSignalSnapshot) async {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 1
        guard let body = try? JSONSerialization.data(withJSONObject: snapshot.payload) else { return }
        request.httpBody = body
        _ = try? await session.data(for: request)
    }
}

struct PhonoscopeResolvedSignalSnapshot {
    let signal: PhonoscopeSignalFrame
    let timeSignature: Int

    var payload: [String: Any] {
        [
            "time": signal.time,
            "delta": signal.delta,
            "duration": signal.duration,
            "progress": signal.progress,
            "playing": signal.playing,
            "bpm": signal.bpm,
            "beatPhase": signal.beatPhase,
            "beatPulse": signal.beatPulse,
            "beatIndex": signal.beatIndex,
            "barPhase": signal.barPhase,
            "barIndex": signal.barIndex,
            "timeSignature": max(1, timeSignature),
            "downbeatPulse": signal.downbeatPulse,
            "energy": signal.energy,
            "valence": signal.valence,
            "lyricProgress": signal.lyricProgress,
            "lyricPulse": signal.lyricPulse,
            "lyricIndex": signal.lyricIndex,
            "lyricCurrent": signal.lyricCurrent,
            "lyricNext": signal.lyricNext,
            "spectrum": signal.spectrum,
            "quality": signal.quality.rawValue,
            // JSON numbers cannot represent all UInt64 seeds losslessly.
            "trackSeed": String(signal.trackSeed),
        ]
    }
}

struct PhonoscopeNowPlayingSnapshot {
    var appleMusicId: String?
    var isrc: String?
    var title: String
    var artist: String
    var album: String?
    var duration: Double
    var artworkUrl: String?
    var genreNames: [String]
    var position: Double
    var playing: Bool
    var hasTrack: Bool
    var barIndex: Int

    var payload: [String: Any] {
        var body: [String: Any] = [
            "position": position,
            "duration": duration,
            "playing": playing,
            "sampledAtMs": Date().timeIntervalSince1970 * 1_000,
            "source": "appletv",
            "barIndex": barIndex,
        ]
        guard hasTrack else { return body }
        var track: [String: Any] = [
            "title": title,
            "artist": artist,
            "duration": duration,
        ]
        if let appleMusicId { track["appleMusicId"] = appleMusicId }
        if let isrc { track["isrc"] = isrc }
        if let album { track["album"] = album }
        if let artworkUrl { track["artworkUrl"] = artworkUrl }
        if !genreNames.isEmpty { track["genreNames"] = genreNames }
        body["track"] = track
        return body
    }
}

/// Where the renderer lives, as reported by Nova. Keeping this server-side means
/// the stream endpoint is not baked into the tvOS build.
struct PhonoscopeRendererEndpoint: Decodable, Equatable {
    let available: Bool
    let streamHost: String
    let streamPort: Int
    let srtPort: Int?
    let srtLatencyMs: Int?
    let signalUrl: URL?
    let status: PhonoscopeRendererStatus?

    var preferredSRTPort: Int? {
        srtPort ?? (status?.srtAvailable == true ? status?.srtPort : nil)
    }

    var preferredSRTLatencyMs: Int { srtLatencyMs ?? status?.srtLatencyMs ?? 60 }
}

struct PhonoscopeRendererStatus: Decodable, Equatable {
    let srtAvailable: Bool?
    let srtPort: Int?
    let srtLatencyMs: Int?
}
