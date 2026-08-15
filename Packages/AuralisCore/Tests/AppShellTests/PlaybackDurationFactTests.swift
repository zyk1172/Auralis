@testable import AppShell
import Application
import Domain
import Foundation
import LocalCatalog
import MusicLibrary
import Testing

/// `effectivePlaybackDuration` 唯一时长事实源的纯状态测试（RC 修补）：
/// - 真实时长尚未解析且 position 已超过 metadata 时动态扩容（进度条比例 < 1，不会提前到头）；
/// - position 未超过 metadata 时返回 metadata；
/// - metadata 缺失且未播放时兜底为 0。
/// 纯状态测试：不依赖模拟器、不联网、不启动播放引擎。
@Suite("Playback duration facts")
struct PlaybackDurationFactTests {

    @MainActor
    private func makeModel(trackDuration: TimeInterval) -> AuralisAppModel {
        let track = Track(
            id: TrackID(rawValue: "t1"), serverID: "server",
            albumID: "al1", artistID: "ar1",
            title: "T1", artistName: "Artist", albumTitle: "Album",
            duration: trackDuration
        )
        let model = AuralisAppModel(
            catalog: LibraryCatalog(
                account: ServerAccount(id: "server", displayName: "Server"),
                artists: [], albums: [], tracks: [track],
                genres: [], playlists: [], history: [], downloads: [],
                lyrics: [:], recommendations: []
            ),
            connector: NeverConnector(),
            defaults: UserDefaults(suiteName: "dur-\(UUID().uuidString)")!,
            storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("dur-\(UUID().uuidString).sqlite")
        )
        model.currentTrack = track
        return model
    }

    private struct NeverConnector: ServerConnecting, @unchecked Sendable {
        func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
            throw CancellationError()
        }
    }

    @Test("position 超过 metadata 且真实时长未解析：时长动态扩容，进度条比例 < 1")
    @MainActor
    func expandsWhenPositionExceedsMetadata() {
        let model = makeModel(trackDuration: 240)
        model.playbackPosition = 243
        #expect(model.effectivePlaybackDuration == 244)
        #expect(model.playbackProgress < 1)
    }

    @Test("position 未超过 metadata：返回 metadata")
    @MainActor
    func usesMetadataWhenWithin() {
        let model = makeModel(trackDuration: 240)
        model.playbackPosition = 100
        #expect(model.effectivePlaybackDuration == 240)
        #expect(model.playbackProgress == 100.0 / 240.0)
    }

    @Test("metadata 为 0 且未播放：兜底 0，进度条为 0")
    @MainActor
    func zeroWhenNoMetadataAndNoPosition() {
        let model = makeModel(trackDuration: 0)
        model.playbackPosition = 0
        #expect(model.effectivePlaybackDuration == 0)
        #expect(model.playbackProgress == 0)
    }
}
