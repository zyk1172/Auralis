import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

/// Offline or mirrored-file analysis. It never runs on AVPlayer's render thread.
public struct MusicHapticsAnalyzer: Sendable {
    public init() {}

    public func analyze(url: URL, identity: MusicHapticsIdentity) async throws -> MusicHapticsTimeline {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw MusicHapticsAnalyzerError.invalidDuration }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw MusicHapticsAnalyzerError.noAudioTrack }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MusicHapticsAnalyzerError.cannotDecode }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MusicHapticsAnalyzerError.cannotDecode }

        var events: [MusicHapticsEvent] = []
        var previousRMS: Float = 0
        var lastEventTime: TimeInterval = -.infinity
        var observedDuration: TimeInterval = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let sampleDuration = CMSampleBufferGetDuration(sample).seconds
            guard time.isFinite else { continue }
            observedDuration = max(observedDuration, time + (sampleDuration.isFinite ? sampleDuration : 0))
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length >= 4 else { continue }
            var bytes = Data(count: length)
            let copyStatus = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard copyStatus == kCMBlockBufferNoErr else { continue }
            let metrics = Self.metrics(bytes)
            let onset = max(0, metrics.rms - previousRMS)
            // 90 ms refractory period prevents a waveform peak from becoming a vibration storm.
            if time - lastEventTime >= 0.09, metrics.rms > 0.035, onset > 0.018 {
                let intensity = min(0.88, 0.28 + metrics.rms * 1.4 + onset * 2.2)
                let sharpness = min(0.80, 0.15 + metrics.zeroCrossingRate * 0.9)
                events.append(MusicHapticsEvent(time: time, intensity: intensity, sharpness: sharpness, kind: .transient))
                lastEventTime = time
            }
            previousRMS = previousRMS * 0.7 + metrics.rms * 0.3
        }
        if reader.status == .failed { throw reader.error ?? MusicHapticsAnalyzerError.cannotDecode }
        return MusicHapticsTimeline(identity: identity, duration: duration, analyzedDuration: observedDuration, analysisCoverage: min(1, observedDuration / duration), events: thin(events))
    }

    private static func metrics(_ bytes: Data) -> (rms: Float, zeroCrossingRate: Float) {
        let values = [UInt8](bytes)
        var sum: Double = 0; var crossings = 0; var previous: Int16 = 0
        let count = values.count / 2
        guard count > 0 else { return (0, 0) }
        for index in 0..<count {
            let offset = index * 2
            let sample = Int16(bitPattern: UInt16(values[offset]) | UInt16(values[offset + 1]) << 8)
            let normalized = Double(sample) / Double(Int16.max)
            sum += normalized * normalized
            if index > 0, (sample < 0) != (previous < 0) { crossings += 1 }
            previous = sample
        }
        return (Float(sqrt(sum / Double(count))), Float(crossings) / Float(count))
    }

    private func thin(_ events: [MusicHapticsEvent]) -> [MusicHapticsEvent] {
        var result: [MusicHapticsEvent] = []
        for event in events {
            guard let previous = result.last, event.time - previous.time < 0.16 else { result.append(event); continue }
            if event.intensity > previous.intensity { result[result.count - 1] = event }
        }
        return result
    }
}

public enum MusicHapticsAnalyzerError: LocalizedError, Sendable {
    case invalidDuration, noAudioTrack, cannotDecode
    public var errorDescription: String? {
        switch self { case .invalidDuration: "音频时长无效"; case .noAudioTrack: "音频没有可分析的声道"; case .cannotDecode: "音频无法解码为触觉分析数据" }
    }
}
