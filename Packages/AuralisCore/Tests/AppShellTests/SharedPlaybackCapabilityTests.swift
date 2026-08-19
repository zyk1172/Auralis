@testable import AppShell
import Application
import Domain
import Foundation
import LocalCatalog
import Testing

/// 共享层：canGoNext/canGoPrevious 统一 capability、GlobalID resolver、
/// Siri/快捷指令 disliked Hard Exclusion。
@Suite("Shared playback capability & GlobalID")
struct SharedPlaybackCapabilityTests {
    private final class NoopConnector: ServerConnecting, @unchecked Sendable {
        func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
            throw CancellationError()
        }
    }

    @MainActor
    private func makeModel(serverID: ServerID = "server", tracks: [Track] = []) -> AuralisAppModel {
        AuralisAppModel(
            catalog: LibraryCatalog(
                account: ServerAccount(
                    id: serverID,
                    displayName: "Server",
                    baseURL: URL(string: "https://music.example.test")!,
                    username: "listener",
                    credentialReference: "test"
                ),
                artists: [], albums: [], tracks: tracks,
                genres: [], playlists: [], history: [], downloads: [],
                lyrics: [:], recommendations: []
            ),
            connector: NoopConnector(),
            defaults: UserDefaults(suiteName: "shared-cap-\(UUID().uuidString)")!,
            storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("shared-cap-\(UUID().uuidString).sqlite")
        )
    }

    private func track(_ id: String, serverID: ServerID = "server") -> Track {
        Track(
            id: TrackID(rawValue: id), serverID: serverID,
            albumID: "album", artistID: "artist",
            title: id, artistName: "Artist", albumTitle: "Album", duration: 180
        )
    }

    @Test("shuffle 模式在物理队尾 canGoNext 仍为 true")
    @MainActor
    func shuffleCanGoNext() async {
        let model = makeModel(tracks: [track("t1"), track("t2"), track("t3")])
        model.playQueue([track("t1"), track("t2"), track("t3")])
        model.setShuffle(true)
        model.currentTrack = track("t3") // 物理队尾
        #expect(model.hasNext == false)
        #expect(model.canGoNext == true) // shuffle 仍可随机选下一首
    }

    @Test("repeatAll 模式在物理队尾 canGoNext 为 true")
    @MainActor
    func repeatAllCanGoNext() async {
        let model = makeModel(tracks: [track("t1"), track("t2")])
        model.playQueue([track("t1"), track("t2")])
        model.repeatMode = .all
        model.currentTrack = track("t2")
        #expect(model.hasNext == false)
        #expect(model.canGoNext == true)
    }

    @Test("repeatOff 且非 shuffle 的物理队尾 canGoNext 为 false")
    @MainActor
    func physicalEndWithoutRepeatCannotGoNext() async {
        let model = makeModel(tracks: [track("t1"), track("t2")])
        model.playQueue([track("t1"), track("t2")])
        model.repeatMode = .off
        model.setShuffle(false)
        model.currentTrack = track("t2")
        #expect(model.canGoNext == false)
    }

    @Test("canGoPrevious 只要存在当前曲目即为 true，无曲目为 false")
    @MainActor
    func canGoPreviousSemantics() async {
        // 空目录：未加载曲目（placeholder）→ 不可执行上一首。
        let empty = makeModel(tracks: [])
        #expect(empty.canGoPrevious == false)
        // 加载曲目后：即使物理上没有上一首，previous() 也能回本曲开头 → 可执行。
        let model = makeModel(tracks: [track("t1")])
        model.playQueue([track("t1")])
        #expect(model.hasPrevious == false)
        #expect(model.canGoPrevious == true)
    }

    @Test("addToQueue / playNext 使用 GlobalID 双键匹配，不跨服务器误匹配")
    @MainActor
    func globalIDResolverCrossServer() async {
        // 内存 catalog 只含当前服务器（server）的曲目。
        let model = makeModel(serverID: "server", tracks: [track("t1"), track("t2")])
        let foreign = GlobalID(serverID: "other", remoteID: "t1") // 另一服务器同 remoteID
        let local = GlobalID(serverID: "server", remoteID: "t1")
        #expect(model.track(for: local)?.serverID == "server")
        #expect(model.track(for: foreign) == nil) // 不跨服务器误匹配

        model.addToQueue(globalID: foreign)
        #expect(model.queue.isEmpty) // 外服务器 GlobalID 不入队
        model.addToQueue(globalID: local)
        #expect(model.queue.count == 1)

        model.playQueue([track("t1"), track("t2")])
        model.currentTrack = track("t2")
        model.playNext(globalID: local)
        // playNext 插入新队列项到当前歌曲之后（R05 允许重复歌曲）：[t1, t2, t1]。
        #expect(model.queue.count == 3)
        #expect(model.queue[2].id.rawValue == "t1")
    }

    @Test("Siri 随机播放排除 disliked")
    @MainActor
    func siriRandomExcludesDisliked() async throws {
        let model = makeModel(tracks: [track("t-disliked"), track("t-ok-1"), track("t-ok-2")])
        let disliked = model.catalog.tracks.first { $0.id.rawValue == "t-disliked" }!
        await model.persistDisliked(disliked, value: true, source: "user")
        // “随机”解析为 .playRandom（“随机播放”会被解析为“切换随机”）。
        await model.executeSiriIntent("随机")
        #expect(!model.queue.map(\.id.rawValue).contains("t-disliked"))
        #expect(model.queue.count == 2)
    }

    @Test("Siri 自动选歌兜底排除 disliked")
    @MainActor
    func siriFallbackExcludesDisliked() async throws {
        let model = makeModel(tracks: [track("t-disliked"), track("t-ok")])
        let disliked = model.catalog.tracks.first { $0.id.rawValue == "t-disliked" }!
        await model.persistDisliked(disliked, value: true, source: "user")
        // 无播放历史、无收藏 → playRecent 退到自动选歌兜底。
        await model.executeSiriIntent("播放最近播放")
        #expect(!model.queue.map(\.id.rawValue).contains("t-disliked"))
        #expect(model.queue.map(\.id.rawValue).contains("t-ok"))
    }

    @Test("Mac 当前集合随机只使用传入 tracks，不混入整库其它歌曲")
    @MainActor
    func scopedShuffleUsesOnlySuppliedTracks() async {
        // 整库 4 首，但收藏页只包含 t2/t3：随机播放必须只从这两首中选择。
        let model = makeModel(tracks: [track("t1"), track("t2"), track("t3"), track("t4")])
        model.playShuffledQueue([track("t2"), track("t3")])
        #expect(model.queue.count == 2)
        #expect(Set(model.queue.map(\.id.rawValue)) == ["t2", "t3"])
        #expect(model.currentTrack.id.rawValue != "placeholder")
    }

    @Test("Mac 空集合随机播放不产生队列")
    @MainActor
    func emptyScopedShuffleIsNoop() async {
        let model = makeModel(tracks: [track("t1")])
        model.playShuffledQueue([])
        #expect(model.queue.isEmpty)
    }
}
