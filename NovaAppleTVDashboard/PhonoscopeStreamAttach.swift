import Foundation

/// Decides whether an SRT connection that is alive but not producing a picture
/// has stalled, so the client can drop it and reconnect.
///
/// Without this the failure is permanent and silent: the socket is healthy and
/// the renderer keeps sending, so no error ever arrives, `hasPresentedFrame`
/// stays false, and the local Metal engine stays on screen for good.
/// Specified in `specs/streamed-visualiser-attach.md`.
struct PhonoscopeAttachWatchdog {
    /// Time allowed from connecting to the first enqueued sample. Generous
    /// because the renderer releases its GPU when nobody watches, and waking it
    /// (EGL, CUDA, NVENC, fonts) happens after the connection is accepted.
    static let attachSeconds = 8.0
    /// Silence tolerated once frames have been flowing. The idle encode cadence
    /// is 15 fps, so a healthy stream is never quiet for anything like this.
    static let streamSeconds = 3.0

    let connectedAt: Double
    private var lastSampleAt: Double?
    private var sawHeaderUnit = false

    init(connectedAt: Double) {
        self.connectedAt = connectedAt
    }

    mutating func sawHeader() {
        sawHeaderUnit = true
    }

    mutating func sawSample(now: Double) {
        lastSampleAt = now
    }

    /// The reason to disconnect, or nil while the connection is healthy.
    func stallReason(now: Double) -> String? {
        if let lastSampleAt {
            return now - lastSampleAt > Self.streamSeconds ? "stalled: no frames" : nil
        }
        guard now - connectedAt > Self.attachSeconds else { return nil }
        return sawHeaderUnit ? "stalled: no decodable frame" : "stalled: no header"
    }
}
