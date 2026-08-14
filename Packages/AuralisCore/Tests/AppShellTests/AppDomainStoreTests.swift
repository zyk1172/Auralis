import Application
import Domain
import Foundation
import LocalCatalog
import OfflineManager
@testable import AppShell
import Testing

private struct DomainStoreConnector: ServerConnecting {
    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
        throw URLError(.cannotConnectToHost)
    }

    func connect(
        _ input: ServerConnectionInput,
        progress: @escaping @Sendable (ServerConnectionStage) async -> Void
    ) async throws -> ServerConnectionResult {
        throw URLError(.cannotConnectToHost)
    }

    func restoreLastConnection() async throws -> ServerConnectionResult? { nil }
}

@Suite("App 领域 Store")
struct AppDomainStoreTests {
    @Test("首页布局由 HomeStore 单独持久化")
    @MainActor
    func homeStoreOwnsLayoutPersistence() {
        let suite = "AppDomainStoreTests.home.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = HomeStore(defaults: defaults)
        first.setModuleVisible("random", isVisible: false)
        let second = HomeStore(defaults: defaults)

        #expect(second.layout.preference(moduleID: "random")?.isVisible == false)
    }

    @Test("本地缓存资料库首次生成首页快照时补齐随机音乐")
    @MainActor
    func homeStoreSeedsRandomMusicForCachedCatalog() {
        let suite = "AppDomainStoreTests.cached-random.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let serverID: ServerID = "cached-server"
        var catalog = LibraryCatalog.empty
        catalog.tracks = [
            Track(
                id: "cached-track",
                serverID: serverID,
                albumID: "cached-album",
                artistID: "cached-artist",
                title: "Cached Track",
                artistName: "Artist",
                albumTitle: "Album",
                duration: 180
            ),
        ]
        let store = HomeStore(defaults: defaults)

        store.refresh(catalog: catalog, playCounts: [:], recentIDs: [], addedDates: [:])
        let initialRandom = store.randomTracks
        store.refresh(catalog: catalog, playCounts: [:], recentIDs: [], addedDates: [:])

        #expect(initialRandom.map(\.id) == [TrackID(rawValue: "cached-track")])
        #expect(store.randomTracks == initialRandom)
    }

    @Test("LibraryStore 与 ServerStore 各自拥有领域状态")
    @MainActor
    func storesOwnIndependentState() {
        let library = LibraryStore(catalog: .empty)
        let server = ServerStore()

        library.playlistDeletionError = "playlist-only"
        server.authenticationFailed = true

        #expect(library.playlistDeletionError == "playlist-only")
        #expect(library.catalog.tracks.isEmpty)
        #expect(library.catalog.albums.isEmpty)
        #expect(library.catalog.artists.isEmpty)
        #expect(server.authenticationFailed)
        #expect(server.connectionState == .idle)
    }

    @Test("DownloadStore 从磁盘按 GlobalID 恢复缓存身份")
    @MainActor
    func downloadStoreRestoresGlobalIDs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDomainStoreTests.download.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TrackCacheStore(directory: directory)
        let cacheID = TrackCacheStore.TrackCacheID(serverID: "server-a", trackID: "track-1")
        _ = try await cache.store(data: Data("audio".utf8), for: cacheID, codec: "flac")

        let store = DownloadStore(connector: DomainStoreConnector(), cacheStore: cache)
        await store.restoreCachedIDs()

        #expect(store.downloadedTrackIDs == [
            GlobalID(serverID: "server-a", remoteID: "track-1"),
        ])
    }
}
