import Domain
import LocalCatalog
import Testing
@testable import AppShell

struct ApplePlatformArchitectureTests {
    @Test func browseDestinationsHaveStableDistinctNavigationIdentity() {
        let album = Album(
            id: "album-1",
            serverID: "server-1",
            artistID: "artist-1",
            title: "Album",
            artistName: "Artist",
            year: 2026,
            genre: nil,
            artworkKey: nil,
            songCount: 1
        )
        let artist = Artist(
            id: "artist-1",
            serverID: "server-1",
            name: "Artist",
            albumCount: 1,
            artworkKey: nil
        )

        let destinations: Set<BrowseDestination> = [
            .album(album),
            .artist(artist),
            .favorites,
            .downloads,
        ]

        #expect(destinations.count == 4)
        #expect(BrowseDestination.album(album).id == "album.album-1")
        #expect(BrowseDestination.artist(artist).id == "artist.artist-1")
    }

    @Test func compactDockContainsOnlyTheThreePrimarySections() {
        #expect(AppSection.compactDockSections == [.home, .library, .assistant])
        #expect(!AppSection.compactDockSections.contains(.search))
        #expect(!AppSection.compactDockSections.contains(.settings))
    }

    @Test func dockRequiresAtLeastAStandardTouchTargetSwipe() {
        #expect(BottomDockProgressReducer.minimumVerticalSwipeDistance >= 44)
        #expect(BottomDockProgressReducer.terminalProgress(for: .init(width: 1, height: -43)) == nil)
        #expect(BottomDockProgressReducer.terminalProgress(for: .init(width: 1, height: -44)) == 1)
    }

    /// 产品契约（RC 收敛）：iPhone 与 iPad 共用同一 iOS navigation / dock 架构；
    /// macOS 是独立 MacMusicShell。这里只断言可提取的纯状态/布局策略，
    /// 不测试私有 View 类型名称。
    @Test func iphoneAndIPadShareSingleIOSDockArchitecture() {
        // iPhone 与 iPad 的根 Shell 只有这一套 Dock 入口集合，不因 size class 切换。
        #expect(AppSection.compactDockSections == [.home, .library, .assistant])
        // 宽屏（iPad regular）浮动控件统一封顶，不横贯整屏；触控目标 ≥ 44pt。
        #expect(IOSLayoutMetrics.floatingChromeWidth(containerWidth: 1194) == 760)
        #expect(IOSLayoutMetrics.floatingChromeWidth(containerWidth: 390) == 390)
        #expect(IOSLayoutMetrics.minimumTouchTargetHeight >= 44)
    }
}
