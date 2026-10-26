import Foundation
import MediaPlayer
import MusicKit
import SwiftUI

/// Which player this app is, to the dashboard: the TV's presets are addressed
/// to `appletv` and the phone's to `iphone`, and the same name tags the
/// now-playing this app reports (`specs/ios-touch-app.md` §Music).
enum PlaybackDevice {
    #if os(tvOS)
    static let name = "appletv"
    #else
    static let name = "iphone"
    #endif

    /// Whether a command is this app's. A command with no target predates
    /// targets and was always the TV's, so an old server can never start the
    /// TV's preset on the phone.
    static func owns(_ target: String?) -> Bool {
        (target ?? "appletv") == name
    }
}

/// What a preset button asked a player to play — the record the dashboard
/// leaves at `GET /api/appletv/command` (`lib/appletv-command.ts`).
struct PresetPlayCommand: Decodable {
    let id: Int
    let name: String
    /// The player the press was for; absent on a server older than targets.
    let target: String?
    /// The preset's own shuffle switch: the playlist is queued either way, and
    /// this decides both that playback starts on a random entry and that the
    /// playlist carries on shuffling after it.
    let shuffle: Bool
    /// The preset's playback type, in the dashboard's own vocabulary: `off`
    /// (play once), `all` (loop) or `infinite` (endless). The television has no
    /// endless mode — see the route's `REPEAT_STATE` — so endless repeats the
    /// playlist, the same instruction the dashboard gives pyatv.
    ///
    /// `repeat` is a Swift keyword, so the property is named for what it holds
    /// and keeps the dashboard's own JSON key (`CodingKeys`). Optional because a
    /// record without the key is still a command worth playing; its absence means
    /// play once, not "this press does nothing".
    let repeatMode: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case shuffle
        case target
        case repeatMode = "repeat"
    }
}

private struct PresetPlayEnvelope: Decodable {
    let command: PresetPlayCommand?
}

/// Plays the playlist a preset names (Adeline, 2026-09-22).
///
/// The dashboard cannot start a named Apple Music playlist: Home Assistant's
/// Apple TV integration is pyatv, which drives the Music app's transport and
/// reads its metadata but has no view of the library, and the Music app answers
/// no URL scheme to deep-link into a playlist. The only place in this house with
/// a MusicKit session is this app, so a press wakes the television, brings this
/// app forward and leaves a command behind; this is what picks it up, resolves
/// the name against the Apple Music library and plays it.
///
/// **Nothing here plays "whatever was loaded."** The whole point of a preset is
/// the playlist it names, and the wrong music is worse than silence, so a name
/// that matches no library playlist plays nothing and says so.
///
/// `SystemMusicPlayer` is the Music app's own player, so playback carries on
/// after this app leaves the screen — which is what lets the phonoscope keep
/// visualising it.
@MainActor
final class PresetPlaybackStore: ObservableObject {
    /// The last thing a press did, for the log and the status overlay.
    @Published private(set) var status: String?

    private let player = SystemMusicPlayer.shared
    private let defaults = UserDefaults.standard
    private var task: Task<Void, Never>?

    /// The last command this app has acted on. The dashboard keeps a command for
    /// a couple of minutes so a television that was asleep still acts on it, and
    /// this is what stops the same press being played on every poll — including
    /// across a relaunch.
    private static let lastCommandIDKey = "nova.presetPlayback.lastCommandID"
    private static let pollInterval = Duration.seconds(2)

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    private func poll() async {
        var components = URLComponents(
            url: AppConfig.dashboardBaseURL.appendingPathComponent("api/appletv/command"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "target", value: PlaybackDevice.name)]
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let envelope = try? JSONDecoder().decode(PresetPlayEnvelope.self, from: data),
              let command = envelope.command,
              PlaybackDevice.owns(command.target)
        else { return }
        guard command.id > defaults.integer(forKey: Self.lastCommandIDKey) else { return }
        // Recorded before the attempt: a playlist this app cannot resolve must
        // not be retried every two seconds.
        defaults.set(command.id, forKey: Self.lastCommandIDKey)
        await play(command)
    }

    private func play(_ command: PresetPlayCommand) async {
        if MusicAuthorization.currentStatus != .authorized {
            let authorization = await MusicAuthorization.request()
            guard authorization == .authorized else {
                await finish(command, played: false, message: "APPLE MUSIC ACCESS NOT GRANTED")
                return
            }
        }

        let wanted = command.name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            var request = MusicLibraryRequest<Playlist>()
            request.limit = 200
            let response = try await request.response()
            guard let playlist = response.items.first(where: { isMatch($0.name, wanted) }) else {
                await finish(command, played: false, message: "NO PLAYLIST NAMED \(wanted.uppercased())")
                return
            }
            // The playlist itself, so the Music app plays *the playlist* rather
            // than a queue of loose songs. Its initializer starts at a named
            // entry, which is also what makes shuffle honest: a shuffled preset
            // starts on a random entry of the playlist instead of always on the
            // first one (Adeline, 2026-09-22). (Queuing the playlist's tracks
            // with `init(for:)` was the first version; it showed up as a queue.)
            let detailed = try await playlist.with([.entries])
            let start = (command.shuffle ? detailed.entries?.randomElement() : nil) ?? detailed.entries?.first
            guard let start else {
                await finish(command, played: false, message: "\(playlist.name.uppercased()) HAS NO ENTRIES")
                return
            }
            player.queue = .init(playlist: detailed, startingAt: start)
            // The press promises a playback type, so the modes are set here, on
            // the queue this code just assigned and before it starts: MusicKit's
            // player has no shuffle or repeat setting (only MediaPlayer's does,
            // for the same system Music app), and leaving it to the dashboard's
            // fire-and-forget pyatv calls would let a refused Home Assistant call
            // — or the queue assignment itself — play a loop preset through once,
            // or a shuffled one through in playlist order from its random entry
            // (Adeline, 2026-09-22).
            let modes = MPMusicPlayerController.systemMusicPlayer
            modes.shuffleMode = command.shuffle ? .songs : .off
            // Fail closed, exactly as the dashboard's own normalisation does: only
            // a value it actually writes loops, and anything else plays the
            // playlist once rather than looping it on a misspelling.
            let loops = command.repeatMode == "all" || command.repeatMode == "infinite"
            modes.repeatMode = loops ? .all : .none
            try await player.play()
            await finish(command, played: true, message: "PLAYING \(playlist.name.uppercased())")
        } catch {
            await finish(command, played: false, message: "COULD NOT PLAY \(wanted.uppercased())")
        }
    }

    /// A preset's name against a library playlist's, forgiving case and accents
    /// but nothing else: two playlists differing only in case are the same
    /// preset, while a different name is a different playlist.
    private func isMatch(_ candidate: String, _ wanted: String) -> Bool {
        candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private func finish(_ command: PresetPlayCommand, played: Bool, message: String) async {
        status = message
        print("[nova-preset] \(message)")
        await report(command, played: played, message: played ? nil : message)
    }

    /// Tell the dashboard what happened, so the preset editor can show it — the
    /// preset's name is the thing to fix when a playlist could not be found, and
    /// nothing else on this television can say so.
    private func report(_ command: PresetPlayCommand, played: Bool, message: String?) async {
        var request = URLRequest(url: AppConfig.dashboardBaseURL.appendingPathComponent("api/appletv/command/result"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 5
        var payload: [String: Any] = ["id": command.id, "name": command.name, "played": played]
        if let message { payload["reason"] = message }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        _ = try? await URLSession.shared.data(for: request)
    }
}
