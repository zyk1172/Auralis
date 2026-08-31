import AVFoundation
import AudioToolbox
import Foundation

/// A decoded piece produced before the remote HTTP response reaches EOF. The
/// decoder deliberately returns canonical mono Float32 PCM so the DSP path is
/// identical for FLAC, AAC, MP3, and a local file.
public struct MusicHapticsDecodedPCMChunk: Sendable {
    public let data: Data
    public let time: TimeInterval
    public let frameCount: Int
    public let format: MusicHapticsPCMFormat
    public let sourceByteOffset: Int64
    public let packetIndex: Int64

    public init(
        data: Data,
        time: TimeInterval,
        frameCount: Int,
        format: MusicHapticsPCMFormat,
        sourceByteOffset: Int64,
        packetIndex: Int64
    ) {
        self.data = data
        self.time = time
        self.frameCount = frameCount
        self.format = format
        self.sourceByteOffset = max(0, sourceByteOffset)
        self.packetIndex = max(0, packetIndex)
    }
}

public struct MusicHapticsProgressiveDecoderMetrics: Sendable, Equatable {
    public let position: TimeInterval
    public let speedX: Double
    public let bytesReceived: Int64
    public let packetsDecoded: Int64
    public let responseComplete: Bool
    public let state: MusicHapticsRemoteDecoderState

    public init(
        position: TimeInterval,
        speedX: Double,
        bytesReceived: Int64,
        packetsDecoded: Int64,
        responseComplete: Bool,
        state: MusicHapticsRemoteDecoderState
    ) {
        self.position = max(0, position.isFinite ? position : 0)
        self.speedX = max(0, speedX.isFinite ? speedX : 0)
        self.bytesReceived = max(0, bytesReceived)
        self.packetsDecoded = max(0, packetsDecoded)
        self.responseComplete = responseComplete
        self.state = state
    }
}

public enum MusicHapticsProgressiveDecoderError: Error, Sendable, Equatable {
    case invalidURL
    case nonHTTPResponse
    case httpStatus(Int)
    case rangeNotHonored
    case streamOpen(OSStatus)
    case streamParse(OSStatus)
    case streamProperty(OSStatus)
    case noAudioFormat
    case converterUnavailable
    case converter(OSStatus)
    case sampleDataUnavailable
    case noAudioPacket
}

/// Incrementally parses and decodes the original encoded stream.
///
/// `AudioFileStream` is specifically designed for a bounded window of bytes;
/// it emits packets as soon as enough bytes arrive. `AVAudioConverter` then
/// decodes those packets to PCM. At no point does this type use a full-file
/// download API, create a complete temporary file, or touch an AVPlayerItem.
public final class MusicHapticsProgressiveAudioDecoder: @unchecked Sendable {
    public typealias PCMHandler = @Sendable (MusicHapticsDecodedPCMChunk) async -> Void
    public typealias MetricsHandler = @Sendable (MusicHapticsProgressiveDecoderMetrics) -> Void
    public typealias ResumePointHandler = @Sendable (MusicHapticsDecoderResumePoint) async -> Void

    private let chunkByteCapacity: Int
    private let outputSampleRate: Double
    private let resumeHeaderByteCapacity = 64 * 1024

    // Keep the parser feed small enough to publish PCM while a response is
    // still open. This is a transport/parser batch size, not an analysis or
    // playback window; the decoder continues consuming until EOF and can run
    // arbitrarily ahead of AVPlayer.
    public init(chunkByteCapacity: Int = 16 * 1024, outputSampleRate: Double = 22_050) {
        self.chunkByteCapacity = min(max(4 * 1024, chunkByteCapacity), 512 * 1024)
        self.outputSampleRate = min(max(8_000, outputSampleRate), 48_000)
    }

