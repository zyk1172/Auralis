import Accelerate
import Foundation

/// Converts the two PCM layouts emitted by the tap/reader into the common
/// mono Float32 representation consumed by `MusicHapticsDSPProcessor`.
/// Byte decoding is intentionally kept separate from the DSP hot path.
enum MusicHapticsPCMDecoder {
    static func decodeMono(
        bytes: Data,
        format: MusicHapticsPCMFormat,
        frameCount: Int
    ) -> [Float]? {
        let sampleCount = frameCount.multipliedReportingOverflow(by: format.channels)
        guard !sampleCount.overflow, frameCount > 0, sampleCount.partialValue > 0 else { return nil }
        let expectedBytes: Int
        if format.interleaved {
            let result = frameCount.multipliedReportingOverflow(by: format.bytesPerFrame)
            guard !result.overflow else { return nil }
            expectedBytes = result.partialValue
        } else {
            let result = sampleCount.partialValue.multipliedReportingOverflow(by: format.bytesPerSample)
            guard !result.overflow else { return nil }
            expectedBytes = result.partialValue
        }
        guard bytes.count >= expectedBytes else { return nil }

        var result = [Float](repeating: 0, count: frameCount)
        bytes.withUnsafeBytes { raw in
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<format.channels {
                    let offset: Int
                    if format.interleaved {
                        offset = frame * format.bytesPerFrame + channel * format.bytesPerSample
                    } else {
                        offset = channel * frameCount * format.bytesPerSample + frame * format.bytesPerSample
                    }
                    if let value = decode(raw, offset: offset, format: format) {
                        sum += value
                    }
                }
                result[frame] = sum / Float(format.channels)
            }
        }
        return result
    }

    static func rms(bytes: Data, format: MusicHapticsPCMFormat, frameCount: Int) -> Float? {
        guard let values = decodeMono(bytes: bytes, format: format, frameCount: frameCount), !values.isEmpty else {
            return nil
        }
        return vDSP.rootMeanSquare(values)
    }

    private static func decode(
        _ raw: UnsafeRawBufferPointer,
        offset: Int,
        format: MusicHapticsPCMFormat
    ) -> Float? {
        guard offset >= 0, offset + format.bytesPerSample <= raw.count else { return nil }
        switch format.sampleType {
        case .float32:
            let bits: UInt32
            if format.isBigEndian {
                bits = UInt32(raw[offset]) << 24
                    | UInt32(raw[offset + 1]) << 16
                    | UInt32(raw[offset + 2]) << 8
                    | UInt32(raw[offset + 3])
            } else {
                bits = UInt32(raw[offset])
                    | UInt32(raw[offset + 1]) << 8
                    | UInt32(raw[offset + 2]) << 16
                    | UInt32(raw[offset + 3]) << 24
            }
            let value = Float32(bitPattern: bits)
            guard value.isFinite else { return nil }
            return min(max(value, -1), 1)
        case .int16:
            let bits: UInt16
            if format.isBigEndian {
                bits = UInt16(raw[offset]) << 8 | UInt16(raw[offset + 1])
            } else {
                bits = UInt16(raw[offset]) | UInt16(raw[offset + 1]) << 8
            }
            return Float32(Int16(bitPattern: bits)) / 32_768
        }
    }
}
