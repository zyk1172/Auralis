@testable import AppShell
import Application
import Domain
import Foundation
import LocalCatalog
import MusicLibrary
import Testing

private actor SyncPolicyConnector: ServerConnecting {
    let networkCount: Int?
    private(set) var countProbeCalls = 0
    private(set) var synchronizerRequests = 0

    init(networkCount: Int?) {
        self.networkCount = networkCount
    }

    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
        throw ServerConnectionError.unsupportedResponse
    }

    func librarySongCount() async -> Int? {
        countProbeCalls += 1
        return networkCount
    }

    func makeSynchronizer(store: LocalCatalogStore) async -> LibrarySynchronizer? {
        synchronizerRequests += 1
        return nil
    }

    func callCounts() -> (probe: Int, synchronizer: Int) {
        (countProbeCalls, synchronizerRequests)
    }
}

@MainActor
private func makeSyncPolicyCoordinator(
    connector: SyncPolicyConnector,
    now: Date,
    completedAt: Date
) async throws -> CatalogCoordinator {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("auralis-sync-policy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let coordinator = CatalogCoordinator(
        connector: connector,
        storeURL: directory.appendingPathComponent("catalog.sqlite"),
        now: { now }
    )
    let serverID: ServerID = "cooldown"
    let track = Track(
        id: "track", serverID: serverID, albumID: "album", artistID: "artist",
        title: "Song", artistName: "Artist", albumTitle: "Album", duration: 120
    )
    let session = try await coordinator.store.beginSync(serverID: serverID, mode: .full)
    try await coordinator.store.stageTracks([track], session: session)
    try await coordinator.store.completeSync(session, completedAt: completedAt)
    return coordinator
}

@Test("Foreground cooldown avoids even the cheap network count probe")
@MainActor
func foregroundCooldownSkipsProbe() async throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let connector = SyncPolicyConnector(networkCount: 1)
    let coordinator = try await makeSyncPolicyCoordinator(
        connector: connector,
        now: now,
        completedAt: now.addingTimeInterval(-60)
    )

    await coordinator.backgroundRefresh(serverID: "cooldown")
    let calls = await connector.callCounts()
    #expect(calls.probe == 0)
    #expect(calls.synchronizer == 0)
    #expect(coordinator.phase == .upToDate(tracks: 1))
}

@Test("After cooldown, an equal count probe skips the full catalog traversal")
@MainActor
func equalCountProbeSkipsCatalogSync() async throws {
    let now = Date(timeIntervalSince1970: 20_000)
    let connector = SyncPolicyConnector(networkCount: 1)
    let coordinator = try await makeSyncPolicyCoordinator(
        connector: connector,
        now: now,
        completedAt: now.addingTimeInterval(-(CatalogCoordinator.foregroundSyncCooldown + 1))
    )

    await coordinator.backgroundRefresh(serverID: "cooldown")
    let calls = await connector.callCounts()
    #expect(calls.probe == 1)
    #expect(calls.synchronizer == 0)
    #expect(coordinator.phase == .upToDate(tracks: 1))
}
