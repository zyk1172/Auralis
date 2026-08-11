import Application
import Domain
import Foundation
import LocalCatalog
import MusicLibrary
import OpenSubsonicKit
import Persistence
import SecurityKit
import Testing

/// 空资料库同步源：restore 路径不触发网络分页。
private struct EmptySyncSource: LibrarySyncSource {
    func artistsPage(serverID: ServerID, request: LibraryPageRequest) async throws -> LibraryPage<Artist> {
        LibraryPage(items: [])
    }
    func albumsPage(serverID: ServerID, request: LibraryPageRequest) async throws -> LibraryPage<Album> {
        LibraryPage(items: [])
    }
    func tracksPage(serverID: ServerID, request: LibraryPageRequest) async throws -> LibraryPage<Track> {
        LibraryPage(items: [])
    }
}

@Suite("服务器恢复与切换")
struct RestoreConnectionTests {
    private func makeTrack(serverID: ServerID, title: String) -> Track {
        Track(
            id: TrackID(rawValue: "t-\(title)"), serverID: serverID,
            albumID: "a", artistID: "r",
            title: title, artistName: "Artist", albumTitle: "Album", duration: 120
        )
    }

    private func makeConnector(
        persistence: any AuralisPersisting,
        vault: any CredentialVault = InMemoryCredentialVault(),
        catalogStore: LocalCatalogStore? = nil
    ) -> ProductionServerConnector {
        ProductionServerConnector(
            credentialVault: vault,
            persistence: persistence,
            catalogStore: catalogStore,
            sourceFactory: { _ in EmptySyncSource() }
        )
    }

    private func seed(persistence: any AuralisPersisting, vault: InMemoryCredentialVault) async throws {
        let serverA = ServerAccount(id: "a", displayName: "A 服务器", baseURL: URL(string: "http://127.0.0.1:1")!, username: "u")
        let serverB = ServerAccount(id: "b", displayName: "B 服务器", baseURL: URL(string: "http://127.0.0.1:2")!, username: "u")
        try await persistence.saveAccount(serverA)
        try await persistence.saveAccount(serverB)
        try await vault.store("pw", for: CredentialID(rawValue: "opensubsonic.a"))
        try await vault.store("pw", for: CredentialID(rawValue: "opensubsonic.b"))
        try await persistence.saveSnapshot(ServerLibrarySnapshot(
            serverID: "a",
            account: serverA,
            tracks: [makeTrack(serverID: "a", title: "A 歌曲")]
        ))
        try await persistence.saveSnapshot(ServerLibrarySnapshot(
            serverID: "b",
            account: serverB,
            tracks: [makeTrack(serverID: "b", title: "B 歌曲")]
        ))
    }

    @Test("restoreConnection 恢复指定服务器的资料库，而不是第一台")
    func restoresRequestedServer() async throws {
        let persistence = InMemoryPersistence()
        let vault = InMemoryCredentialVault()
        try await seed(persistence: persistence, vault: vault)

        let result = try await makeConnector(persistence: persistence, vault: vault)
            .restoreConnection(serverID: ServerID(rawValue: "b"))
        #expect(result != nil)
        #expect(result?.account.id == ServerID(rawValue: "b"))
        #expect(result?.tracks.first?.title == "B 歌曲")
    }

    @Test("旧 JSON 音乐快照一次性迁入 SQLite，JSON 只保留账号")
    func migratesLegacySnapshotToCanonicalSQLite() async throws {
        let persistence = InMemoryPersistence()
        let vault = InMemoryCredentialVault()
        try await seed(persistence: persistence, vault: vault)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("auralis-legacy-migration-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let catalogStore = try LocalCatalogStore(url: directory.appendingPathComponent("catalog.sqlite"))
        let connector = makeConnector(persistence: persistence, vault: vault, catalogStore: catalogStore)

        let result = try await connector.restoreConnection(serverID: "b")
        #expect(result?.tracks.first?.title == "B 歌曲")
        #expect(try await catalogStore.trackCount(serverID: "b") == 1)

        let compacted = try await persistence.snapshot(serverID: "b")
        #expect(compacted?.account?.id == ServerID(rawValue: "b"))
        #expect(compacted?.tracks.isEmpty == true)
        #expect(compacted?.albums.isEmpty == true)
        #expect(compacted?.artists.isEmpty == true)

        // A new connector can restore solely from SQLite plus the preserved account.
        let reopenedStore = try LocalCatalogStore(url: directory.appendingPathComponent("catalog.sqlite"))
        let reopened = makeConnector(persistence: persistence, vault: vault, catalogStore: reopenedStore)
        let restoredAgain = try await reopened.restoreConnection(serverID: "b")
        #expect(restoredAgain?.tracks.first?.title == "B 歌曲")
    }

    @Test("restoreLastConnection 回退到首个已保存账户")
    func restoreLastConnectionFallsBackToFirst() async throws {
        let persistence = InMemoryPersistence()
        let vault = InMemoryCredentialVault()
        try await seed(persistence: persistence, vault: vault)

        let result = try await makeConnector(persistence: persistence, vault: vault)
            .restoreLastConnection()
        #expect(result?.account.id == ServerID(rawValue: "a"))
    }

    /// 备份恢复后服务器只有账号没有本地快照（未同步过）：
    /// restoreConnection 必须返回空库结果而不是 nil，否则设置页切换服务器会错误地弹「重新添加服务器」。
    @Test("restoreConnection 返回已配置但未同步的服务器（空库）而不是 nil")
    func restoreConnectionReturnsUnsyncedAccount() async throws {
        let persistence = InMemoryPersistence()
        let vault = InMemoryCredentialVault()
        // 只保存账号与凭据，不保存任何快照 —— 模拟「从备份恢复」的服务器。
        let server = ServerAccount(id: "restored", displayName: "恢复的服务器", baseURL: URL(string: "http://127.0.0.1:9")!, username: "u")
        try await persistence.saveAccount(server)
        try await vault.store("pw", for: CredentialID(rawValue: "opensubsonic.restored"))

        let result = try await makeConnector(persistence: persistence, vault: vault)
            .restoreConnection(serverID: ServerID(rawValue: "restored"))

        #expect(result != nil)
        #expect(result?.account.id == ServerID(rawValue: "restored"))
        #expect(result?.account.displayName == "恢复的服务器")
        #expect(result?.tracks.isEmpty == true)
        #expect(result?.artists.isEmpty == true)
        #expect(result?.albums.isEmpty == true)
    }

    /// 完全没有账号时才返回 nil（触发「重新添加服务器」是合理的）。
    @Test("restoreConnection 无账号时返回 nil")
    func restoreConnectionReturnsNilWithoutAccount() async throws {
        let persistence = InMemoryPersistence()
        let vault = InMemoryCredentialVault()
        let result = try await makeConnector(persistence: persistence, vault: vault)
            .restoreConnection(serverID: ServerID(rawValue: "ghost"))
        #expect(result == nil)
    }
}
