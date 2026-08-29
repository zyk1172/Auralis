@testable import AppShell
import Testing

/// Keeps the two product entry points in the real AppShell target.  This is a
/// deliberately small structural guard: it catches accidental removal of the
/// iOS setting or the Now Playing submenu before a device build is installed.
@Suite("Music Haptics iOS UI structure")
struct MusicHapticsUIStructureTests {
    @Test("播放设置页 and Now Playing submenu retain stable iOS identifiers")
    @MainActor
    func hapticsEntryPointsRemainAvailable() {
        #expect(PlaybackSettingsPage.musicHapticsSettingsIdentifier == "auralis.settings.musicHaptics")
        #expect(NowPlayingView.musicHapticsMenuIdentifier == "auralis.nowPlaying.musicHaptics")
    }

    @Test("播放控制统一映射播放、加载与暂停")
    @MainActor
    func playbackControlPresentationMapsAuthoritativeStates() {
        #expect(PlaybackControlPresentation(state: .playing) == .pause)
        #expect(PlaybackControlPresentation(state: .preparing) == .loading)
        #expect(PlaybackControlPresentation(state: .buffering) == .loading)
        #expect(PlaybackControlPresentation(state: .stalled) == .loading)
        #expect(PlaybackControlPresentation(state: .paused) == .play)
        #expect(PlaybackControlPresentation(state: .idle) == .play)
        #expect(PlaybackControlPresentation(state: .failed(.networkUnavailable)) == .play)
    }
}
