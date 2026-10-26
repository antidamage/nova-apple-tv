import Foundation

struct HeaterEncoderPreferences: Decodable {
    var mode: String?
    var temperature: Double?
    var offTimerEndsAt: String?
}

struct TimerEncoderIcon: Decodable, Identifiable {
    struct Glyph: Decodable { var kind: String; var id: String?; var value: String? }
    var id: String
    var label: String
    var glyph: Glyph
    var code: String { glyph.kind == "text" ? "text:" + (glyph.value ?? "") : glyph.id ?? "timer" }
    static let fallback = TimerEncoderIcon(id: "timer", label: "Countdown", glyph: Glyph(kind: "phosphor", id: "timer"))
}

extension DashboardStore {
    /// Uses the same server command boundary as web controls. Errors stay visible,
    /// and the face returns to server truth after the preview ends.
    func sendEncoderCommand(path: String, body: [String: Any]) async {
        isSending = true
        defer { isSending = false }
        do {
            let (data, response) = try await post(path: path, body: body)
            try validate(response: response, data: data)
            await refresh()
            await refreshOrbEvents()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum TimerEncoderScale {
    static let minutes: [Double] = {
        var seconds = [0]
        seconds += Array(stride(from: 5, to: 60, by: 5))
        seconds += Array(stride(from: 60, to: 300, by: 10))
        seconds += Array(stride(from: 300, to: 600, by: 30))
        seconds += Array(stride(from: 600, to: 1800, by: 60))
        seconds += Array(stride(from: 1800, to: 3600, by: 300))
        seconds += Array(stride(from: 3600, through: 28800, by: 600))
        return seconds.map { Double($0) / 60 }
    }()
    static func fraction(_ minutes: Double) -> Double {
        minutes < 1 / 12 ? 0 : max(0, (log(min(480, minutes)) + 1) / (log(480) + 1))
    }
    static func nearestIndex(_ value: Double) -> Int {
        minutes.indices.min { abs(minutes[$0] - value) < abs(minutes[$1] - value) } ?? 0
    }
    static func text(_ minutes: Double) -> String {
        let seconds = Int((minutes * 60).rounded())
        if seconds == 0 { return "OFF" }
        if seconds < 3600 { return String(format: "%d:%02d", seconds / 60, seconds % 60) }
        return String(format: "%dH %02dM", seconds / 3600, seconds / 60 % 60)
    }
    static func remainingMinutes(_ end: String?) -> Double {
        guard let end else { return 0 }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: end) ?? ISO8601DateFormatter().date(from: end) else { return 0 }
        return max(0, ceil(date.timeIntervalSinceNow / 60))
    }
    static func deadline(_ minutes: Double) -> Any {
        minutes <= 0 ? NSNull() : ISO8601DateFormatter().string(from: Date().addingTimeInterval(minutes * 60)) as Any
    }
}
