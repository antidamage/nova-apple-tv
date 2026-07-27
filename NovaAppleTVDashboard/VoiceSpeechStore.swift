import Foundation
import QuartzCore
import SwiftUI

enum VoiceSpeechPhase: String, Equatable {
    case idle
    case speaking
    case ending
}

struct VoiceSpeechSnapshot: Equatable {
    var turnID: String
    var startedAt: TimeInterval
    var audibleAt: TimeInterval
    var timings: [Double]?
    var estimatedDuration: TimeInterval
    var fadeOutAt: TimeInterval?
    var safetyDeadline: TimeInterval

    func envelope(at now: TimeInterval, alertPulsePeriod: TimeInterval) -> Double {
        let fadeIn = clamped((now - startedAt) / VoiceSpeechStore.fadeInSeconds)
        let fadeOut: Double
        if let fadeOutAt, now >= fadeOutAt {
            fadeOut = clamped(1 - (now - fadeOutAt) / VoiceSpeechStore.fadeOutSeconds)
        } else {
            fadeOut = 1
        }
        let gate = fadeIn * fadeOut
        guard gate > 0 else { return 0 }

        guard let timings, !timings.isEmpty else {
            let period = max(0.05, alertPulsePeriod)
            return gate * (1 - cos((now / period) * .pi * 2)) / 2
        }

        let speechMilliseconds = (now - audibleAt) * 1_000
        let kernelWindow = VoiceSpeechStore.pulseAttackMilliseconds +
            VoiceSpeechStore.pulseDecayMilliseconds * 5
        var pulse = 0.0
        for onset in timings {
            let delta = speechMilliseconds - onset
            if delta < 0 { break }
            if delta > kernelWindow { continue }
            if delta <= VoiceSpeechStore.pulseAttackMilliseconds {
                pulse += delta / VoiceSpeechStore.pulseAttackMilliseconds
            } else {
                pulse += exp(
                    -(delta - VoiceSpeechStore.pulseAttackMilliseconds) /
                        VoiceSpeechStore.pulseDecayMilliseconds
                )
            }
        }
        pulse = min(1, pulse)
        return gate * (VoiceSpeechStore.pulseFloor + (1 - VoiceSpeechStore.pulseFloor) * pulse)
    }
}

private struct VoiceSpeakingEvent: Decodable {
    var phase: String?
    var turnId: String?
    var timingsMs: [Double]?
    var estimatedDurationMs: Double?
    var audibleOffsetMs: Double?
    var playedDurationMs: Double?
    var elapsedMs: Double?
}

/// Native subscriber for the dashboard's shared SSE stream. It mirrors the
/// browser voiceSpeech model so tvOS receives the same speech start/replay/end
/// events and samples the same consonant envelope.
@MainActor
final class VoiceSpeechStore: ObservableObject {
    static let fadeInSeconds = 0.140
    static let fadeOutSeconds = 0.420
    static let returnSeconds = 0.450
    static let pulseAttackMilliseconds = 45.0
    static let pulseDecayMilliseconds = 110.0
    static let pulseFloor = 0.22
    private static let safetySlackSeconds = 8.0

    @Published private(set) var phase: VoiceSpeechPhase = .idle
    @Published private(set) var snapshot: VoiceSpeechSnapshot?

    private var streamSession: URLSession?
    private var streamDelegate: VoiceSpeechStreamDelegate?
    private var reconnectTask: Task<Void, Never>?
    private var phaseTask: Task<Void, Never>?
    private var safetyTask: Task<Void, Never>?
    private let decoder = JSONDecoder()
    private var isRunning = false
    private var reconnectDelay = 2.0

    func start() {
        guard !isRunning else { return }
        isRunning = true
        connect(candidateIndex: 0)
    }

    func stop() {
        isRunning = false
        reconnectTask?.cancel()
        reconnectTask = nil
        streamSession?.invalidateAndCancel()
        streamSession = nil
        streamDelegate = nil
        phaseTask?.cancel()
        safetyTask?.cancel()
        phaseTask = nil
        safetyTask = nil
        snapshot = nil
        phase = .idle
    }

