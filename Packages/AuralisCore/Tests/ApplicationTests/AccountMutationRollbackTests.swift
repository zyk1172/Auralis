import Application
import Domain
import Foundation
import LocalCatalog
import MusicLibrary
import OpenSubsonicKit
import Persistence
import SecurityKit
import Testing

/// R12 收尾：rollback 前置快照必须严格 throwing——
/// 「读取失败」绝不能被 try? 折叠成「本来就不存在」，
/// 否则补偿会错误地 delete 正确凭据 / purge 服务器数据。

/// 可注入 failpoint 的 Keychain vault：记录 delete/store 次数，可令 retrieve 抛错。
private actor FailingCredentialVault: CredentialVault {
    private let wrapped = InMemoryCredentialVault()
    private let failRetrieve: Bool
    private(set) var deleteCount = 0
    private(set) var storeCount = 0

    init(failRetrieve: Bool = false) {
        self.failRetrieve = failRetrieve
    }

    func store(_ value: String, for id: CredentialID) async throws {
        storeCount += 1
        try await wrapped.store(value, for: id)
    }

    func retrieve(id: CredentialID) async throws -> String {
        if failRetrieve { throw ServerConnectionError.secureStorageUnavailable }
        return try await wrapped.retrieve(id: id)
    }

    func delete(id: CredentialID) async throws {
        deleteCount += 1
        try await wrapped.delete(id: id)
    }

    func storedValue(id: CredentialID) async throws -> String? {
        (try? await wrapped.retrieve(id: id))
    }
}

/// 可注入 failpoint 的 Persistence：转发全部方法，可令 account(id:) 抛错、
/// 或第 N 次 saveAccount 抛错；记录 saveAccount 调用次数。
private actor FailingPersistence: AuralisPersisting {
    private let wrapped = InMemoryPersistence()
    private let failAccountRead: Bool
    private let failSaveAccountOnCall: Int?
    private var saveAccountCalls = 0

    init(failAccountRead: Bool = false, failSaveAccountOnCall: Int? = nil) {
        self.failAccountRead = failAccountRead
        self.failSaveAccountOnCall = failSaveAccountOnCall
    }

    func schemaVersion() async -> Int { await wrapped.schemaVersion() }

    func saveAccount(_ account: ServerAccount) async throws {
        saveAccountCalls += 1
        if let failSaveAccountOnCall, saveAccountCalls == failSaveAccountOnCall {
            throw ServerConnectionError.secureStorageUnavailable
        }
        try await wrapped.saveAccount(account)
    }

    func accounts() async throws -> [ServerAccount] {
        try await wrapped.accounts()
    }

    func account(id: ServerID) async throws -> ServerAccount? {
        if failAccountRead { throw ServerConnectionError.secureStorageUnavailable }
        return try await wrapped.account(id: id)
    }

    func saveSnapshot(_ snapshot: ServerLibrarySnapshot) async throws {
        try await wrapped.saveSnapshot(snapshot)
    }

    func snapshot(serverID: ServerID) async throws -> ServerLibrarySnapshot? {
        try await wrapped.snapshot(serverID: serverID)
    }

    func upsertArtists(_ artists: [Artist], serverID: ServerID) async throws -> PersistenceMutationSummary {
        try await wrapped.upsertArtists(artists, serverID: serverID)
    }

    func upsertAlbums(_ albums: [Album], serverID: ServerID) async throws -> PersistenceMutationSummary {
        try await wrapped.upsertAlbums(albums, serverID: serverID)
    }

    func upsertTracks(_ tracks: [Track], serverID: ServerID) async throws -> PersistenceMutationSummary {
        try await wrapped.upsertTracks(tracks, serverID: serverID)
    }

    func artists(serverID: ServerID, offset: Int, limit: Int) async throws -> [Artist] {
        try await wrapped.artists(serverID: serverID, offset: offset, limit: limit)
    }

    func albums(serverID: ServerID, offset: Int, limit: Int) async throws -> [Album] {
        try await wrapped.albums(serverID: serverID, offset: offset, limit: limit)
    }

    func tracks(serverID: ServerID, offset: Int, limit: Int) async throws -> [Track] {
        try await wrapped.tracks(serverID: serverID, offset: offset, limit: limit)
    }

    func track(id: TrackID, serverID: ServerID) async throws -> Track? {
        try await wrapped.track(id: id, serverID: serverID)
    }

    func searchTracks(serverID: ServerID, query: String, offset: Int, limit: Int) async throws -> [Track] {
        try await wrapped.searchTracks(serverID: serverID, query: query, offset: offset, limit: limit)
    }

    func saveCheckpoint(_ checkpoint: PersistenceSyncCheckpoint) async throws {
        try await wrapped.saveCheckpoint(checkpoint)
    }

    func checkpoint(serverID: ServerID, kind: LibraryRecordKind) async throws -> PersistenceSyncCheckpoint? {
        try await wrapped.checkpoint(serverID: serverID, kind: kind)
    }

    func clearCheckpoints(serverID: ServerID) async throws {
        try await wrapped.clearCheckpoints(serverID: serverID)
    }

    func beginFullSync(serverID: ServerID) async throws -> PersistenceSyncSession {
        try await wrapped.beginFullSync(serverID: serverID)
    }

    func stageArtists(_ artists: [Artist], session: PersistenceSyncSession) async throws {
        try await wrapped.stageArtists(artists, session: session)
    }

    func stageAlbums(_ albums: [Album], session: PersistenceSyncSession) async throws {
        try await wrapped.stageAlbums(albums, session: session)
    }

    func stageTracks(_ tracks: [Track], session: PersistenceSyncSession) async throws {
        try await wrapped.stageTracks(tracks, session: session)
    }

    func commitFullSync(_ session: PersistenceSyncSession) async throws {
        try await wrapped.commitFullSync(session)
    }

    func discardFullSync(_ session: PersistenceSyncSession) async {
        await wrapped.discardFullSync(session)
    }

    func removeServer(_ serverID: ServerID) async throws {
        try await wrapped.removeServer(serverID)
    }

    func integrityReport() async throws -> PersistenceIntegrityReport {
        try await wrapped.integrityReport()
    }

    func saveAccountCallCount() -> Int { saveAccountCalls }
}

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