    public func decode(
        url: URL,
        startPosition: TimeInterval = 0,
        resumePoint: MusicHapticsDecoderResumePoint? = nil,
        stopAtPosition: TimeInterval? = nil,
        onPCM: @escaping PCMHandler,
        onMetrics: @escaping MetricsHandler = { _ in },
        onResumePoint: @escaping ResumePointHandler = { _ in }
    ) async throws {
        guard url.isFileURL || url.scheme?.isEmpty == false else {
            throw MusicHapticsProgressiveDecoderError.invalidURL
        }

        let safeStart = max(0, startPosition.isFinite ? startPosition : 0)
        let safeStop: TimeInterval? = stopAtPosition.flatMap { value in
            guard value.isFinite else { return nil }
            return max(safeStart, value)
        }
        if let safeStop, safeStop <= safeStart + 0.001 { return }
        let anchor = resumePoint.map {
            MusicHapticsDecoderResumePoint(
                position: max(safeStart, $0.position),
                byteOffset: $0.byteOffset,
                packetIndex: $0.packetIndex
            )
        }
        // A compressed stream cannot be decoded correctly by starting at an
        // arbitrary byte without first restoring its header/codec state. If
        // no safe anchor exists, parse from byte zero and let the analyzer
        // discard already-covered PCM without re-running its DSP.
        let decoderStartPosition = anchor == nil ? 0 : anchor!.position
        let parser = try StreamParser(
            startPosition: decoderStartPosition,
            packetIndex: anchor?.packetIndex ?? 0,
            outputSampleRate: outputSampleRate
        )
        let startedAt = ContinuousClock.now
        var bytesReceived: Int64 = 0

        var stoppedAtTarget = false
        let consume: @Sendable (Data, Int64, Bool, Int64) async throws -> Bool = { [parser] data, baseOffset, responseComplete, bytesReceived in
            guard !data.isEmpty else { return true }
            try parser.parse(data: data, baseOffset: baseOffset)
            let packets = parser.takePackets()
            for packet in packets {
                let chunks = try parser.decode(packet: packet)
                var reachedStopTarget = false
                for chunk in chunks {
                    await onPCM(chunk)
                    if let safeStop,
                       chunk.time + Double(chunk.frameCount) / chunk.format.sampleRate >= safeStop {
                        reachedStopTarget = true
                        break
                    }
                }
                // Do not persist an anchor after a compressed packet that
                // crossed the requested hole boundary. Its byte offset is
                // safe for the decoder, but its timestamp may already be past
                // the first missing sample. Keeping the previous packet
                // anchor causes a small, harmless decode overlap on resume;
                // the analyzer clips it and never re-runs DSP for covered
                // ranges.
                if !reachedStopTarget, let resume = parser.resumePoint(after: packet) {
                    await onResumePoint(resume)
                }
                if reachedStopTarget { return false }
            }
            if !packets.isEmpty {
                let wall = Self.durationSeconds(startedAt.duration(to: .now))
                onMetrics(MusicHapticsProgressiveDecoderMetrics(
                    position: parser.outputPosition,
                    speedX: wall > 0 ? parser.processedAudioDuration / wall : 0,
                    bytesReceived: bytesReceived,
                    packetsDecoded: parser.packetsDecoded,
                    responseComplete: responseComplete,
                    state: .streaming
                ))
            }
            return true
        }

        let drainPendingPackets: @Sendable (Bool, Int64) async throws -> Void = { [parser] responseComplete, receivedBytes in
            let packets = parser.takePackets()
            for packet in packets {
                let chunks = try parser.decode(packet: packet)
                for chunk in chunks { await onPCM(chunk) }
                if let resume = parser.resumePoint(after: packet) {
                    await onResumePoint(resume)
                }
            }
            if !packets.isEmpty {
                let wall = Self.durationSeconds(startedAt.duration(to: .now))
                onMetrics(MusicHapticsProgressiveDecoderMetrics(
                    position: parser.outputPosition,
                    speedX: wall > 0 ? parser.processedAudioDuration / wall : 0,
                    bytesReceived: receivedBytes,
                    packetsDecoded: parser.packetsDecoded,
                    responseComplete: responseComplete,
                    state: .streaming
                ))
            }
        }

        if url.isFileURL {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let offset = anchor?.byteOffset ?? 0
            if offset > 0 {
                // Prime AudioFileStream with the file header/metadata before
                // seeking to the packet anchor. Packets emitted while
                // priming are discarded; only packets at the anchor reach
                // the DSP path.
                let headerEnd = min(offset, Int64(resumeHeaderByteCapacity))
                file.seek(toFileOffset: 0)
                var headerOffset: Int64 = 0
                while headerOffset < headerEnd {
                    let count = min(chunkByteCapacity, Int(headerEnd - headerOffset))
                    guard let data = try file.read(upToCount: count), !data.isEmpty else { break }
                    try parser.parse(data: data, baseOffset: headerOffset)
                    _ = parser.takePackets()
                    headerOffset += Int64(data.count)
                }
                guard parser.isConfigured else { throw parser.configurationFailure }
                try parser.prepareForResume(
                    position: anchor?.position ?? safeStart,
                    packetIndex: anchor?.packetIndex ?? 0
                )
                file.seek(toFileOffset: UInt64(offset))
            }
            var baseOffset = offset
            var stoppedEarly = false
            while true {
                try Task.checkCancellation()
                guard let data = try file.read(upToCount: chunkByteCapacity), !data.isEmpty else { break }
                bytesReceived += Int64(data.count)
                if try await consume(data, baseOffset, false, bytesReceived) == false {
                    stoppedAtTarget = true
                    stoppedEarly = true
                    break
                }
                baseOffset += Int64(data.count)
            }
            if stoppedEarly {
                let wall = Self.durationSeconds(startedAt.duration(to: .now))
                onMetrics(MusicHapticsProgressiveDecoderMetrics(
                    position: parser.outputPosition,
                    speedX: wall > 0 ? parser.processedAudioDuration / wall : 0,
                    bytesReceived: bytesReceived,
                    packetsDecoded: parser.packetsDecoded,
                    responseComplete: false,
                    state: .streaming
                ))
                return
            }
            try parser.finish()
            try await drainPendingPackets(true, bytesReceived)
            try await parser.finishConversion(onPCM: onPCM)
        } else {
            let requestedOffset = anchor?.byteOffset ?? 0
            var streamOffset = requestedOffset
            let streamResult: (URLSession.AsyncBytes, URLResponse)
            if requestedOffset > 0 {
                // Prime only the bounded header prefix. The subsequent Range
                // request starts at a packet boundary and reuses the same
                // AudioFileStream parser, so FLAC metadata and codec cookies
                // are available without replaying the entire file.
                let headerEnd = min(requestedOffset, Int64(resumeHeaderByteCapacity))
                let headerRequest = Self.makeRequest(
                    url: url,
                    range: "bytes=0-\(headerEnd - 1)"
                )
                let headerResult = try await URLSession.shared.bytes(for: headerRequest)
                guard let headerHTTP = headerResult.1 as? HTTPURLResponse else {
                    throw MusicHapticsProgressiveDecoderError.nonHTTPResponse
                }
                guard (200..<300).contains(headerHTTP.statusCode) else {
                    throw MusicHapticsProgressiveDecoderError.httpStatus(headerHTTP.statusCode)
                }
                var headerBuffer = Data()
                headerBuffer.reserveCapacity(Int(headerEnd))
                var headerOffset: Int64 = 0
                for try await byte in headerResult.0 {
                    try Task.checkCancellation()
                    headerBuffer.append(byte)
                    if headerBuffer.count >= chunkByteCapacity {
                        try parser.parse(data: headerBuffer, baseOffset: headerOffset)
                        _ = parser.takePackets()
                        headerOffset += Int64(headerBuffer.count)
                        headerBuffer.removeAll(keepingCapacity: true)
                    }
                    if headerOffset + Int64(headerBuffer.count) >= headerEnd { break }
                }
                if !headerBuffer.isEmpty {
                    try parser.parse(data: headerBuffer, baseOffset: headerOffset)
                    _ = parser.takePackets()
                }
                guard parser.isConfigured else { throw parser.configurationFailure }
                try parser.prepareForResume(
                    position: anchor?.position ?? safeStart,
                    packetIndex: anchor?.packetIndex ?? 0
                )

                let rangeResult = try await URLSession.shared.bytes(
                    for: Self.makeRequest(url: url, range: "bytes=\(requestedOffset)-")
                )
                guard let rangeHTTP = rangeResult.1 as? HTTPURLResponse else {
                    throw MusicHapticsProgressiveDecoderError.nonHTTPResponse
                }
                guard (200..<300).contains(rangeHTTP.statusCode) else {
                    throw MusicHapticsProgressiveDecoderError.httpStatus(rangeHTTP.statusCode)
                }
                if rangeHTTP.statusCode == 206 {
                    streamResult = rangeResult
                } else {
                    // Servers without byte ranges remain usable: restart a
                    // fresh parser and consume the original stream from byte
                    // zero incrementally. The analyzer still clips this
                    // replay to the uncovered range and never re-runs DSP for
                    // already-covered timeline ranges.
                    try parser.restart(position: 0, packetIndex: 0)
                    streamOffset = 0
                    // A 200 response to the Range request is already the
                    // original stream. Reuse that live byte sequence instead
                    // of opening a second request (and potentially racing a
                    // short-lived token); it is still consumed incrementally.
                    streamResult = rangeResult
                }
            } else {
                streamResult = try await URLSession.shared.bytes(
                    for: Self.makeRequest(url: url, range: nil)
                )
            }
            let bytes = streamResult.0
            let response = streamResult.1
            guard let http = response as? HTTPURLResponse else {
                throw MusicHapticsProgressiveDecoderError.nonHTTPResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw MusicHapticsProgressiveDecoderError.httpStatus(http.statusCode)
            }
            var buffer = Data()
            buffer.reserveCapacity(chunkByteCapacity)
            var chunkOffset = streamOffset
            var stoppedEarly = false
            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                if buffer.count < chunkByteCapacity { continue }
                bytesReceived += Int64(buffer.count)
                if try await consume(buffer, chunkOffset, false, bytesReceived) == false {
                    stoppedAtTarget = true
                    stoppedEarly = true
                    break
                }
                chunkOffset += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
            }
            if !stoppedEarly, !buffer.isEmpty {
                bytesReceived += Int64(buffer.count)
                stoppedEarly = try await consume(buffer, chunkOffset, true, bytesReceived) == false
                if stoppedEarly { stoppedAtTarget = true }
            }
            if stoppedEarly {
                let wall = Self.durationSeconds(startedAt.duration(to: .now))
                onMetrics(MusicHapticsProgressiveDecoderMetrics(
                    position: parser.outputPosition,
                    speedX: wall > 0 ? parser.processedAudioDuration / wall : 0,
                    bytesReceived: bytesReceived,
                    packetsDecoded: parser.packetsDecoded,
                    responseComplete: false,
                    state: .streaming
                ))
                return
            }
            try parser.finish()
            let packets = parser.takePackets()
            for packet in packets {
                let chunks = try parser.decode(packet: packet)
                for chunk in chunks { await onPCM(chunk) }
                if let resume = parser.resumePoint(after: packet) {
                    await onResumePoint(resume)
                }
            }
            try await parser.finishConversion(onPCM: onPCM)
        }

