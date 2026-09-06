import Testing
@testable import MusicHaptics

@Suite("Music Haptics audio-first analysis policy")
struct MusicHapticsAnalysisControlTests {
    @Test("startup grace gives playback exclusive initial resources")
    func startupGrace() {
        #expect(!MusicHapticsAnalysisControl.analysisMayRun(
            playbackPosition: 0,
            analysisPosition: 0,
            sourceDuration: 180,
            playbackRate: 1
        ))
        #expect(!MusicHapticsAnalysisControl.analysisMayRun(
            playbackPosition: 1.49,
            analysisPosition: 0,
            sourceDuration: 180,
            playbackRate: 1
        ))
        #expect(MusicHapticsAnalysisControl.analysisMayRun(
            playbackPosition: 1.5,
            analysisPosition: 1.5,
            sourceDuration: 180,
            playbackRate: 1
        ))
    }

    @Test("analysis cannot outrun the bounded lookahead budget")
    func boundedLead() {
        #expect(MusicHapticsAnalysisControl.analysisMayRun(
            playbackPosition: 10,
            analysisPosition: 18,
            sourceDuration: 180,
            playbackRate: 1
        ))
        #expect(!MusicHapticsAnalysisControl.analysisMayRun(
            playbackPosition: 10,
            analysisPosition: 18.1,
            sourceDuration: 180,
            playbackRate: 1
        ))
        #expect(MusicHapticsAnalysisControl.analysisMayRun(
            playbackPosition: 10,
            analysisPosition: 26,
            sourceDuration: 180,
            playbackRate: 2
        ))
    }
}