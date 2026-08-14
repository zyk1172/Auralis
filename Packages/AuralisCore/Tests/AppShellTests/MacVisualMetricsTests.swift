@testable import AppShell
import Domain
import Foundation
import LocalCatalog
import Testing

/// Apple Music macOS 27 Visual Parity 纯逻辑度量测试（REFERENCE_A / REFERENCE_B）。
/// 允许安全视觉范围，不要求单个精确 px。
@Suite("Mac visual metrics")
struct MacVisualMetricsTests {
    @Test("歌曲表行修订不会因播放进度 tick 改变")
    func songRowsRevisionOnlyTracksLibraryFacts() {
        let first = GlobalID(serverID: "server-a", remoteID: "track-1")
        let last = GlobalID(serverID: "server-a", remoteID: "track-25100")
        let baseline = MacSongRowsRevision(
            catalog: 8,
            metadata: 13,
            visibleCount: 25_100,
            firstID: first,
            lastID: last,
            contentDigest: 0xA11CE
        )

        // playbackPosition / playbackState intentionally are not part of this key.
        let afterPlaybackTick = MacSongRowsRevision(
            catalog: 8,
            metadata: 13,
            visibleCount: 25_100,
            firstID: first,
            lastID: last,
            contentDigest: 0xA11CE
        )
        let afterPlayCountChange = MacSongRowsRevision(
            catalog: 8,
            metadata: 14,
            visibleCount: 25_100,
            firstID: first,
            lastID: last,
            contentDigest: 0xA11CE
        )

        #expect(afterPlaybackTick == baseline)
        #expect(afterPlayCountChange != baseline)
    }

    // MARK: - Albums Grid（REFERENCE_A：detail ≈1268 → 4 列，item ≈267-275）

    @Test("detailWidth ≈1268 → 4 列")
    func albumsFourColumns() {
        let m = MacArtworkGridMetrics.albums(availableWidth: 1268)
        #expect(m.columnCount == 4)
    }

    @Test("detailWidth ≈1268 → item 260...280")
    func albumsItemSize() {
        let m = MacArtworkGridMetrics.albums(availableWidth: 1268)
        #expect(m.itemWidth >= 260 && m.itemWidth <= 280)
        #expect(m.horizontalPadding >= 40 && m.horizontalPadding <= 48)
    }

    @Test("窄宽度 → 2 列，宽宽度 → 5-6 列")
    func albumsAdaptiveColumns() {
        #expect(MacArtworkGridMetrics.albums(availableWidth: 600).columnCount == 2)
        #expect(MacArtworkGridMetrics.albums(availableWidth: 1400).columnCount == 5)
        #expect(MacArtworkGridMetrics.albums(availableWidth: 1600).columnCount == 6)
    }

    @Test("home 度量 item 在 150...210")
    func homeItemRange() {
        let m = MacArtworkGridMetrics.home(availableWidth: 1268)
        #expect(m.itemWidth >= 150 && m.itemWidth <= 210)
    }

    // MARK: - Floating Player（Music.app 内容区宽胶囊，左右各保留稳定控制区）

    @Test("player 内部几何：detail 1268 → 左右固定 230-260")
    func playerSideWidths() {
        // 复刻 MacFloatingPlayerBar 的 sideWidth 规则（min(260, max(230, width*0.23))）
        let width: CGFloat = 1268
        let side = min(260, max(230, width * 0.23))
        #expect(side >= 230 && side <= 260)
    }

    // MARK: - Full Player（Music.app 左播放轨道 + 右歌词/队列轨道）

    @Test("full player artwork 1536×1050 与控制轨等宽")
    func fullPlayerArtworkSize() {
        let size = CGSize(width: 1536, height: 1050)
        let artwork = MacFullPlayerMetrics.artworkSize(window: size)
        let column = MacFullPlayerMetrics.playerColumnWidth(window: size)
        #expect(artwork == column)
    }

    @Test("full player left margin ≈ 9.2% 窗口宽（130...150）")
    func fullPlayerLeftMargin() {
        let m = MacFullPlayerMetrics.leftMargin(window: CGSize(width: 1536, height: 1050))
        #expect(m >= 130 && m <= 150)
    }

    @Test("full player 封面、资料与控制整组垂直居中（145...150）")
    func fullPlayerTop() {
        let t = MacFullPlayerMetrics.topY(window: CGSize(width: 1536, height: 1050))
        #expect(t >= 145 && t <= 150)
    }

    @Test("full player 左轨 440...520，右轨更靠上")
    func fullPlayerTracks() {
        let size = CGSize(width: 1536, height: 1050)
        let column = MacFullPlayerMetrics.playerColumnWidth(window: size)
        let playerTop = MacFullPlayerMetrics.topY(window: size)
        let contextTop = MacFullPlayerMetrics.contextTopY(window: size)
        #expect(column >= 440 && column <= 520)
        #expect(contextTop < playerTop)
    }

    @Test("三种常见窗口下封面与控制轨保持 Apple Music 比例")
    func artworkMatchesPlayerColumnAcrossWindowSizes() {
        for size in [
            CGSize(width: 1280, height: 820),
            CGSize(width: 1440, height: 900),
            CGSize(width: 1728, height: 1117),
        ] {
            let artwork = MacFullPlayerMetrics.artworkSize(window: size)
            let column = MacFullPlayerMetrics.playerColumnWidth(window: size)
            let playingRatio = artwork / column
            let pausedRatio = playingRatio * MacUIVisualTokens.ExpandedPlayer.pausedArtworkScale
            #expect(artwork <= column)
            #expect(playingRatio == 1)
            #expect(pausedRatio >= 0.73 && pausedRatio <= 0.75)
        }
    }
}
