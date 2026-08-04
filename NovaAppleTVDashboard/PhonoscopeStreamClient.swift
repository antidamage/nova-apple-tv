import AVFoundation
import Foundation
import Network
import NovaSRT
import VideoToolbox

/// Receives the GPU-rendered visualiser from the `nova-visualiser` service on
/// iridium and feeds it straight into an `AVSampleBufferDisplayLayer`.
///
/// Why not HLS: even low-latency HLS adds segmenting, playlist round trips and
/// AVPlayer's own buffering — seconds of latency for a visualiser that has to
/// look like it is reacting to the music playing in this room. Handing access
/// units to `AVSampleBufferDisplayLayer` is hardware decode with roughly one
/// frame of pipeline and no player in the way.
///
/// Wire format is documented in `nova-visualiser/src/net/stream_server.h`.
/// Big-endian throughout:
///
///     "NOVAVIS1" + uint32 headerLength + JSON header
///     then repeating:
///     uint8 type, uint8 flags, uint16 reserved, uint32 length,
///     uint64 ptsMicroseconds, uint64 sentAtMicroseconds, payload
@MainActor
final class PhonoscopeStreamClient: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case streaming
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var measuredFramesPerSecond = 0.0

    /// Set once the first frame has actually been decoded and enqueued. The view
    /// only hides the local Metal engine when this is true, so a renderer that
    /// accepts a connection but never produces video cannot black the screen.
    @Published private(set) var hasPresentedFrame = false

    let displayLayer = AVSampleBufferDisplayLayer()
    private var presentationTimebase: CMTimebase?
    private var timebasePrimed = false

    private var connection: NWConnection?
    private var srtConnection: OpaquePointer?
    private let srtQueue = DispatchQueue(label: "nz.co.skull.nova.phonoscope.srt", qos: .userInteractive)
    private var transportGeneration = 0
    private var activeHost = ""
    private var activeSRTPort: UInt16?
    private var activeTCPPort: UInt16 = 8_770
    private var activeSRTLatencyMs = 60
    private var rendererControlURL: URL?
    private var buffer = Data()
    private var handshakeComplete = false
    private var formatDescription: CMFormatDescription?
    /// The VPS/SPS/PPS bytes the current `formatDescription` was built from.
    ///
    /// Every IDR repeats the parameter sets in-band, and this used to rebuild
    /// the format description on each one — several times a minute, for bytes
    /// that had not changed. Rebuilding hands the renderer a different
    /// `CMFormatDescription` object and disturbs its state for no reason.
    /// Compare first and rebuild only on a genuine change.
    private var parameterSetsFingerprint: Data?
    private var decodedFrames: Int64 = 0
    private var droppedFrames: Int64 = 0
    private var fpsWindowStart = CACurrentMediaTime()
    private var fpsFrames = 0
    private var lastReportAt = CACurrentMediaTime()
    private var pipelineDelaySeconds = 0.0
    private var reconnectAttempt = 0
    private var totalReconnectCount = 0
    private var stopped = true

    nonisolated private static let magic = Array("NOVAVIS1".utf8)
    nonisolated private static let frameHeaderBytes = 24

    init() {
        displayLayer.videoGravity = .resizeAspect
        // SRT's TSBPD queue removes network jitter. Keep one additional frame
        // decoded on the Apple TV and let the display layer pace by PTS; the
        // server includes this exact interval in its render-ahead calculation.
        var timebase: CMTimebase?
        if CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        ) == noErr {
            presentationTimebase = timebase
            displayLayer.controlTimebase = timebase
        }
    }

    func start(
        host: String,
        srtPort: UInt16?,
        tcpPort: UInt16,
        srtLatencyMs: Int,
        rendererControlURL: URL
    ) {
        stop()
        stopped = false
        transportGeneration += 1
        reconnectAttempt = 0
        totalReconnectCount = 0
        activeHost = host
        activeSRTPort = srtPort
        activeTCPPort = tcpPort
        activeSRTLatencyMs = srtLatencyMs
        self.rendererControlURL = rendererControlURL
        if let srtPort {
            connectSRT(host: host, port: srtPort, latencyMs: srtLatencyMs, generation: transportGeneration)
        } else {
            connectTCP(host: host, port: tcpPort)
        }
    }

    func stop() {
        stopped = true
        transportGeneration += 1
        if let srtConnection {
            self.srtConnection = nil
            NovaSRTDisconnect(srtConnection)
            NovaSRTRelease(srtConnection)
        }
        connection?.cancel()
        connection = nil
        buffer.removeAll(keepingCapacity: false)
        handshakeComplete = false
        formatDescription = nil
        timebasePrimed = false
        if let presentationTimebase { CMTimebaseSetRate(presentationTimebase, rate: 0) }
        hasPresentedFrame = false
        state = .idle
        displayLayer.flushAndRemoveImage()
    }

    // MARK: - Connection

    private func connectTCP(host: String, port: UInt16) {
        guard !stopped else { return }
        connection?.cancel()
        state = .connecting
        handshakeComplete = false
        formatDescription = nil
        timebasePrimed = false
        buffer.removeAll(keepingCapacity: true)

        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            // A Nagle delay of 40 ms is over two frames at 60 fps.
            tcp.noDelay = true
            tcp.connectionTimeout = 5
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 8_770
        )
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.reconnectAttempt = 0
                    self.receive()
                case .failed(let error):
                    self.handleDisconnect(host: host, port: port, reason: error.localizedDescription)
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    private func handleDisconnect(host: String, port: UInt16, reason: String) {
        guard !stopped else { return }
        hasPresentedFrame = false
        state = .failed(reason)
        // Back off, but stay eager: the renderer releases its GPU resources when
        // nothing is watching, so a reconnect is the normal way it wakes up.
        reconnectAttempt = min(reconnectAttempt + 1, 5)
        totalReconnectCount += 1
        let delay = Double(reconnectAttempt)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor in self?.connectTCP(host: host, port: port) }
        }
    }

    private func connectSRT(host: String, port: UInt16, latencyMs: Int, generation: Int) {
        guard !stopped, generation == transportGeneration else { return }
        state = .connecting
        handshakeComplete = false
        formatDescription = nil
        buffer.removeAll(keepingCapacity: true)
        reportTransportState("connecting")
        let layer = displayLayer
        let timebase = presentationTimebase

        srtQueue.async { [weak self] in
            var error = [CChar](repeating: 0, count: 512)
            let connection = host.withCString { hostBytes in
                NovaSRTConnect(hostBytes, port, Int32(latencyMs), &error, Int32(error.count))
            }
            guard let connection else {
                let message = String(cString: error)
                Task { @MainActor in
                    self?.handleSRTDisconnect(reason: message, generation: generation)
                }
                return
            }

            // The receive queue owns the connection returned by Connect. Give
            // the MainActor its own reference before publishing the pointer so
            // stop/reconnect and the receive failure callback cannot free it
            // out from under one another.
            NovaSRTRetain(connection)
            let publication = DispatchSemaphore(value: 0)
            Task { @MainActor in
                defer { publication.signal() }
                guard let self, !self.stopped, self.transportGeneration == generation else {
                    NovaSRTRelease(connection)
                    return
                }
                self.srtConnection = connection
                self.reconnectAttempt = 0
            }
            // Establish (or reject) MainActor ownership before receive can
            // fail, so a very fast disconnect cannot overtake publication and
            // leave a stale pointer behind.
            publication.wait()

            // Native SRT reassembles the renderer's packet fragments. Two MiB
            // comfortably covers the observed 4K IDR maximum (~100 KiB) while
            // keeping one stable allocation for the whole connection.
            var unit = [UInt8](repeating: 0, count: 2 * 1_024 * 1_024)
            var receivedHandshake = false
            var srtFormatDescription: CMFormatDescription?
            var srtFormatFingerprint: Data?
            var localDecoded: Int64 = 0
            var localDropped: Int64 = 0
            var localFPSFrames = 0
            var localFPSStarted = CACurrentMediaTime()
            var localTimebasePrimed = false
            while true {
                let received = NovaSRTReceiveUnit(
                    connection, &unit, Int32(unit.count), &error, Int32(error.count)
                )
                if received == -2 { continue }
                if received <= 0 {
                    let message = received == 0 ? "SRT disconnected" : String(cString: error)
                    // One callback reference survives until MainActor has
                    // cleared (and released) its published reference.
                    NovaSRTRetain(connection)
                    NovaSRTDisconnect(connection)
                    NovaSRTRelease(connection)
                    Task { @MainActor in
                        self?.handleSRTDisconnect(
                            reason: message, generation: generation, connection: connection
                        )
                        NovaSRTRelease(connection)
                    }
                    return
                }

                let logicalUnit = Data(unit.prefix(Int(received)))

                    if !receivedHandshake {
                        guard logicalUnit.count >= 12,
                              Array(logicalUnit.prefix(8)) == Self.magic
                        else { continue }
                        let headerLength = Int(Self.readUInt32(in: logicalUnit, at: 8))
                        guard logicalUnit.count >= 12 + headerLength,
                              let object = try? JSONSerialization.jsonObject(
                                  with: logicalUnit.subdata(in: 12 ..< (12 + headerLength))
                              ) as? [String: Any]
                        else { continue }
                        if let encoded = object["parameterSets"] as? String,
                           let parameterSets = Data(base64Encoded: encoded) {
                            srtFormatDescription = Self.makeFormatDescription(fromAnnexB: parameterSets)
                            srtFormatFingerprint = Data(Self.nalUnitsStatic(in: parameterSets).joined())
                        }
                        receivedHandshake = true
                        continue
                    }

                    guard logicalUnit.count >= Self.frameHeaderBytes else { continue }
                    let payloadLength = Int(Self.readUInt32(in: logicalUnit, at: 4))
                    guard payloadLength > 0,
                          logicalUnit.count >= Self.frameHeaderBytes + payloadLength
                    else { continue }
                    let keyframe = (logicalUnit[logicalUnit.startIndex + 1] & 1) != 0
                    let pts = Self.readUInt64(in: logicalUnit, at: 8)
                    let annexB = logicalUnit.subdata(
                        in: Self.frameHeaderBytes ..< (Self.frameHeaderBytes + payloadLength)
                    )
                    if keyframe || srtFormatDescription == nil {
                        let units = Self.nalUnitsStatic(in: annexB)
                        let parameterSets = units.filter {
                            guard let first = $0.first else { return false }
                            let type = (first >> 1) & 0x3F
                            return type == 32 || type == 33 || type == 34
                        }
                        let fingerprint = Data(parameterSets.joined())
                        if !parameterSets.isEmpty, fingerprint != srtFormatFingerprint {
                            srtFormatDescription = Self.makeFormatDescription(fromAnnexB: annexB)
                            srtFormatFingerprint = fingerprint
                        }
                    }
                    guard let format = srtFormatDescription,
                          let sample = Self.makeSampleBuffer(
                              annexB: annexB, ptsMicroseconds: pts, formatDescription: format
                          )
                    else { continue }

                    if layer.status == .failed {
                        layer.flush()
                        localDropped += 1
                        localTimebasePrimed = false
                        Task { @MainActor in self?.requestKeyframe() }
                    }
                    if !localTimebasePrimed {
                        Self.primePresentationTimebase(timebase, ptsMicroseconds: pts)
                        localTimebasePrimed = true
                    }
                    layer.enqueue(sample)
                    localDecoded += 1
                    localFPSFrames += 1
                    if localDecoded == 1 {
                        Task { @MainActor in
                            self?.markSRTStreaming(generation: generation)
                        }
                    }
                    let now = CACurrentMediaTime()
                    if now - localFPSStarted >= 1 {
                        let fps = Double(localFPSFrames) / (now - localFPSStarted)
                        Task { @MainActor in
                            self?.reportSRTProgress(
                                fps: fps,
                                decoded: localDecoded,
                                dropped: localDropped,
                                generation: generation
                            )
                        }
                        localFPSFrames = 0
                        localFPSStarted = now
                    }
            }
        }
    }

    private func markSRTStreaming(generation: Int) {
        guard !stopped, generation == transportGeneration else { return }
        hasPresentedFrame = true
        state = .streaming
        reportTransportState("streaming")
    }

    private func reportSRTProgress(fps: Double, decoded: Int64, dropped: Int64, generation: Int) {
        guard !stopped, generation == transportGeneration else { return }
        measuredFramesPerSecond = fps
        decodedFrames = decoded
        droppedFrames = dropped
        reportDecoderTelemetry(fps: fps, decoded: decoded, dropped: dropped)
#if DEBUG
        print(String(
            format: "PHONOSCOPE_STREAM_FPS %.2f transport=srt decoded=%lld dropped=%lld",
            fps, decoded, dropped
        ))
#endif
    }

    private func reportDecoderTelemetry(fps: Double, decoded: Int64, dropped: Int64) {
        guard let rendererControlURL else { return }
        Task {
            var request = URLRequest(url: rendererControlURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 2
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "command": "telemetry",
                "payload": [
                    "decodedFps": fps,
                    "decodedFrames": decoded,
                    "droppedFrames": dropped,
                ],
            ])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    private func reportTransportState(_ connectionState: String, reason: String? = nil) {
        guard let rendererControlURL else { return }
        Task {
            var payload: [String: Any] = [
                "connectionState": connectionState,
                "reconnectCount": totalReconnectCount,
            ]
            if let reason { payload["disconnectReason"] = reason }
            var request = URLRequest(url: rendererControlURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 2
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "command": "telemetry",
                "payload": payload,
            ])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    private func handleSRTDisconnect(
        reason: String, generation: Int, connection: OpaquePointer? = nil
    ) {
        if let connection, srtConnection == connection {
            srtConnection = nil
            NovaSRTRelease(connection)
        }
        guard !stopped, generation == transportGeneration else { return }
        hasPresentedFrame = false
        state = .failed(reason)
        reconnectAttempt = min(reconnectAttempt + 1, 5)
        totalReconnectCount += 1
        reportTransportState("reconnecting", reason: reason)
        let delay = Double(reconnectAttempt)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor in
                guard let self, !self.stopped, self.transportGeneration == generation else { return }
                if let port = self.activeSRTPort {
                    self.connectSRT(
                        host: self.activeHost,
                        port: port,
                        latencyMs: self.activeSRTLatencyMs,
                        generation: generation
                    )
                } else {
                    self.connectTCP(host: self.activeHost, port: self.activeTCPPort)
                }
            }
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 262_144) {
            [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.drain()
                }
                if isComplete || error != nil {
                    let reason = error?.localizedDescription ?? "stream closed"
                    if let connection = self.connection,
                       case let .hostPort(host, port) = connection.endpoint {
                        self.handleDisconnect(
                            host: "\(host)".trimmingCharacters(in: CharacterSet(charactersIn: "%")),
                            port: port.rawValue,
                            reason: reason
                        )
                    }
                    return
                }
                self.receive()
            }
        }
    }

    // MARK: - Framing

    private func drain() {
        if !handshakeComplete {
            guard buffer.count >= 12 else { return }
            guard Array(buffer.prefix(8)) == Self.magic else {
                state = .failed("unexpected stream header")
                connection?.cancel()
                return
            }
            let headerLength = Int(readUInt32(at: 8))
            guard buffer.count >= 12 + headerLength else { return }
            let headerData = buffer.subdata(in: 12 ..< (12 + headerLength))
            buffer.removeSubrange(0 ..< (12 + headerLength))
            applyHeader(headerData)
            handshakeComplete = true
        }

        while buffer.count >= Self.frameHeaderBytes {
            let payloadLength = Int(readUInt32(at: 4))
            let total = Self.frameHeaderBytes + payloadLength
            guard buffer.count >= total else { return }

            let type = buffer[buffer.startIndex]
            let keyframe = (buffer[buffer.startIndex + 1] & 1) != 0
            let ptsMicroseconds = readUInt64(at: 8)
            let payload = buffer.subdata(in: Self.frameHeaderBytes ..< total)
            buffer.removeSubrange(0 ..< total)

            if type == 0 {
                enqueue(annexB: payload, ptsMicroseconds: ptsMicroseconds, keyframe: keyframe)
            }
        }
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        let index = buffer.startIndex + offset
        return (UInt32(buffer[index]) << 24) | (UInt32(buffer[index + 1]) << 16)
            | (UInt32(buffer[index + 2]) << 8) | UInt32(buffer[index + 3])
    }

    private func readUInt64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in 0 ..< 8 {
            value = (value << 8) | UInt64(buffer[buffer.startIndex + offset + byte])
        }
        return value
    }

    nonisolated private static func readUInt32(in data: Data, at offset: Int) -> UInt32 {
        let index = data.startIndex + offset
        return (UInt32(data[index]) << 24) | (UInt32(data[index + 1]) << 16)
            | (UInt32(data[index + 2]) << 8) | UInt32(data[index + 3])
    }

    nonisolated private static func readUInt64(in data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in 0 ..< 8 {
            value = (value << 8) | UInt64(data[data.startIndex + offset + byte])
        }
        return value
    }

    private func applyHeader(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        // Parameter sets arrive base64-encoded in the handshake and are repeated
        // in-band on every IDR, so a mid-stream join also works.
        if let encoded = object["parameterSets"] as? String,
           let parameterSets = Data(base64Encoded: encoded) {
            buildFormatDescription(fromAnnexB: parameterSets)
        }
        if let latencyMs = object["latencyMs"] as? Double {
            pipelineDelaySeconds = latencyMs / 1_000
        } else if let latencyMs = object["latencyMs"] as? Int {
            pipelineDelaySeconds = Double(latencyMs) / 1_000
        }
    }

    /// Splits an Annex-B buffer into NAL units on 3- and 4-byte start codes.
    private func nalUnits(in data: Data) -> [Data] {
        var units: [Data] = []
        var index = data.startIndex
        var unitStart: Int?

        while index < data.endIndex {
            let remaining = data.distance(from: index, to: data.endIndex)
            var startCodeLength = 0
            if remaining >= 4, data[index] == 0, data[index + 1] == 0, data[index + 2] == 0,
               data[index + 3] == 1 {
                startCodeLength = 4
            } else if remaining >= 3, data[index] == 0, data[index + 1] == 0, data[index + 2] == 1 {
                startCodeLength = 3
            }

            if startCodeLength > 0 {
                if let start = unitStart, start < index {
                    units.append(data.subdata(in: start ..< index))
                }
                index += startCodeLength
                unitStart = index
            } else {
                index += 1
            }
        }
        if let start = unitStart, start < data.endIndex {
            units.append(data.subdata(in: start ..< data.endIndex))
        }
        return units
    }

    /// Stateless variant used by the SRT media queue. Keeping framing, Core
    /// Media conversion, and display-layer enqueueing on that queue prevents a
    /// burst of 4K access units from starving SwiftUI's main actor.
    nonisolated private static func nalUnitsStatic(in data: Data) -> [Data] {
        var units: [Data] = []
        var index = data.startIndex
        var unitStart: Int?

        while index < data.endIndex {
            let remaining = data.distance(from: index, to: data.endIndex)
            var startCodeLength = 0
            if remaining >= 4, data[index] == 0, data[index + 1] == 0, data[index + 2] == 0,
               data[index + 3] == 1 {
                startCodeLength = 4
            } else if remaining >= 3, data[index] == 0, data[index + 1] == 0, data[index + 2] == 1 {
                startCodeLength = 3
            }

            if startCodeLength > 0 {
                if let start = unitStart, start < index {
                    units.append(data.subdata(in: start ..< index))
                }
                index += startCodeLength
                unitStart = index
            } else {
                index += 1
            }
        }
        if let start = unitStart, start < data.endIndex {
            units.append(data.subdata(in: start ..< data.endIndex))
        }
        return units
    }

    nonisolated private static func makeFormatDescription(
        fromAnnexB data: Data
    ) -> CMFormatDescription? {
        var parameterSets: [Data?] = [nil, nil, nil]
        for unit in nalUnitsStatic(in: data) {
            guard let first = unit.first else { continue }
            switch (first >> 1) & 0x3F {
            case 32: parameterSets[0] = unit
            case 33: parameterSets[1] = unit
            case 34: parameterSets[2] = unit
            default: break
            }
        }
        guard let vps = parameterSets[0], let sps = parameterSets[1],
              let pps = parameterSets[2]
        else { return nil }

        let retainedSets = [vps, sps, pps]
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        var retained: [UnsafeMutablePointer<UInt8>] = []
        for set in retainedSets {
            let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: storage, count: set.count)
            retained.append(storage)
            pointers.append(UnsafePointer(storage))
            sizes.append(set.count)
        }
        defer { retained.forEach { $0.deallocate() } }

        var description: CMFormatDescription?
        let status = pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: retainedSets.count,
                    parameterSetPointers: pointerBuffer.baseAddress!,
                    parameterSetSizes: sizeBuffer.baseAddress!,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            }
        }
        return status == noErr ? description : nil
    }

    nonisolated private static func makeSampleBuffer(
        annexB: Data,
        ptsMicroseconds: UInt64,
        formatDescription: CMFormatDescription
    ) -> CMSampleBuffer? {
        var lengthPrefixed = Data()
        lengthPrefixed.reserveCapacity(annexB.count + 16)
        for unit in nalUnitsStatic(in: annexB) {
            guard let first = unit.first else { continue }
            let type = (first >> 1) & 0x3F
            if type == 32 || type == 33 || type == 34 { continue }
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { lengthPrefixed.append(contentsOf: $0) }
            lengthPrefixed.append(unit)
        }
        guard !lengthPrefixed.isEmpty else { return nil }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: lengthPrefixed.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: lengthPrefixed.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        let copyStatus = lengthPrefixed.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: lengthPrefixed.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = lengthPrefixed.count
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: CMTimeValue(ptsMicroseconds), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        return sampleBuffer
    }

    nonisolated private static func primePresentationTimebase(
        _ timebase: CMTimebase?, ptsMicroseconds: UInt64
    ) {
        guard let timebase else { return }
        let pts = CMTime(value: CMTimeValue(ptsMicroseconds), timescale: 1_000_000)
        let oneFrame = CMTime(value: 1, timescale: 60)
        // At this host instant the media clock is one frame behind the sample,
        // so this PTS becomes due one frame from now. Subsequent frames keep
        // their server-authored cadence instead of being burst-presented.
        CMTimebaseSetTime(timebase, time: CMTimeSubtract(pts, oneFrame))
        CMTimebaseSetRate(timebase, rate: 1)
    }

    private func buildFormatDescription(fromAnnexB data: Data) {
        let units = nalUnits(in: data)
        var vps: Data?
        var sps: Data?
        var pps: Data?
        for unit in units {
            guard let first = unit.first else { continue }
            // HEVC NAL type is bits 1..6 of the first header byte.
            switch (first >> 1) & 0x3F {
            case 32: vps = unit
            case 33: sps = unit
            case 34: pps = unit
            default: break
            }
        }
        guard let vps, let sps, let pps else { return }

        let parameterSets = [vps, sps, pps]
        // Skip the rebuild when the bytes are identical to the ones already in
        // use, which is the case at every IDR.
        let fingerprint = parameterSets.reduce(into: Data()) { $0.append($1) }
        if fingerprint == parameterSetsFingerprint, formatDescription != nil { return }

        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        var retained: [UnsafeMutablePointer<UInt8>] = []
        for set in parameterSets {
            let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: storage, count: set.count)
            retained.append(storage)
            pointers.append(UnsafePointer(storage))
            sizes.append(set.count)
        }
        defer { retained.forEach { $0.deallocate() } }

        var description: CMFormatDescription?
        let status = pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: parameterSets.count,
                    parameterSetPointers: pointerBuffer.baseAddress!,
                    parameterSetSizes: sizeBuffer.baseAddress!,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            }
        }
        if status == noErr {
            formatDescription = description
            parameterSetsFingerprint = fingerprint
        }
    }

    private func enqueue(annexB: Data, ptsMicroseconds: UInt64, keyframe: Bool) {
        // Every IDR repeats VPS/SPS/PPS in-band, so the format description is
        // rebuilt on keyframes as well as from the handshake. That is what lets
        // a client join a stream that is already running.
        if keyframe || formatDescription == nil {
            buildFormatDescription(fromAnnexB: annexB)
        }
        guard let formatDescription else { return }

        // Annex-B start codes become 4-byte big-endian lengths (AVCC/HVCC),
        // which is what CMBlockBuffer expects.
        var lengthPrefixed = Data()
        lengthPrefixed.reserveCapacity(annexB.count + 16)
        for unit in nalUnits(in: annexB) {
            guard let first = unit.first else { continue }
            let type = (first >> 1) & 0x3F
            // Parameter sets live in the format description, not the sample.
            if type == 32 || type == 33 || type == 34 { continue }
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { lengthPrefixed.append(contentsOf: $0) }
            lengthPrefixed.append(unit)
        }
        guard !lengthPrefixed.isEmpty else { return }

        var blockBuffer: CMBlockBuffer?
        let sampleBytes = [UInt8](lengthPrefixed)
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: sampleBytes.count)
        storage.update(from: sampleBytes, count: sampleBytes.count)
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: storage,
            blockLength: sampleBytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sampleBytes.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else {
            storage.deallocate()
            return
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = sampleBytes.count
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: CMTimeValue(ptsMicroseconds), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return }

        if displayLayer.status == .failed {
            // A failed renderer needs a flush AND a stream access point: after a
            // flush the decoder has no reference frames, so every inter-coded
            // frame until the next IDR is wasted. The server used to have no way
            // to hear about this and the picture stayed frozen until the next
            // scheduled GOP boundary, up to two seconds away.
            displayLayer.flush()
            droppedFrames += 1
            timebasePrimed = false
            requestKeyframe()
        }
        if !timebasePrimed {
            Self.primePresentationTimebase(presentationTimebase, ptsMicroseconds: ptsMicroseconds)
            timebasePrimed = true
        }
        displayLayer.enqueue(sampleBuffer)

        decodedFrames += 1
        fpsFrames += 1
        if !hasPresentedFrame {
            hasPresentedFrame = true
            state = .streaming
        }

        let now = CACurrentMediaTime()
        if now - fpsWindowStart >= 1 {
            measuredFramesPerSecond = Double(fpsFrames) / (now - fpsWindowStart)
#if DEBUG
            print(String(
                format: "PHONOSCOPE_STREAM_FPS %.2f transport=%@ decoded=%lld dropped=%lld",
                measuredFramesPerSecond,
                srtConnection == nil ? "tcp" : "srt",
                decodedFrames,
                droppedFrames
            ))
#endif
            fpsFrames = 0
            fpsWindowStart = now
        }
        if now - lastReportAt >= 1 {
            lastReportAt = now
            reportTelemetry()
        }
    }

    // MARK: - Recovery

    /// Asks the renderer for an IDR. Sent when the decoder has failed and been
    /// flushed, so the picture resumes at the next frame the server can produce
    /// rather than at the next scheduled GOP boundary.
    ///
    /// Rate-limited on the server too — a client flapping on bad WiFi must not
    /// be able to turn the stream into an unbroken run of IDRs, which would be
    /// its own kind of hitching.
    private var lastKeyframeRequestAt = 0.0

    private func requestKeyframe() {
        let now = CACurrentMediaTime()
        guard now - lastKeyframeRequestAt >= 0.5 else { return }
        lastKeyframeRequestAt = now

        if let connection {
            var packet = Data()
            packet.append(0x81)
            // Length-prefixed with an empty body: the server consumes the body
            // for every message type, so the framing stays in step.
            var length = UInt32(0).bigEndian
            withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
            connection.send(content: packet, completion: .idempotent)
        } else if let rendererControlURL {
            Task {
                var request = URLRequest(url: rendererControlURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: ["command": "keyframe"])
                request.timeoutInterval = 2
                _ = try? await URLSession.shared.data(for: request)
            }
        }
    }

    // MARK: - Latency feedback

    /// Reports the measured presentation delay back to the renderer, which uses
    /// it to draw ahead by that much. Audio plays here while video takes an
    /// encode/network/decode path; without this loop every beat lands late.
    private func reportTelemetry() {
        // SRT's TSBPD clock and server-side RTT/loss stats are authoritative.
        // This legacy estimate exists only for the TCP fallback.
        guard connection != nil else { return }
        // Estimated from the layer's own queue depth plus one frame of decode.
        // The absolute value matters less than that it is stable: the server
        // smooths it heavily before applying it as a clock offset.
        let queued = displayLayer.isReadyForMoreMediaData ? 1.0 : 3.0
        pipelineDelaySeconds = pipelineDelaySeconds * 0.8 + (queued / 60.0) * 0.2

        let payload: [String: Any] = [
            "presentationDelayMs": pipelineDelaySeconds * 1_000,
            "decodedFrames": decodedFrames,
            "droppedFrames": droppedFrames,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var packet = Data()
        packet.append(0x80)
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
        packet.append(body)
        connection?.send(content: packet, completion: .idempotent)
    }
}