@Suite("R12 账户变更补偿 failpoint")
struct AccountMutationRollbackTests {
    private func makeConnector(
        persistence: any AuralisPersisting,
        vault: any CredentialVault,
        catalogStore: LocalCatalogStore? = nil
    ) -> ProductionServerConnector {
        let store = catalogStore ?? (try! LocalCatalogStore(url: URL(string: "file::memory:")!))
        return ProductionServerConnector(
            credentialVault: vault,
            persistence: persistence,
            catalogStore: store,
            sourceFactory: { _ in EmptySyncSource() }
        )
    }

    private func makeUpdate(serverID: String = "a") -> ServerConfigurationUpdate {
        ServerConfigurationUpdate(
            displayName: "新名字",
            baseURL: URL(string: "http://127.0.0.1:9")!,
            externalBaseURL: nil,
            username: "new-user",
            password: "new-password"
        )
    }

    /// 场景 1：Keychain retrieve 抛 secure-storage 错误（而非 missing）——
    /// mutation 必须根本不开始：不写新密码、不 delete 旧凭据。
    @Test("凭据读取失败：mutation 不开始，不 delete 旧凭据")
    func credentialReadFailureAbortsMutation() async throws {
        let persistence = InMemoryPersistence()
        let vault = FailingCredentialVault(failRetrieve: true)
        let server = ServerAccount(id: "a", displayName: "A", baseURL: URL(string: "http://127.0.0.1:1")!, username: "u")
        try await persistence.saveAccount(server)
        // 旧凭据真实存在。
        try await vault.store("old-password", for: CredentialID(rawValue: "opensubsonic.a"))

        let connector = makeConnector(persistence: persistence, vault: vault)
        let result = await connector.updateServerConfiguration(serverID: "a", update: makeUpdate())

        #expect(result == nil, "快照读取失败必须中止变更")
        #expect(await vault.deleteCount == 0, "不得把读取失败误判为『无旧凭据』而 delete")
        #expect(await vault.storeCount == 1, "只有 setup 的 1 次写入——mutation 未开始，未写新密码")
        #expect(try await vault.storedValue(id: CredentialID(rawValue: "opensubsonic.a")) == "old-password")
    }

    /// 场景 2：persistence.account 读取失败（restoreAccountFromBackup 入口不先读 account，
    /// 由补偿辅助读取）——mutation 必须抛错且根本不开始（saveAccount 0 次）。
    @Test("账户读取失败：备份恢复中止，不执行任何写入")
    func accountReadFailureAbortsBackupRestore() async throws {
        let persistence = FailingPersistence(failAccountRead: true)
        let vault = FailingCredentialVault()
        let connector = makeConnector(persistence: persistence, vault: vault)

        let account = ServerAccount(
            id: "restored",
            displayName: "恢复的服务器",
            baseURL: URL(string: "http://127.0.0.1:9")!,
            username: "u"
        )
        // 备份恢复必须抛错——不是静默成功，也不是「视为无旧账户」。
        await #expect(throws: ServerConnectionError.self) {
            try await connector.restoreAccountFromBackup(account, secret: "secret")
        }
        #expect(await persistence.saveAccountCallCount() == 0, "mutation 根本没开始")
        #expect(await vault.storeCount == 0)
    }

    /// 场景 3：credential 新写成功、persistence.saveAccount 失败——
    /// 逆序恢复：旧密码必须被写回（新密码不残留），旧账户不丢失。
    @Test("中途失败：新密码已写、账户写入失败 → 旧密码逆序恢复")
    func midMutationFailureRestoresCredentialAndAccount() async throws {
        // 第 1 次 saveAccount 是 setup（成功）；第 2 次是 updateServerConfiguration
        // 的 mutate 内写入（抛错）；第 3 次是补偿恢复（成功）。
        let persistence = FailingPersistence(failSaveAccountOnCall: 2)
        let vault = FailingCredentialVault()
        let server = ServerAccount(id: "a", displayName: "A", baseURL: URL(string: "http://127.0.0.1:1")!, username: "u")
        try await persistence.saveAccount(server)
        try await vault.store("old-password", for: CredentialID(rawValue: "opensubsonic.a"))

        let connector = makeConnector(persistence: persistence, vault: vault)
        let result = await connector.updateServerConfiguration(serverID: "a", update: makeUpdate())

        #expect(result == nil)
        // Keychain：setup 1 次 + 新密码 1 次 + 补偿恢复 1 次 = 3；失败后必须恢复旧密码。
        #expect(await vault.storeCount == 3, "setup + 新密码 + 补偿恢复各 1 次")
        #expect(try await vault.storedValue(id: CredentialID(rawValue: "opensubsonic.a")) == "old-password",
                "补偿必须把旧密码写回，不能残留新密码")
        // Persistence：旧账户保持不变（用户名/URL 未变成新配置）。
        let stored = try await persistence.account(id: "a")
        #expect(stored?.username == "u")
        #expect(stored?.displayName == "A")
    }
}
