import Foundation

/// The last few thousand remote events (touches, presses and what the band did
/// with them), kept in the app's caches so a swipe that went the wrong way can be
/// read back from the device afterwards: `Library/Caches/input-trace.txt`.
final class InputTrace {
    static let shared = InputTrace()
    private static let capacity = 3000

    private var lines: [String] = []
    private var dirty = false
    private let started = ProcessInfo.processInfo.systemUptime
    private let queue = DispatchQueue(label: "nova.input-trace", qos: .utility)
    private let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("input-trace.txt")

    func note(_ event: String) {
        lines.append(String(format: "%9.3f ", ProcessInfo.processInfo.systemUptime - started) + event)
        if lines.count > Self.capacity { lines.removeFirst(lines.count - Self.capacity) }
        dirty = true
    }

    /// Writes the trace out, off the main thread. Called at the end of each touch.
    func flush() {
        guard dirty else { return }
        dirty = false
        let text = lines.joined(separator: "\n") + "\n"
        let url = url
        queue.async { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }
}
