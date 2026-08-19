@testable import AppShell
import Application
import Domain
import Foundation
import LocalCatalog
import MusicLibrary
import Testing

private actor SyncPolicyConnector: ServerConnecting {
    let networkCount: Int?
    let fingerprint: String?
    private(set) var countProbeCalls = 0
    private(set) var synchronizerRequests = 0

    init(networkCount: Int?, fingerprint: String? = nil) {
        self.networkCount = networkCount
        self.fingerprint = fingerprint
    }

    func connect(_ input: ServerConnectionInput) async throws -> ServerConnectionResult {
        throw ServerConnectionError.unsupportedResponse
    }

    func librarySongCount(serverID: ServerID) async -> Int? {
        countProbeCalls += 1
        return networkCount
    }

    func libraryRevisionProbe(serverID: ServerID) async -> LibraryRevisionProbe? {
        countProbeCalls += 1
        guard networkCount != nil || fingerprint != nil else { return nil }
        return LibraryRevisionProbe(
            kind: fingerprint == nil ? .countOnly : .albumFingerprint,
            fingerprint: fingerprint,
            songCount: networkCount
        )
    }

    func makeSynchronizer(serverID: ServerID, store: LocalCatalogStore) async -> LibrarySynchronizer? {
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
    completedAt: Date,
    fingerprint: String? = nil
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
    if let fingerprint {
        try await coordinator.store.recordRemoteProbe(
            serverID: serverID,
            fingerprint: fingerprint,
            kind: LibraryRevisionProbe.Kind.albumFingerprint.rawValue,
            probedAt: completedAt,
            markValidated: true
        )
    }
    return coordinator
}

@Test("Foreground cooldown avoids even the cheap network count probe")
@MainActor
func foregroundCooldownSkipsProbe() async throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let connector = SyncPolicyConnector(networkCount: 1, fingerprint: "same")
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

@Test("After cooldown, an unchanged fingerprint with recent validation skips traversal")
@MainActor
func equalCountProbeSkipsCatalogSync() async throws {
    let now = Date(timeIntervalSince1970: 20_000)
    let connector = SyncPolicyConnector(networkCount: 1, fingerprint: "same")
    let coordinator = try await makeSyncPolicyCoordinator(
        connector: connector,
        now: now,
        completedAt: now.addingTimeInterval(-(CatalogCoordinator.foregroundSyncCooldown + 1)),
        fingerprint: "same"
    )

    await coordinator.backgroundRefresh(serverID: "cooldown")
    let calls = await connector.callCounts()
    #expect(calls.probe == 1)
    #expect(calls.synchronizer == 0)
    #expect(coordinator.phase == .upToDate(tracks: 1))
}

@Test("Equal song count alone never proves the catalog is unchanged")
@MainActor
func countOnlyProbeDoesNotSkipCatalogSync() async throws {
    let now = Date(timeIntervalSince1970: 30_000)
    let connector = SyncPolicyConnector(networkCount: 1)
    let coordinator = try await makeSyncPolicyCoordinator(
        connector: connector,
        now: now,
        completedAt: now.addingTimeInterval(-(CatalogCoordinator.foregroundSyncCooldown + 1))
    )
    await coordinator.backgroundRefresh(serverID: "cooldown")
    let calls = await connector.callCounts()
    #expect(calls.probe == 1)
    #expect(calls.synchronizer == 1)
}

@Test("Same count with changed fingerprint requests a full replacement")
@MainActor
func changedFingerprintTriggersSync() async throws {
    let now = Date(timeIntervalSince1970: 40_000)
    let connector = SyncPolicyConnector(networkCount: 1, fingerprint: "new")
    let coordinator = try await makeSyncPolicyCoordinator(
        connector: connector,
        now: now,
        completedAt: now.addingTimeInterval(-(CatalogCoordinator.foregroundSyncCooldown + 1)),
        fingerprint: "old"
    )
    await coordinator.backgroundRefresh(serverID: "cooldown")
    let calls = await connector.callCounts()
    #expect(calls.probe == 1)
    #expect(calls.synchronizer == 1)
}

@Test("Weak fingerprint performs low-frequency full validation")
@MainActor
func staleWeakFingerprintTriggersValidation() async throws {
    let now = Date(timeIntervalSince1970: 200_000)
    let connector = SyncPolicyConnector(networkCount: 1, fingerprint: "same")
    let completedAt = now.addingTimeInterval(-(CatalogCoordinator.weakProbeFullValidationInterval + 1))
    let coordinator = try await makeSyncPolicyCoordinator(
        connector: connector,
        now: now,
        completedAt: completedAt,
        fingerprint: "same"
    )
    await coordinator.backgroundRefresh(serverID: "cooldown")
    let calls = await connector.callCounts()
    #expect(calls.probe == 1)
    #expect(calls.synchronizer == 1)
}
