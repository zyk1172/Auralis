// SPDX-License-Identifier: GPL-3.0-only
import AudioToolbox
import CoreAudio
import Foundation
import Testing
@testable import PlaybackEngine

@Suite("MusicHaptics PCM bridge")
struct MusicHapticsPCMBridgeTests {
    @Test("Float32 stereo non-interleaved ASBD maps to planar format")
    func float32StereoNonInterleavedFormat() {
        let format = MusicHapticsPCMBridge.makeFormat(from: AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        ))

        #expect(format?.sampleType == .float32)
        #expect(format?.channels == 2)
        #expect(format?.interleaved == false)
        #expect(format?.bytesPerSample == 4)
        #expect(format?.bytesPerFrame == 8)
    }

    @Test("Float32 stereo interleaved ASBD maps to interleaved format")
    func float32StereoInterleavedFormat() {
        let format = MusicHapticsPCMBridge.makeFormat(from: AudioStreamBasicDescription(
            mSampleRate: 44_100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        ))

        #expect(format?.sampleType == .float32)
        #expect(format?.channels == 2)
        #expect(format?.interleaved == true)
        #expect(format?.bytesPerSample == 4)
        #expect(format?.bytesPerFrame == 8)
    }

    @Test("Int16 stereo interleaved ASBD maps to interleaved format")
    func int16StereoInterleavedFormat() {
        let format = MusicHapticsPCMBridge.makeFormat(from: AudioStreamBasicDescription(
            mSampleRate: 44_100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        ))

        #expect(format?.sampleType == .int16)
        #expect(format?.channels == 2)
        #expect(format?.interleaved == true)
        #expect(format?.bytesPerSample == 2)
        #expect(format?.bytesPerFrame == 4)
    }

    @Test("Int24 stereo interleaved ASBD maps without a fixed 16-bit assumption")
    func int24StereoInterleavedFormat() {
        let format = MusicHapticsPCMBridge.makeFormat(from: AudioStreamBasicDescription(
            mSampleRate: 96_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 6,
            mFramesPerPacket: 1,
            mBytesPerFrame: 6,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 24,
            mReserved: 0
        ))

        #expect(format?.sampleType == .int24)
        #expect(format?.channels == 2)
        #expect(format?.interleaved == true)
        #expect(format?.bytesPerSample == 3)
        #expect(format?.bytesPerFrame == 6)
    }

    @Test("two-buffer planar AudioBufferList is copied as channel planes")
    func copiesPlanarAudioBufferList() {
        let format = MusicHapticsPCMBridge.makeFormat(from: AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        ))!
        let left = [Float32(0.1), 0.2, 0.3]
        let right = [Float32(-0.1), -0.2, -0.3]
        let bufferList = AudioBufferList.allocate(maximumBuffers: 2)
        defer { bufferList.unsafeMutablePointer.deallocate() }

        let payload: Data? = left.withUnsafeBytes { leftBytes in
            right.withUnsafeBytes { rightBytes in
                bufferList[0] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(leftBytes.count),
                    mData: UnsafeMutableRawPointer(mutating: leftBytes.baseAddress)
                )
                bufferList[1] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(rightBytes.count),
                    mData: UnsafeMutableRawPointer(mutating: rightBytes.baseAddress)
                )
                return MusicHapticsPCMBridge.copyPayload(
                    from: bufferList.unsafeMutablePointer,
                    frameCount: left.count,
                    format: format
                )
            }
        }

        let expected = data(left) + data(right)
        #expect(payload == expected)
    }

    private func data<T>(_ values: [T]) -> Data {
        values.withUnsafeBytes { bytes in
            Data(bytes: bytes.baseAddress!, count: bytes.count)
        }
    }
}