    private func connect(candidateIndex: Int) {
        guard isRunning, streamSession == nil else { return }
        let urls = AppConfig.urls(path: "api/events")
        guard !urls.isEmpty else { return }
        let index = candidateIndex % urls.count
        var request = URLRequest(url: urls[index])
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let delegate = VoiceSpeechStreamDelegate(
            onOpen: { [weak self] in
                Task { @MainActor in
                    self?.reconnectDelay = 2
                }
            },
            onEvent: { [weak self] name, data in
                Task { @MainActor in
                    self?.dispatchEvent(name: name, data: data)
                }
            },
            onComplete: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.streamSession = nil
                    self.streamDelegate = nil
                    guard self.isRunning else { return }
                    self.scheduleReconnect(candidateIndex: index + 1)
                }
            }
        )
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        streamDelegate = delegate
        streamSession = session
        session.dataTask(with: request).resume()
    }

    private func scheduleReconnect(candidateIndex: Int) {
        reconnectTask?.cancel()
        let delay = reconnectDelay
        reconnectDelay = min(30, reconnectDelay * 2)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.reconnectTask = nil
            self?.connect(candidateIndex: candidateIndex)
        }
    }

    private func dispatchEvent(name: String, data: String) {
        guard name == "voice-speaking", let payload = data.data(using: .utf8),
              let event = try? decoder.decode(VoiceSpeakingEvent.self, from: payload)
        else {
            return
        }
        if event.phase == "start" {
            handleStart(event)
        } else if event.phase == "end" {
            handleEnd(event)
        }
    }

    private func handleStart(_ event: VoiceSpeakingEvent) {
        guard let turnID = event.turnId, !turnID.isEmpty else { return }
        phaseTask?.cancel()
        safetyTask?.cancel()

        let now = CACurrentMediaTime()
        let elapsed = max(0, event.elapsedMs ?? 0) / 1_000
        let audibleOffset = max(0, event.audibleOffsetMs ?? 0) / 1_000
        let estimated = max(0.3, (event.estimatedDurationMs ?? 0) / 1_000)
        let timings = event.timingsMs?
            .filter(\.isFinite)
            .map { max(0, $0) }
            .sorted()
        let startedAt = now - elapsed
        let audibleAt = startedAt + audibleOffset
        let safetyDeadline = audibleAt + max(
            estimated * 1.5,
            estimated + Self.safetySlackSeconds
        )

        snapshot = VoiceSpeechSnapshot(
            turnID: turnID,
            startedAt: startedAt,
            audibleAt: audibleAt,
            timings: timings?.isEmpty == false ? timings : nil,
            estimatedDuration: estimated,
            fadeOutAt: nil,
            safetyDeadline: safetyDeadline
        )
        phase = .speaking

        safetyTask = Task { [weak self] in
            let delay = max(0, safetyDeadline - CACurrentMediaTime())
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.beginEnding(at: CACurrentMediaTime())
        }
    }

    private func handleEnd(_ event: VoiceSpeakingEvent) {
        guard let active = snapshot,
              event.turnId == nil || event.turnId == active.turnID,
              active.fadeOutAt == nil
        else {
            return
        }
        let now = CACurrentMediaTime()
        let played = max(0, event.playedDurationMs ?? 0) / 1_000
        beginEnding(at: max(now, min(active.audibleAt + played, active.safetyDeadline)))
    }

    private func beginEnding(at fadeOutAt: TimeInterval) {
        guard var active = snapshot, active.fadeOutAt == nil else { return }
        active.fadeOutAt = fadeOutAt
        snapshot = active
        safetyTask?.cancel()
        phaseTask?.cancel()
        phaseTask = Task { [weak self] in
            let untilFade = max(0, fadeOutAt - CACurrentMediaTime())
            try? await Task.sleep(nanoseconds: UInt64(untilFade * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.phase = .ending
            try? await Task.sleep(
                nanoseconds: UInt64((Self.fadeOutSeconds + Self.returnSeconds) * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self?.snapshot = nil
            self?.phase = .idle
        }
    }
}

/// Incremental SSE parser. The dashboard sends a large state snapshot before
/// speech events; consuming data chunks directly keeps that unrelated payload
/// out of the voice store while preserving standard event/data line framing.
private final class VoiceSpeechStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let onOpen: () -> Void
    private let onEvent: (String, String) -> Void
    private let onComplete: () -> Void
    private var eventName = "message"
    private var dataLines: [String] = []
    private var lineBuffer = ""
    private var acceptedResponse = false

    init(
        onOpen: @escaping () -> Void,
        onEvent: @escaping (String, String) -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.onOpen = onOpen
        self.onEvent = onEvent
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        acceptedResponse = (response as? HTTPURLResponse)
            .map { 200..<300 ~= $0.statusCode } ?? false
        completionHandler(acceptedResponse ? .allow : .cancel)
        if acceptedResponse {
            onOpen()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard acceptedResponse else { return }
        lineBuffer.append(String(decoding: data, as: UTF8.self))
        while let newline = lineBuffer.firstIndex(of: "\n") {
            var line = String(lineBuffer[..<newline])
            lineBuffer.removeSubrange(...newline)
            if line.last == "\r" {
                line.removeLast()
            }
            consume(line: line)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        onComplete()
    }

    private func consume(line: String) {
        if line.isEmpty {
            if !dataLines.isEmpty {
                onEvent(eventName, dataLines.joined(separator: "\n"))
            }
            eventName = "message"
            dataLines.removeAll(keepingCapacity: true)
        } else if line.hasPrefix("event:") {
            eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
    }
}
