import AudioToolbox
import CoreAudio
import Foundation
import MusicHaptics

/// Bridges AVFoundation's audio-tap representations into the PCM contract used
/// by MusicHaptics.  The payload copy is intentionally synchronous and bounded
/// to the buffers supplied for this callback; analysis remains off the tap
/// thread.
enum MusicHapticsPCMBridge {
    static func makeFormat(from description: AudioStreamBasicDescription) -> MusicHapticsPCMFormat? {
        guard description.mFormatID == kAudioFormatLinearPCM else { return nil }
        let channels = Int(description.mChannelsPerFrame)
        let sampleRate = description.mSampleRate
        let bitsPerChannel = Int(description.mBitsPerChannel)
        guard channels > 0, sampleRate.isFinite, sampleRate > 0 else { return nil }

        let flags = description.mFormatFlags
        let sampleType: MusicHapticsPCMSampleType
        let bytesPerSample: Int
        if flags & kAudioFormatFlagIsFloat != 0, bitsPerChannel == 32 {
            sampleType = .float32
            bytesPerSample = MemoryLayout<Float32>.size
        } else if flags & kAudioFormatFlagIsSignedInteger != 0, bitsPerChannel == 16 {
            sampleType = .int16
            bytesPerSample = MemoryLayout<Int16>.size
        } else {
            return nil
        }

        let nonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let rawBytesPerFrame = Int(description.mBytesPerFrame)
        guard rawBytesPerFrame > 0 else { return nil }
        let sourceBytesPerSample: Int
        if nonInterleaved {
            sourceBytesPerSample = rawBytesPerFrame
        } else {
            guard rawBytesPerFrame % channels == 0 else { return nil }
            sourceBytesPerSample = rawBytesPerFrame / channels
        }
        guard sourceBytesPerSample == bytesPerSample else { return nil }

        return MusicHapticsPCMFormat(
            sampleRate: sampleRate,
            channels: channels,
            sampleType: sampleType,
            interleaved: !nonInterleaved,
            bytesPerFrame: bytesPerSample * channels,
            bytesPerSample: bytesPerSample,
            isBigEndian: flags & kAudioFormatFlagIsBigEndian != 0
        )
    }

    /// Copies the source buffers into the canonical payload layout expected by
    /// `MusicHapticsPCMFormat`: one interleaved buffer, or one complete plane
    /// per channel for non-interleaved PCM.
    static func copyPayload(
        from bufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: Int,
        format: MusicHapticsPCMFormat
    ) -> Data? {
        guard let expectedBytes = canonicalByteCount(frameCount: frameCount, format: format) else { return nil }
        var payload = Data(repeating: 0, count: expectedBytes)
        let copied = payload.withUnsafeMutableBytes { destination in
            copyPayload(
                into: destination,
                from: bufferList,
                frameCount: frameCount,
                format: format
            )
        }
        guard copied == expectedBytes else { return nil }
        return payload
    }

    /// Copies directly into caller-owned storage. This is the render-callback
    /// path: it performs validation and memcpy only, with no Data allocation or
    /// synchronization.
    @discardableResult
    static func copyPayload(
        into destination: UnsafeMutableRawBufferPointer,
        from bufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: Int,
        format: MusicHapticsPCMFormat
    ) -> Int? {
        guard let expectedBytes = canonicalByteCount(frameCount: frameCount, format: format),
              destination.count >= expectedBytes,
              destination.baseAddress != nil
        else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let expectedBufferCount = format.interleaved ? 1 : format.channels
        guard buffers.count == expectedBufferCount else { return nil }

        var totalBytes = 0
        for buffer in buffers {
            guard buffer.mData != nil, buffer.mDataByteSize > 0 else { return nil }
            let byteCount = Int(buffer.mDataByteSize)
            let result = totalBytes.addingReportingOverflow(byteCount)
            guard !result.overflow else { return nil }
            totalBytes = result.partialValue
        }
        guard totalBytes == expectedBytes else { return nil }

        var destinationOffset = 0
        for buffer in buffers {
            let byteCount = Int(buffer.mDataByteSize)
            guard let source = buffer.mData, let destinationBase = destination.baseAddress else { return nil }
            destinationBase.advanced(by: destinationOffset).copyMemory(
                from: source,
                byteCount: byteCount
            )
            destinationOffset += byteCount
        }
        return destinationOffset
    }

    private static func canonicalByteCount(
        frameCount: Int,
        format: MusicHapticsPCMFormat
    ) -> Int? {
        guard frameCount > 0, format.isValid else { return nil }
        if format.interleaved {
            let result = frameCount.multipliedReportingOverflow(by: format.bytesPerFrame)
            return result.overflow ? nil : result.partialValue
        }
        let sampleCount = frameCount.multipliedReportingOverflow(by: format.channels)
        guard !sampleCount.overflow else { return nil }
        let result = sampleCount.partialValue.multipliedReportingOverflow(by: format.bytesPerSample)
        return result.overflow ? nil : result.partialValue
    }
}
