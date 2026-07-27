import AVKit
import SwiftUI

// Live HLS playback plumbing for the Nova camera feeds (the Outside S-Video
// capture). The dashboard host serves a rolling-window HLS playlist at
// `/api/camera/<id>/index.m3u8`; tvOS plays it natively through AVPlayer.
//
// Deliberately a bare AVPlayerLayer host rather than AVKit's `VideoPlayer`:
// `VideoPlayer` installs focusable transport controls that would fight the
// dashboard's custom remote-driven focus model. This view is non-interactive
// and non-focusable — it just renders the feed, muted (the capture is
// video-only), and self-heals on stalls/failures so a dropped segment or a
// briefly-unavailable recorder recovers without any user action.

/// Decoded subset of `GET /api/camera/<id>/status` used to drive the feed's
/// "live / offline" chrome. Mirrors the web `CameraStatus` shape.
struct CameraFeedStatus: Decodable {
    let source: String?
    let recording: Bool?
    let deviceConnected: Bool?
}

/// Full-screen native player for a camera feed. Presented when the inline tile
/// is selected: `AVPlayerViewController` is the canonical tvOS video surface,
/// so the user gets the platform's own transport — play/pause on Select,
/// swipe-to-scrub across the rolling DVR window, skip, and a LIVE indicator —
/// driven by the Siri remote exactly as it works everywhere else on tvOS.
/// Menu/Back dismisses the player (and the presenting cover).
struct CameraFullScreenPlayer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let player = AVPlayer(url: url)
        player.isMuted = true
        controller.player = player
        // Show the native transport bar; live HLS gets the system LIVE badge
        // and DVR scrubbing for free.
        controller.showsPlaybackControls = true
        player.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
        controller.player = nil
    }
}

/// SwiftUI host for a live camera feed. `failed` reports up whenever the
/// player cannot start or keep a stream alive, so the surrounding panel can
/// show an offline overlay.
struct CameraPlayerView: UIViewRepresentable {
    let url: URL
    @Binding var failed: Bool

    func makeUIView(context: Context) -> CameraPlayerUIView {
        let view = CameraPlayerUIView()
        view.onFailedChange = { value in
            // Hop to the main actor; KVO/notification callbacks can arrive off it.
            DispatchQueue.main.async {
                if failed != value { failed = value }
            }
        }
        view.configure(url: url)
        return view
    }

    func updateUIView(_ uiView: CameraPlayerUIView, context: Context) {
        // Rebuilds only when the resolved stream URL actually changes (e.g. the
        // store settles on a different reachable host); a no-op otherwise.
        uiView.configure(url: url)
    }

    static func dismantleUIView(_ uiView: CameraPlayerUIView, coordinator: ()) {
        uiView.teardown()
    }
}

/// UIView whose backing layer is an AVPlayerLayer. Owns the AVPlayer lifecycle,
/// watches the item for readiness/failure, and rebuilds on any terminal state
/// (a live playlist should never legitimately "end"), with a short backoff.
final class CameraPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var currentURL: URL?
    private var retryWorkItem: DispatchWorkItem?

    var onFailedChange: ((Bool) -> Void)?

    // The dashboard drives focus itself; the feed must never absorb it.
    override var canBecomeFocused: Bool { false }

    func configure(url: URL) {
        guard url != currentURL else { return }
        currentURL = url
        start(url: url)
    }

    private func start(url: URL) {
        teardownPlayback()

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard let self else { return }
            switch observed.status {
            case .readyToPlay:
                self.onFailedChange?(false)
                self.player?.play()
            case .failed:
                self.onFailedChange?(true)
                self.scheduleRetry()
            default:
                break
            }
        }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleStall), name: .AVPlayerItemPlaybackStalled, object: item)
        center.addObserver(self, selector: #selector(handleEnded), name: .AVPlayerItemDidPlayToEndTime, object: item)
        center.addObserver(self, selector: #selector(handleFailedToEnd), name: .AVPlayerItemFailedToPlayToEndTime, object: item)

        player.play()
    }

    @objc private func handleStall() {
        // Nudge playback; AVFoundation will refill from the live playlist.
        player?.play()
    }

    @objc private func handleEnded() {
        // A live stream ending means the playlist went away — rebuild.
        scheduleRetry()
    }

    @objc private func handleFailedToEnd() {
        onFailedChange?(true)
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let url = self.currentURL else { return }
            self.start(url: url)
        }
        retryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func teardownPlayback() {
        statusObservation?.invalidate()
        statusObservation = nil
        NotificationCenter.default.removeObserver(self)
        player?.pause()
    }

    func teardown() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        teardownPlayback()
        playerLayer.player = nil
        player = nil
        currentURL = nil
    }
}
