@testable import AppShell
import Testing

/// Keeps the two product entry points in the real AppShell target.  This is a
/// deliberately small structural guard: it catches accidental removal of the
/// iOS setting or the Now Playing submenu before a device build is installed.
@Suite("Music Haptics iOS UI structure")
struct MusicHapticsUIStructureTests {
    @Test("播放设置页 and Now Playing submenu retain their product labels")
    @MainActor
    func hapticsEntryPointsRemainAvailable() {
        #expect(PlaybackSettingsPage.musicHapticsSectionTitle == "音乐震动反馈")
        #expect(NowPlayingView.musicHapticsMenuTitle == "音乐震动")
    }
}