        guard parser.packetsDecoded > 0 else {
            onMetrics(MusicHapticsProgressiveDecoderMetrics(
                position: parser.outputPosition,
                speedX: 0,
                bytesReceived: bytesReceived,
                packetsDecoded: parser.packetsDecoded,
                responseComplete: true,
                state: .failed
            ))
            throw MusicHapticsProgressiveDecoderError.noAudioPacket
        }
        let wall = Self.durationSeconds(startedAt.duration(to: .now))
        onMetrics(MusicHapticsProgressiveDecoderMetrics(
            position: parser.outputPosition,
            speedX: wall > 0 ? parser.processedAudioDuration / wall : 0,
            bytesReceived: bytesReceived,
            packetsDecoded: parser.packetsDecoded,
            responseComplete: !stoppedAtTarget,
            state: stoppedAtTarget ? .streaming : .complete
        ))
    }

    private static func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func makeRequest(url: URL, range: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("audio/*;q=0.9,*/*;q=0.1", forHTTPHeaderField: "Accept")
        if let range {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        return request
    }

    private final class StreamParser: @unchecked Sendable {
        struct Packet: @unchecked Sendable {
            let data: Data
            let byteOffset: Int64
            let packetIndex: Int64
            let frameCount: Int
            let startPosition: TimeInterval
        }

        private var stream: AudioFileStreamID?
        private var sourceFormat: AVAudioFormat?
        private var converter: AVAudioConverter?
        private let outputFormat: AVAudioFormat
        private let pcmFormat: MusicHapticsPCMFormat
        private var pendingPackets: [Packet] = []
        private var inputBaseOffset: Int64 = 0
        private var startPosition: TimeInterval
        private var nextPacketFrame: Int64
        private var nextPacketIndex: Int64
        private var outputFrameCount: Int64 = 0
        private var didSetPacketClock = false
        private var lastPropertyStatus: OSStatus?
        private var converterInitializationFailed = false
        private var lastPacket: Packet?
        private(set) var packetsDecoded: Int64 = 0
        private(set) var processedAudioDuration: TimeInterval = 0

        var outputPosition: TimeInterval {
            Double(outputFrameCount) / outputFormat.sampleRate
        }

        init(startPosition: TimeInterval, packetIndex: Int64, outputSampleRate: Double) throws {
            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: outputSampleRate,
                channels: 1,
                interleaved: true
            ),
            let pcmFormat = MusicHapticsPCMFormat(
                sampleRate: outputSampleRate,
                channels: 1,
                sampleType: .float32,
                interleaved: true,
                bytesPerFrame: MemoryLayout<Float32>.size,
                bytesPerSample: MemoryLayout<Float32>.size
            ) else {
                throw MusicHapticsProgressiveDecoderError.noAudioFormat
            }
            self.outputFormat = outputFormat
            self.pcmFormat = pcmFormat
            self.startPosition = max(0, startPosition)
            self.nextPacketFrame = 0
            self.nextPacketIndex = max(0, packetIndex)
            self.outputFrameCount = Int64((self.startPosition * outputSampleRate).rounded())
            try openStream()
        }

        deinit {
            if let stream { AudioFileStreamClose(stream) }
        }

        var isConfigured: Bool {
            sourceFormat != nil && converter != nil
        }

        var configurationFailure: MusicHapticsProgressiveDecoderError {
            if let lastPropertyStatus {
                return .streamProperty(lastPropertyStatus)
            }
            if converterInitializationFailed {
                return .converterUnavailable
            }
            return .noAudioFormat
        }

        /// Restores the logical decoder clock after a bounded header prime.
        /// AudioFileStream keeps the parsed format/cookie state, while packet
        /// numbering and output timestamps restart exactly at the persisted
        /// packet boundary.
        func prepareForResume(
            position: TimeInterval,
            packetIndex: Int64
        ) throws {
            guard isConfigured else {
                throw MusicHapticsProgressiveDecoderError.noAudioFormat
            }
            startPosition = max(0, position)
            nextPacketFrame = Int64((startPosition * sourceFormat!.sampleRate).rounded())
            nextPacketIndex = max(0, packetIndex)
            outputFrameCount = Int64((startPosition * outputFormat.sampleRate).rounded())
            packetsDecoded = 0
            processedAudioDuration = 0
            didSetPacketClock = true
            pendingPackets.removeAll(keepingCapacity: true)
            lastPacket = nil
            converter?.reset()
        }

        /// Reopens the parser when a server ignores a byte-range request. It
        /// is still incremental, but starts from byte zero and lets the
        /// analyzer discard covered ranges without duplicate DSP events.
        func restart(position: TimeInterval, packetIndex: Int64) throws {
            if let stream { AudioFileStreamClose(stream) }
            stream = nil
            sourceFormat = nil
            converter = nil
            lastPropertyStatus = nil
            converterInitializationFailed = false
            pendingPackets.removeAll(keepingCapacity: true)
            inputBaseOffset = 0
            startPosition = max(0, position)
            nextPacketFrame = 0
            nextPacketIndex = max(0, packetIndex)
            outputFrameCount = Int64((startPosition * outputFormat.sampleRate).rounded())
            didSetPacketClock = false
            lastPacket = nil
            packetsDecoded = 0
            processedAudioDuration = 0
            try openStream()
        }

        private func openStream() throws {
            var stream: AudioFileStreamID?
            let status = AudioFileStreamOpen(
                Unmanaged.passUnretained(self).toOpaque(),
                Self.propertyListener,
                Self.packetsListener,
                0,
                &stream
            )
            guard status == noErr, let stream else {
                throw MusicHapticsProgressiveDecoderError.streamOpen(status)
            }
            self.stream = stream
        }

        func parse(data: Data, baseOffset: Int64) throws {
            guard let stream else { throw MusicHapticsProgressiveDecoderError.streamOpen(-1) }
            inputBaseOffset = baseOffset
            let status = data.withUnsafeBytes { rawBuffer -> OSStatus in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return AudioFileStreamParseBytes(
                    stream,
                    UInt32(rawBuffer.count),
                    baseAddress,
                    []
                )
            }
            guard status == noErr else {
                throw MusicHapticsProgressiveDecoderError.streamParse(status)
            }
        }

        func finish() throws {
            guard let stream else { return }
            let status = AudioFileStreamParseBytes(stream, 0, nil, [])
            guard status == noErr else {
                throw MusicHapticsProgressiveDecoderError.streamParse(status)
            }
        }

        func takePackets() -> [Packet] {
            defer { pendingPackets.removeAll(keepingCapacity: true) }
            return pendingPackets
        }

        func decode(packet: Packet) throws -> [MusicHapticsDecodedPCMChunk] {
            guard let converter else {
                throw MusicHapticsProgressiveDecoderError.converterUnavailable
            }
            guard packet.data.count > 0,
                  packet.data.count <= Int(UInt32.max)
            else {
                throw MusicHapticsProgressiveDecoderError.sampleDataUnavailable
            }
            let capacity = packet.data.count
            let compressed = AVAudioCompressedBuffer(
                format: converter.inputFormat,
                packetCapacity: 1,
                maximumPacketSize: capacity
            )
            packet.data.withUnsafeBytes { rawBuffer in
                if let baseAddress = rawBuffer.baseAddress {
                    compressed.data.copyMemory(from: baseAddress, byteCount: rawBuffer.count)
                }
            }
            compressed.byteLength = UInt32(packet.data.count)
            compressed.packetCount = 1
            if let descriptions = compressed.packetDescriptions {
                descriptions.pointee = AudioStreamPacketDescription(
                    mStartOffset: 0,
                    mVariableFramesInPacket: UInt32(packet.frameCount),
                    mDataByteSize: UInt32(packet.data.count)
                )
            }

            var inputUsed = false
            var chunks: [MusicHapticsDecodedPCMChunk] = []
            while true {
                guard let output = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: 8_192
                ) else {
                    throw MusicHapticsProgressiveDecoderError.noAudioFormat
                }
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { _, status in
                    if inputUsed {
                        status.pointee = .noDataNow
                        return nil
                    }
                    inputUsed = true
                    status.pointee = .haveData
                    return compressed
                }
                if let conversionError {
                    let nsError = conversionError as NSError
                    throw MusicHapticsProgressiveDecoderError.converter(OSStatus(nsError.code))
                }
                if output.frameLength > 0 {
                    guard let channel = output.floatChannelData?[0] else {
                        throw MusicHapticsProgressiveDecoderError.noAudioFormat
                    }
                    let frameCount = Int(output.frameLength)
                    let byteCount = frameCount * MemoryLayout<Float32>.size
                    let data = Data(bytes: channel, count: byteCount)
                    let time = outputPosition
                    chunks.append(MusicHapticsDecodedPCMChunk(
                        data: data,
                        time: time,
                        frameCount: frameCount,
                        format: pcmFormat,
                        sourceByteOffset: packet.byteOffset,
                        packetIndex: packet.packetIndex
                    ))
                    outputFrameCount += Int64(frameCount)
                    processedAudioDuration += Double(frameCount) / outputFormat.sampleRate
                }
                switch status {
                case .haveData:
                    if inputUsed { return chunks }
                case .inputRanDry, .endOfStream:
                    return chunks
                case .error:
                    throw MusicHapticsProgressiveDecoderError.converter(-1)
                @unknown default:
                    return chunks
                }
            }
        }

        func finishConversion(
            onPCM: @escaping PCMHandler
        ) async throws {
            guard let converter else { return }
            while true {
                guard let output = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: 8_192
                ) else { return }
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if let conversionError {
                    let nsError = conversionError as NSError
                    throw MusicHapticsProgressiveDecoderError.converter(OSStatus(nsError.code))
                }
                guard output.frameLength > 0 else { return }
                guard let channel = output.floatChannelData?[0] else { return }
                let frameCount = Int(output.frameLength)
                let data = Data(bytes: channel, count: frameCount * MemoryLayout<Float32>.size)
                let chunk = MusicHapticsDecodedPCMChunk(
                    data: data,
                    time: outputPosition,
                    frameCount: frameCount,
                    format: pcmFormat,
                    sourceByteOffset: lastPacket?.byteOffset ?? 0,
                    packetIndex: lastPacket?.packetIndex ?? 0
                )
                outputFrameCount += Int64(frameCount)
                processedAudioDuration += Double(frameCount) / outputFormat.sampleRate
                await onPCM(chunk)
                if status == .endOfStream { return }
            }
        }

        func resumePoint(after packet: Packet) -> MusicHapticsDecoderResumePoint? {
            guard let sourceFormat,
                  sourceFormat.sampleRate > 0 else { return nil }
            let position = packet.startPosition + Double(packet.frameCount) / sourceFormat.sampleRate
            return MusicHapticsDecoderResumePoint(
                position: position,
                byteOffset: packet.byteOffset + Int64(packet.data.count),
                packetIndex: packet.packetIndex + 1
            )
        }

        private func configureIfNeeded() {
            guard let stream,
                  let sourceFormat = sourceFormatFromStream(stream)
            else { return }
            if !didSetPacketClock {
                self.sourceFormat = sourceFormat
                nextPacketFrame = Int64((startPosition * sourceFormat.sampleRate).rounded())
                didSetPacketClock = true
            }
            if let converter {
                if let cookie = magicCookie(from: stream) {
                    converter.magicCookie = cookie
                }
                return
            }
            self.sourceFormat = sourceFormat
            guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
                converterInitializationFailed = true
                return
            }
            converter.downmix = true
            converter.primeMethod = .none
            if let cookie = magicCookie(from: stream) {
                converter.magicCookie = cookie
            }
            self.converter = converter
        }

        private func sourceFormatFromStream(_ stream: AudioFileStreamID) -> AVAudioFormat? {
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = AudioFileStreamGetProperty(
                stream,
                kAudioFileStreamProperty_DataFormat,
                &size,
                &asbd
            )
            guard status == noErr else {
                lastPropertyStatus = status
                return nil
            }
            return AVAudioFormat(streamDescription: &asbd)
        }

        private func magicCookie(from stream: AudioFileStreamID) -> Data? {
            var size = UInt32(0)
            guard AudioFileStreamGetPropertyInfo(
                stream,
                kAudioFileStreamProperty_MagicCookieData,
                &size,
                nil
            ) == noErr, size > 0 else { return nil }
            var data = Data(count: Int(size))
            let status = data.withUnsafeMutableBytes { rawBuffer -> OSStatus in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return AudioFileStreamGetProperty(
                    stream,
                    kAudioFileStreamProperty_MagicCookieData,
                    &size,
                    baseAddress
                )
            }
            return status == noErr ? data : nil
        }

        private static let propertyListener: AudioFileStream_PropertyListenerProc = {
            clientData, stream, propertyID, _ in
            let clientData = clientData
            let parser = Unmanaged<StreamParser>.fromOpaque(clientData).takeUnretainedValue()
            if propertyID == kAudioFileStreamProperty_DataFormat
                || propertyID == kAudioFileStreamProperty_ReadyToProducePackets
                || propertyID == kAudioFileStreamProperty_MagicCookieData {
                parser.configureIfNeeded()
            }
        }

        private static let packetsListener: AudioFileStream_PacketsProc = {
            clientData, numberBytes, numberPackets, inputData, descriptions in
            let clientData = clientData
            let inputData = inputData
            guard numberPackets > 0 else { return }
            let parser = Unmanaged<StreamParser>.fromOpaque(clientData).takeUnretainedValue()
            parser.handlePackets(
                numberBytes: Int(numberBytes),
                numberPackets: Int(numberPackets),
                inputData: inputData,
                descriptions: descriptions
            )
        }

        private func handlePackets(
            numberBytes: Int,
            numberPackets: Int,
            inputData: UnsafeRawPointer,
            descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
        ) {
            guard numberBytes > 0, numberPackets > 0 else { return }
            let data = Data(bytes: inputData, count: numberBytes)
            let bytesPerPacket = sourceFormat?.streamDescription.pointee.mBytesPerPacket ?? 0
            var relativeOffset = 0
            for index in 0..<numberPackets {
                let description = descriptions.map { $0[index] }
                let packetSize: Int
                let packetOffset: Int
                let variableFrames: Int
                if let description {
                    packetOffset = max(0, Int(description.mStartOffset))
                    packetSize = max(0, Int(description.mDataByteSize))
                    variableFrames = Int(description.mVariableFramesInPacket)
                } else if bytesPerPacket > 0 {
                    packetOffset = index * Int(bytesPerPacket)
                    packetSize = Int(bytesPerPacket)
                    variableFrames = 0
                } else if numberPackets == 1 {
                    packetOffset = 0
                    packetSize = numberBytes
                    variableFrames = 0
                } else {
                    packetOffset = relativeOffset
                    packetSize = max(0, (numberBytes - relativeOffset) / (numberPackets - index))
                    variableFrames = 0
                }
                guard packetOffset >= 0,
                      packetSize > 0,
                      packetOffset + packetSize <= data.count
                else { continue }
                let frameCount = max(
                    1,
                    variableFrames > 0
                        ? variableFrames
                        : Int(sourceFormat?.streamDescription.pointee.mFramesPerPacket ?? 1)
                )
                let startPosition: TimeInterval
                if let sampleRate = sourceFormat?.sampleRate, sampleRate > 0 {
                    startPosition = Double(nextPacketFrame) / sampleRate
                } else {
                    startPosition = 0
                }
                pendingPackets.append(Packet(
                    data: data.subdata(in: packetOffset..<(packetOffset + packetSize)),
                    byteOffset: inputBaseOffset + Int64(packetOffset),
                    packetIndex: nextPacketIndex,
                    frameCount: frameCount,
                    startPosition: startPosition
                ))
                lastPacket = pendingPackets.last
                packetsDecoded += 1
                nextPacketIndex += 1
                nextPacketFrame += Int64(frameCount)
                relativeOffset = packetOffset + packetSize
            }
        }
    }
}
