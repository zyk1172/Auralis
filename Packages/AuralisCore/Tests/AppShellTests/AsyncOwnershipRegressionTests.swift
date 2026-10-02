// SPDX-License-Identifier: GPL-3.0-only
@testable import AppShell
import Application
import Domain
import Foundation
import SecurityKit
import Testing

private actor AuditLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor AuditConnector: ServerConnecting {
    let entered = AuditLatch()
    let release = AuditLatch()
    let destination: ServerConnectionResult
    var fetched: [Track]
    var fails = false
    private(set) var replacements: [[TrackID]] = []

    init(destination: ServerConnectionResult, fetched: [Track] = []) {
        self.destination = destination
        self.fetched = fetched
    }
    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult { destination }
    func replacePlaylistTracks(serverID: ServerID, playlistID: PlaylistID, trackIDs: [TrackID]) async -> Bool {
        replacements.append(trackIDs)
        await entered.open()
        await release.wait()
        return true
    }
    func deletePlaylist(serverID: ServerID, playlistID: PlaylistID) async -> Bool {
        await entered.open()
        await release.wait()
        return true
    }
    func fetchPlaylistTracks(serverID: ServerID, playlistID: PlaylistID) async throws -> [Track] {
        await entered.open()
        await release.wait()
        if fails { throw URLError(.notConnectedToInternet) }
        return fetched
    }
    func refreshStreamURL(serverID: ServerID, trackID: TrackID) async -> URL? {
        await entered.open()
        await release.wait()
        return URL(string: "https://music.example.test/refreshed.flac")!
    }
    func failReads(_ value: Bool) { fails = value }
    func orders() -> [[TrackID]] { replacements }
}

private actor AuditEngine: PlaybackControlling {
    private var value: PlaybackState = .idle
    private var played: [TrackID] = []
    private var failure: (@Sendable () -> Void)?
    let handlerReady = AuditLatch()
    func state() -> PlaybackState { value }
    func play(track: Track) { played.append(track.id); value = .playing }
    func pause() { value = .paused }
    func resume() { value = .playing }
    func stop() { value = .idle }
    func setPlaybackFailureHandler(_ handler: (@Sendable () -> Void)?) async {
        failure = handler
        await handlerReady.open()
    }
    func fail() { failure?() }
    func playedIDs() -> [TrackID] { played }
}

private actor AuditFailingVault: CredentialVault {
    private var values: [CredentialID: String] = [:]
    private var nextFailure: CredentialID?
    func store(_ value: String, for id: CredentialID) throws {
        if nextFailure == id { nextFailure = nil; throw CredentialVaultError.unavailable }
        values[id] = value
    }
    func retrieve(id: CredentialID) throws -> String {
        guard let value = values[id] else { throw CredentialVaultError.missing }
        return value
    }
    func delete(id: CredentialID) { values[id] = nil }
    func failNextWrite(_ id: CredentialID) { nextFailure = id }
}

