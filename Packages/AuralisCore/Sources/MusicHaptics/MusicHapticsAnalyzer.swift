import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

/// Offline/local-file analysis.  It shares the v2 processor with remote
/// lookahead and realtime tap fallback and never runs on the render thread.
public struct MusicHapticsAnalyzer: Sendable {
    public init() {}

    public func analyze(url: URL, identity: MusicHapticsIdentity) async throws -> MusicHapticsTimeline {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw MusicHapticsAnalyzerError.invalidDuration }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw MusicHapticsAnalyzerError.noAudioTrack }
        let sampleRate = 22_050.0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MusicHapticsAnalyzerError.cannotDecode }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MusicHapticsAnalyzerError.cannotDecode }

        var processor = MusicHapticsDSPProcessor()
        var events: [MusicHapticsEvent] = []
        var observedDuration: TimeInterval = 0
        let format = MusicHapticsPCMFormat(
            sampleRate: sampleRate,
            channels: 1,
            sampleType: .int16,
            interleaved: true,
            bytesPerFrame: 2,
            bytesPerSample: 2
        )!

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time.isFinite,
                  let block = CMSampleBufferGetDataBuffer(sample)
            else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let frameCount = CMSampleBufferGetNumSamples(sample)
            guard length >= 2, frameCount > 0 else { continue }
            var bytes = Data(count: length)
            let copyStatus = bytes.withUnsafeMutableBytes { destination in
                CMBlockBufferCopyDataBytes(
                    block,
                    atOffset: 0,
                    dataLength: length,
                    destination: destination.baseAddress!
                )
            }
            guard copyStatus == kCMBlockBufferNoErr,
                  let mono = MusicHapticsPCMDecoder.decodeMono(
                      bytes: bytes,
                      format: format,
                      frameCount: frameCount
                  )
            else { continue }
            let sampleDuration = CMSampleBufferGetDuration(sample).seconds
            observedDuration = max(
                observedDuration,
                time + (sampleDuration.isFinite && sampleDuration > 0
                    ? sampleDuration
                    : Double(frameCount) / sampleRate)
            )
            events.append(contentsOf: processor.process(
                monoSamples: mono,
                startTime: time,
                sampleRate: sampleRate
            ))
        }
        events.append(contentsOf: processor.finish())
        if reader.status == .failed { throw reader.error ?? MusicHapticsAnalyzerError.cannotDecode }
        let diagnostics = processor.diagnostics
        let merged = MusicHapticsEventDeduplicator.merge(events)
        return MusicHapticsTimeline(
            identity: identity,
            duration: duration,
            analyzedDuration: min(duration, observedDuration),
            analysisCoverage: min(1, observedDuration / duration),
            events: merged,
            tempoBPM: diagnostics.tempoBPM,
            beatConfidence: diagnostics.beatConfidence,
            beatPhase: diagnostics.beatPhase
        )
    }
}
public enum MusicHapticsAnalyzerError: LocalizedError, Sendable {
    case invalidDuration
    case noAudioTrack
    case cannotDecode

    public var errorDescription: String? {
        switch self {
        case .invalidDuration: "音频时长无效"
        case .noAudioTrack: "音频没有可分析的声道"
        case .cannotDecode: "音频无法解码为触觉分析数据"
        }
    }
}