@Suite("Async state ownership", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct AsyncOwnershipRegressionTests {
    private func track(_ id: String, server: ServerID = "a") -> Track {
        Track(id: TrackID(rawValue: id), serverID: server, albumID: "album", artistID: "artist",
              title: id, artistName: "Artist", albumTitle: "Album", duration: 180,
              streamURL: URL(string: "https://music.example.test/\(id).flac")!)
    }
    private func result(_ server: ServerID, playlists: [Playlist] = []) -> ServerConnectionResult {
        ServerConnectionResult(
            account: ServerAccount(id: server, displayName: server.rawValue,
                                   baseURL: URL(string: "https://music.example.test")!,
                                   username: "listener", credentialReference: "test"),
            capabilities: .init(), artists: [], albums: [], tracks: [track("1", server: server)],
            playlists: playlists
        )
    }
    private func model(_ connector: AuditConnector, playlists: [Playlist], engine: AuditEngine = AuditEngine()) -> AuralisAppModel {
        let initial = result("a", playlists: playlists)
        return AuralisAppModel(
            catalog: LibraryCatalog(account: initial.account, artists: [], albums: [],
                                    tracks: [track("1"), track("2"), track("3")], genres: [],
                                    playlists: playlists, history: [], downloads: [], lyrics: [:], recommendations: []),
            engine: engine, connector: connector,
            defaults: UserDefaults(suiteName: "audit-\(UUID().uuidString)")!,
            storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).sqlite")
        )
    }
    private func switchServer(_ model: AuralisAppModel) async {
        await model.connect(to: .init(displayName: "B", baseURL: URL(string: "https://music.example.test")!,
                                     username: "listener", password: "test-only-value"))
    }
    private func settle() async { for _ in 0..<200 { await Task.yield() } }

    @Test("A pending reorder cannot index into the replacement server's catalog")
    func reorderAcrossSwitch() async {
        let playlist = Playlist(id: "same", serverID: "a", name: "A", trackIDs: ["1", "2"])
        let connector = AuditConnector(destination: result("b"))
        let model = model(connector, playlists: [playlist])
        let pending = Task { await model.reorderPlaylist(id: playlist.id, from: 0, to: 1) }
        await connector.entered.wait()
        await switchServer(model)
        await connector.release.open()
        #expect(await pending.value)
        #expect(model.catalog.activeServerID == "b")
        #expect(model.catalog.playlists.isEmpty)
    }

    @Test("Successive reorders use the previous committed order")
    func serializedReorders() async {
        let playlist = Playlist(id: "same", serverID: "a", name: "A", trackIDs: ["1", "2", "3"])
        let connector = AuditConnector(destination: result("b"))
        let model = model(connector, playlists: [playlist])
        let first = Task { await model.reorderPlaylist(id: playlist.id, from: 0, to: 2) }
        await connector.entered.wait()
        let second = Task { await model.reorderPlaylist(id: playlist.id, from: 0, to: 1) }
        await connector.release.open()
        #expect(await first.value)
        #expect(await second.value)
        #expect(await connector.orders() == [["2", "3", "1"], ["3", "2", "1"]])
        #expect(model.catalog.playlists.first?.trackIDs == ["3", "2", "1"])
    }

    @Test("Late deletion from A cannot remove B's playlist with the same remote ID")
    func deleteAcrossSwitch() async {
        let a = Playlist(id: "same", serverID: "a", name: "A", trackIDs: ["1"])
        let b = Playlist(id: "same", serverID: "b", name: "B", trackIDs: ["1"])
        let connector = AuditConnector(destination: result("b", playlists: [b]))
        let model = model(connector, playlists: [a])
        let pending = Task { await model.deletePlaylist(globalID: GlobalID(serverID: "a", remoteID: "same")) }
        await connector.entered.wait()
        await switchServer(model)
        await connector.release.open()
        #expect(await pending.value)
        #expect(model.catalog.playlists.first?.serverID == "b")
        #expect(model.catalog.playlists.first?.name == "B")
    }

    @Test("Late detail fetch cannot populate B's scoped cache")
    func fetchAcrossSwitch() async {
        let a = Playlist(id: "same", serverID: "a", name: "A", trackIDs: ["1"])
        let b = Playlist(id: "same", serverID: "b", name: "B", trackIDs: ["1"])
        let connector = AuditConnector(destination: result("b", playlists: [b]), fetched: [track("2")])
        let model = model(connector, playlists: [a])
        let pending = Task { await model.fetchAndCachePlaylist(a) }
        await connector.entered.wait()
        await switchServer(model)
        await connector.release.open()
        await pending.value
        #expect(model.catalog.playlists.first?.trackIDs == ["1"])
        #expect(model.playlistTracks[GlobalID(serverID: "b", remoteID: "same")] == nil)
    }

    @Test("Failed fetch preserves contents; a successful empty response clears them")
    func failureAndEmptyAreDistinct() async throws {
        let a = Playlist(id: "same", serverID: "a", name: "A", trackIDs: ["1"])
        let connector = AuditConnector(destination: result("b"))
        let model = model(connector, playlists: [a])
        let gid = GlobalID(serverID: "a", remoteID: "same")
        try await model.catalogCoordinator.store.upsertPlaylist(a, serverID: "a")
        await connector.release.open()
        await connector.failReads(true)
        await model.fetchAndCachePlaylist(a)
        #expect(model.catalog.playlists.first?.trackIDs == ["1"])
        #expect(model.playlistTracks[gid] == nil)
        await connector.failReads(false)
        await model.fetchAndCachePlaylist(a)
        #expect(model.catalog.playlists.first?.trackIDs.isEmpty == true)
        #expect(model.playlistTracks[gid]?.isEmpty == true)
        let stored = try await model.catalogCoordinator.store.listPlaylists(serverID: "a")
        #expect(stored.first?.trackIDs.isEmpty == true)
    }

    @Test("Manual retry cannot select the old track after a newer selection")
    func manualRetryAcrossSelection() async {
        let connector = AuditConnector(destination: result("b"))
        let engine = AuditEngine()
        let model = model(connector, playlists: [], engine: engine)
        model.currentTrack = track("1")
        model.retryPlayback()
        await connector.entered.wait()
        model.selectAndPlay(track("2"))
        await connector.release.open()
        await settle()
        #expect(model.currentTrack.id == "2")
        #expect(!(await engine.playedIDs()).contains("1"))
    }

    @Test("Stream recovery cannot restart after an explicit stop")
    func streamRecoveryAfterStop() async {
        let connector = AuditConnector(destination: result("b"))
        let engine = AuditEngine()
        let model = model(connector, playlists: [], engine: engine)
        model.currentTrack = track("1")
        await engine.handlerReady.wait()
        await engine.fail()
        await connector.entered.wait()
        model.stopPlayback()
        await connector.release.open()
        await settle()
        #expect((await engine.playedIDs()).isEmpty)
        #expect(await engine.state() == .idle)
    }

    private func backup(key: String?, token: String?) -> SettingsBackup {
        SettingsBackup(createdAt: .now, servers: [],
                       ai: BackupAISettings(baseURL: "https://new.example.test", apiPath: "/v1/chat/completions",
                                            model: "new", apiKey: key),
                       musicDownload: BackupMusicDownloadSettings(baseURL: "https://download.example.test",
                                                                 externalBaseURL: "", token: token), preferences: [:])
    }

    @Test("Restoring missing secrets clears old connection credentials")
    func missingCredentials() async throws {
        let vault = InMemoryCredentialVault()
        let defaults = UserDefaults(suiteName: "backup-audit-\(UUID().uuidString)")!
        try await vault.store("old-test-value", for: AIConnectionSettings.credentialID)
        try await vault.store("old-download-value", for: MoviePilotSettings.tokenCredentialID)
        try await BackupConnectionRestorer.restore(backup(key: nil, token: ""), defaults: defaults, vault: vault)
        #expect(defaults.string(forKey: AIConnectionSettings.Keys.baseURL) == "https://new.example.test")
        await #expect(throws: CredentialVaultError.missing) { try await vault.retrieve(id: AIConnectionSettings.credentialID) }
        await #expect(throws: CredentialVaultError.missing) { try await vault.retrieve(id: MoviePilotSettings.tokenCredentialID) }
    }

    @Test("Credential failure rolls back secrets and does not publish new settings")
    func credentialRollback() async throws {
        let vault = AuditFailingVault()
        let defaults = UserDefaults(suiteName: "backup-audit-\(UUID().uuidString)")!
        defaults.set("https://old.example.test", forKey: AIConnectionSettings.Keys.baseURL)
        try await vault.store("old-test-value", for: AIConnectionSettings.credentialID)
        try await vault.store("old-download-value", for: MoviePilotSettings.tokenCredentialID)
        await vault.failNextWrite(MoviePilotSettings.tokenCredentialID)
        await #expect(throws: CredentialVaultError.unavailable) {
            try await BackupConnectionRestorer.restore(backup(key: "new-test-value", token: "new-download-value"), defaults: defaults, vault: vault)
        }
        #expect(defaults.string(forKey: AIConnectionSettings.Keys.baseURL) == "https://old.example.test")
        #expect(try await vault.retrieve(id: AIConnectionSettings.credentialID) == "old-test-value")
        #expect(try await vault.retrieve(id: MoviePilotSettings.tokenCredentialID) == "old-download-value")
    }
}
